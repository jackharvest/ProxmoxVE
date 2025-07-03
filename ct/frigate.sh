#!/usr/bin/env bash
# ==============================================================================
#  Frigate NVR – one-shot Proxmox LXC installer (Ubuntu 24.04 + Intel iGPU)
#  Enhanced version with interactive password setup and credential extraction.
#  Author: you@example.com | License: MIT
# ==============================================================================

set -eE

# --- pretty output helpers ----------------------------------------------------
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# --- defaults (override with environment variables or edit below) -------------
APP="Frigate"
CT_NAME="${CT_NAME:-frigate}"
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_record_disk="${var_record_disk:-128}"   # 0 = no extra recordings disk
var_storage="${var_storage:-local-lvm}"
var_tags="${var_tags:-media}"
var_unprivileged="${var_unprivileged:-1}"   # 1 = unprivileged

# --- banner -------------------------------------------------------------------
header_info "$APP"
echo -e "  🆔  Container ID: $CTID"
echo -e "  🖥️  Host Node     : $(hostname)"
echo -e "  💾  Root Disk     : ${var_disk} GB on ${var_storage}"
[[ "$var_record_disk" -gt 0 ]] && \
echo -e "  📹  Record Disk   : ${var_record_disk} GB on ${var_storage} (mounted /mnt/frigate)"
echo -e "  🧠  RAM           : ${var_ram} MiB"
echo -e "  🧮  vCPUs         : ${var_cpu}"
echo -e "  📦  Type          : Unprivileged LXC\n"

# --- prompt for LXC root password ---------------------------------------------
# This loop prompts the user for a password for the LXC's root user.
# -s: silent mode, hides input.
# -r: raw mode, prevents backslash interpretation.
# The loop ensures the password is not empty and that the confirmation matches.
while true; do
  read -s -r -p "Enter a password for the LXC root user: " LXC_PASSWORD
  echo
  read -s -r -p "Confirm the password: " LXC_PASSWORD2
  echo
  if]; then
    msg_ok "Password set."
    break
  fi
  msg_error "Passwords do not match or are empty. Please try again."
done

# --- pull latest Ubuntu 24.04 template if missing -----------------------------
pveam update >/dev/null 2>&1
tmpl=$(pveam available | grep "ubuntu-24.04-standard" | sort -Vr | head -n1 | awk '{print $2}')
[[ -z "$tmpl" ]] && { msg_error "Ubuntu 24.04 template not found in PVE repo"; exit 1; }

if! ls /var/lib/vz/template/cache | grep -q "$(basename "$tmpl")"; then
  msg_info "Downloading template $tmpl …"
  pveam download local "$tmpl" |

| { msg_error "Template download failed"; exit 1; }
fi
tmpl_file="local:vztmpl/$(basename "$tmpl")"

# --- create container ---------------------------------------------------------
msg_info "Creating LXC $CTID …"
pct create "$CTID" "$tmpl_file"                                  \
  -hostname "$CT_NAME"                                           \
  -password "$LXC_PASSWORD"                                      \
  -tags "$var_tags"                                              \
  -cores "$var_cpu" -memory "$var_ram"                           \
  -rootfs "${var_storage}:${var_disk}"                           \
  -features nesting=1,keyctl=1                                   \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp                           \
  -unprivileged "$var_unprivileged"
msg_ok "Container created."

# --- optional extra disk for recordings ---------------------------------------
if [[ "$var_record_disk" -gt 0 ]]; then
  msg_info "Adding ${var_record_disk} GB recordings volume …"
  pct set "$CTID" -mp0 "${var_storage}:${var_record_disk},mp=/mnt/frigate"
fi

# --- pass the Intel iGPU ------------------------------------------------------
CFG="/etc/pve/lxc/${CTID}.conf"
grep -q "/dev/dri" "$CFG" |

| {
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >>"$CFG"
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$CFG"
}

