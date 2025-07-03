#!/usr/bin/env bash
# ==============================================================================
#  Proxmox VE Helper Script – Frigate NVR in Ubuntu 24.04 LXC (Intel iGPU)
#  Author: you@example.com | License: MIT
# ==============================================================================

#--- load tteck helper functions for pretty output on the HOST only ------------
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Frigate"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"            # root disk size (GB)
var_record_disk="${var_record_disk:-128}"  # recordings disk (GB) – set 0 to skip
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"   # 1 = unprivileged

header_info "$APP"
variables
color
catch_errors

# ───────────────────────────────────────────────────────────────────────────────
#  Wizard banner & default summary (no build_container – we will build manually)
# ───────────────────────────────────────────────────────────────────────────────
start                                               # sets $CTID, $CT_NAME, $var_storage, …
msg_ok "Using Default Settings on node $(hostname)"

# ───────────────────────────────────────────────────────────────────────────────
#  Pull template if missing
# ───────────────────────────────────────────────────────────────────────────────
pveam update >/dev/null 2>&1
tmpl=$(pveam available | grep "ubuntu-${var_version}-standard" | sort -Vr | head -n1 | awk '{print $2}')
if ! ls /var/lib/vz/template/cache | grep -q "$(basename "$tmpl")"; then
  msg_info "Downloading LXC template $tmpl …"
  pveam download local "$tmpl" || { msg_error "Template download failed"; exit 1; }
fi
tmpl_file="local:vztmpl/$(basename "$tmpl")"

# ───────────────────────────────────────────────────────────────────────────────
#  Create container (do NOT start yet)
# ───────────────────────────────────────────────────────────────────────────────
msg_info "Creating LXC container $CTID …"
pct create "$CTID" "$tmpl_file"                         \
  -hostname "$CT_NAME"                                  \
  -tags "$var_tags"                                     \
  -cores "$var_cpu" -memory "$var_ram"                  \
  -rootfs "${var_storage:-local-lvm}:${var_disk}"       \
  -features nesting=1,keyctl=1                          \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp                  \
  -unprivileged "$var_unprivileged" ||                  \
  { msg_error "pct create failed"; exit 1; }
msg_ok "LXC $CTID created."

# ───────────────────────────────────────────────────────────────────────────────
#  GPU passthrough configuration
# ───────────────────────────────────────────────────────────────────────────────
CFG="/etc/pve/lxc/${CTID}.conf"
grep -q "/dev/dri" "$CFG" || {
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >>"$CFG"
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$CFG"
}

# recordings disk (optional)
if [[ "$var_record_disk" -gt 0 ]]; then
  msg_info "Adding ${var_record_disk} GB recordings volume …"
  pct set "$CTID" -mp0 "${var_storage:-local-lvm}:${var_record_disk},mp=/mnt/frigate"
fi

# ───────────────────────────────────────────────────────────────────────────────
#  Start container, get group IDs needed for docker‑compose
# ───────────────────────────────────────────────────────────────────────────────
pct start "$CTID"
sleep 5
VIDEO_GID=$(pct exec "$CTID" -- getent group video  | cut -d: -f3)
RENDER_GID=$(pct exec "$CTID" -- getent group render | cut -d: -f3)

# ───────────────────────────────────────────────────────────────────────────────
#  Install Docker inside the container
# ───────────────────────────────────────────────────────────────────────────────
msg_info "Installing Docker (inside CT $CTID) …"
pct exec "$CTID" -- bash -s <<'INCHROOT'
set -e
apt-get update
apt-get -y upgrade
for p in docker docker.io docker-doc podman-docker containerd runc; do apt-get -y remove "$p" || true; done
apt-get -y install ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
INCHROOT
msg_ok "Docker installed."

# ───────────────────────────────────────────────────────────────────────────────
#  Deploy Frigate via docker‑compose
# ───────────────────────────────────────────────────────────────────────────────
msg_info "Deploying Frigate …"
pct exec "$CTID" -- bash -s <<INCHROOT
set -e
mkdir -p /opt/frigate/config
cat >/opt/frigate/docker-compose.yml <<'YML'
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
      - /dev/dri/renderD128:/dev/dri/renderD128
      - /dev/dri/card0:/dev/dri/card0
    group_add:
      - "${VIDEO_GID}"
      - "${RENDER_GID}"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate:/media/frigate
YML
cd /opt/frigate
docker compose up -d
INCHROOT
msg_ok "Frigate container launched."

# ───────────────────────────────────────────────────────────────────────────────
#  Finish – show access info
# ───────────────────────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo -e "${INFO}${YW} Frigate UI:  http://${CT_IP}:8971 ${CL}"
echo -e "${INFO}${YW} Logs / first‑run creds: pct exec $CTID -- docker logs frigate ${CL}"
echo -e "${INFO}${GN} ${APP} setup completed successfully! ${CL}"
