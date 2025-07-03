#!/usr/bin/env bash
# ==============================================================================
#  Frigate NVR – one‑shot Proxmox LXC installer (Ubuntu 24.04 + Intel iGPU)
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
echo -e "  🖥️  Host Node   : $(hostname)"
echo -e "  💾  Root Disk   : ${var_disk} GB on ${var_storage}"
[[ "$var_record_disk" -gt 0 ]] && \
echo -e "  📹  Record Disk : ${var_record_disk} GB on ${var_storage} (mounted /mnt/frigate)"
echo -e "  🧠  RAM         : ${var_ram} MiB"
echo -e "  🧮  vCPUs       : ${var_cpu}"
echo -e "  📦  Container Type: Unprivileged\n"

# --- pull latest Ubuntu 24.04 template if missing -----------------------------
pveam update >/dev/null 2>&1
tmpl=$(pveam available | grep "ubuntu-24.04-standard" | sort -Vr | head -n1 | awk '{print $2}')
[[ -z "$tmpl" ]] && { msg_error "Ubuntu 24.04 template not found in PVE repo"; exit 1; }

if ! ls /var/lib/vz/template/cache | grep -q "$(basename "$tmpl")"; then
  msg_info "Downloading template $tmpl …"
  pveam download local "$tmpl" || { msg_error "Template download failed"; exit 1; }
fi
tmpl_file="local:vztmpl/$(basename "$tmpl")"

# --- create container ---------------------------------------------------------
msg_info "Creating LXC $CTID …"
pct create "$CTID" "$tmpl_file"                       \
  -hostname "$CT_NAME"                               \
  -tags "$var_tags"                                  \
  -cores "$var_cpu" -memory "$var_ram"               \
  -rootfs "${var_storage}:${var_disk}"               \
  -features nesting=1,keyctl=1                       \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp               \
  -unprivileged "$var_unprivileged"
msg_ok "Container created."

# --- optional extra disk for recordings ---------------------------------------
if [[ "$var_record_disk" -gt 0 ]]; then
  msg_info "Adding ${var_record_disk} GB recordings volume …"
  pct set "$CTID" -mp0 "${var_storage}:${var_record_disk},mp=/mnt/frigate"
fi

# --- pass the Intel iGPU ------------------------------------------------------
CFG="/etc/pve/lxc/${CTID}.conf"
grep -q "/dev/dri" "$CFG" || {
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >>"$CFG"
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$CFG"
}

# --- start CT and wait until it's ready ---------------------------------------
pct start "$CTID"
for i in {1..20}; do
  pct exec "$CTID" -- whoami &>/dev/null && break
  sleep 1
done

# --- disable root password and enable autologin -------------------------------
pct exec "$CTID" -- passwd -d root

pct exec "$CTID" -- bash -c "
mkdir -p /etc/systemd/system/console-getty.service.d
cat <<EOF > /etc/systemd/system/console-getty.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 vt220
EOF
systemctl daemon-reexec
systemctl restart console-getty
"

# --- gather group IDs ---------------------------------------------------------
VIDEO_GID=$(pct exec "$CTID" -- getent group video  | awk -F: '{print $3}' || echo 44)
RENDER_GID=$(pct exec "$CTID" -- getent group render | awk -F: '{print $3}' || echo 0)

# --- install Docker -----------------------------------------------------------
msg_info "Installing Docker in CT $CTID …"
pct exec "$CTID" -- bash -s <<'EOF_CT'
set -e
apt-get update
apt-get -y upgrade
for p in docker docker.io podman-docker containerd runc; do apt-get -y remove "$p" || true; done
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

# --- deploy Frigate via docker‑compose ----------------------------------------
msg_info "Deploying Frigate …"
pct exec "$CTID" -- bash -s <<EOF_CT
set -e
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
      - "8971:8971"
      - "8554:8554"
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "$VIDEO_GID"
      - "$RENDER_GID"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate:/media/frigate
YML
cd /opt/frigate
docker compose up -d
EOF_CT
msg_ok "Frigate container launched."

# --- retrieve Frigate credentials ---------------------------------------------
msg_info "Retrieving Frigate credentials …"
FRIGATE_PASS=""
for i in {1..30}; do
  FRIGATE_PASS=$(pct exec "$CTID" -- bash -c \
    "docker logs frigate 2>&1 | grep -m1 'Created user admin with password' | awk '{print \$NF}'") || true
  [[ -n "$FRIGATE_PASS" ]] && break
  sleep 1
done
[[ -z "$FRIGATE_PASS" ]] && FRIGATE_PASS="<check logs manually>"

# --- final output -------------------------------------------------------------
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo -e "${INFO}${YW} Frigate UI: http://${CT_IP}:8971 ${CL}"
echo -e "${INFO}${YW} Login → user: ${GN}admin${CL}  pass: ${GN}${FRIGATE_PASS}${CL}"
echo -e "${INFO}${GN} Frigate LXC provisioning completed successfully! ${CL}"