# --- start CT & gather group IDs inside it ------------------------------------
pct start "$CTID"
sleep 5
VIDEO_GID=$(pct exec "$CTID" -- getent group video | awk -F: '{print $3}' |

| echo 44)
RENDER_GID=$(pct exec "$CTID" -- getent group render | awk -F: '{print $3}' |

| echo 0)

# --- install Docker -----------------------------------------------------------
msg_info "Installing Docker in CT $CTID …"
pct exec "$CTID" -- bash -s <<'EOF_CT'
set -e
apt-get update
apt-get -y upgrade
for p in docker docker.io podman-docker containerd runc; do apt-get -y remove "$p" |

| true; done
apt-get -y install ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
EOF_CT
msg_ok "Docker installed."

# --- deploy Frigate via docker-compose ----------------------------------------
msg_info "Deploying Frigate …"
# Pass GIDs as arguments to the heredoc for safety
pct exec "$CTID" -- bash -s -- "$VIDEO_GID" "$RENDER_GID" <<'EOF_CT'
set -e
VIDEO_GID_ARG=$1
RENDER_GID_ARG=$2
mkdir -p /opt/frigate/config
cat >/opt/frigate/docker-compose.yml <<YML
version: '3.9'
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    privileged: true
    restart: unless-stopped
    shm_size: 256m
    ports:
      # Map host port 8971 to container's UI port 5000
      - "8971:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "$VIDEO_GID_ARG"
      - "$RENDER_GID_ARG"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate:/media/frigate
YML
cd /opt/frigate
docker compose up -d
EOF_CT
msg_ok "Frigate container launched."

# --- show access info and extract credentials ---------------------------------
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
CRED_TIMEOUT=180 # 3 minute timeout

# Wait until the Docker container is actually in a 'running' state
msg_info "Waiting for Frigate container to start (max 60s)..."
COUNT=0
while]; do
  sleep 2
  COUNT=$((COUNT + 2))
  if]; then
    msg_error "Frigate Docker container failed to start within the timeout period."
    echo -e "${INFO}${YW} Please check the logs manually with the command below:${CL}"
    echo -e "${INFO}   pct exec $CTID -- docker logs frigate"
    exit 1
  fi
done
msg_ok "Frigate container is running."

msg_info "Waiting for Frigate to generate initial credentials (max ${CRED_TIMEOUT}s) …"

# Use timeout and grep to capture the credential block from the logs.
# grep -m 1: find the first match then exit.
# grep -A 2: print the matching line and the 2 lines after it.
# The '|| true' prevents the script from exiting if timeout is reached.
CRED_OUTPUT=$(timeout ${CRED_TIMEOUT}s bash -c "pct exec '$CTID' -- docker logs --follow frigate 2>/dev/null | grep -m 1 -A 2 'Created a default user:'" |

| true)

FRIGATE_USER=""
FRIGATE_PASS=""

if]; then
    FRIGATE_USER=$(echo "$CRED_OUTPUT" | grep "user:" | awk '{print $NF}')
    FRIGATE_PASS=$(echo "$CRED_OUTPUT" | grep "password:" | awk '{print $NF}')
fi

echo
echo -e "${INFO} ${GN}Frigate LXC Provisioning Completed Successfully!${CL}"
echo -e "${INFO} -----------------------------------------------------"
echo -e "${INFO}${YW} Frigate UI: http://${CT_IP}:8971 ${CL}"
if]; then
  echo -e "${INFO}${GN} Initial Frigate credentials have been extracted:${CL}"
  echo -e "${INFO}   Username: ${YW}$FRIGATE_USER${CL}"
  echo -e "${INFO}   Password: ${YW}$FRIGATE_PASS${CL}"
  echo -e "${INFO} ${CYAN}It is strongly recommended to change this password after your first login.${CL}"
else
  msg_error "Could not automatically extract Frigate credentials within ${CRED_TIMEOUT}s."
  echo -e "${INFO}${YW} Please check the logs manually with the command below:${CL}"
  echo -e "${INFO}   pct exec $CTID -- docker logs frigate"
fi
echo -e "${INFO} -----------------------------------------------------"
