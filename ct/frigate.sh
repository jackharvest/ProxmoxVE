#!/usr/bin/env bash
# ==============================================================================
#  Proxmox VE Helper Script – Frigate NVR in Ubuntu 24.04 LXC
#  Creates an unprivileged container, enables Intel iGPU passthrough, installs
#  Docker & Frigate (via docker‑compose).
#  Adapted from Proxmox forum guide “Ubuntu LXC CT setup with device passthrough
#  on Proxmox VE 8.4 for Frigate installation”.
#  Author: you@example.com | License: MIT
# ==============================================================================

# --- load shared functions ----------------------------------------------------
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# --- default variables (over‑ride with environment vars or whiptail) ----------
APP="Frigate"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"          # root disk (GB)
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"  # 1 = unprivileged
# optional secondary disk for recordings (comment out if not wanted)
var_record_disk="${var_record_disk:-128}"  # GB – mounted at /mnt/frigate

header_info "$APP"
variables
color
catch_errors

# -----------------------------------------------------------------------------#
#  OPTIONAL: implement an update routine later if desired
# -----------------------------------------------------------------------------#
function update_script() {
  header_info
  if pct status "$CTID" &>/dev/null; then
    msg_info "To update Frigate: pct exec $CTID -- docker compose -f /opt/frigate/docker-compose.yml pull && docker compose up -d"
  else
    msg_error "No ${APP} LXC present."
  fi
  exit
}

# ---------- build the container ----------------------------------------------
start
build_container                     # provided by build.func (creates $CTID)
description                         # prints container summary

# ---------- add iGPU passthrough & optional recordings disk ------------------
msg_info "Applying GPU passthrough to CT $CTID …"
pct stop "$CTID"

CFG="/etc/pve/lxc/${CTID}.conf"
# allow DRM (major 226) & render (major 226 minor 128+) to the container
grep -q "cgroup2.devices.allow: c 226" "$CFG" 2>/dev/null || {
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >>"$CFG"
}
# bind‑mount the whole /dev/dri tree
grep -q "lxc.mount.entry: /dev/dri" "$CFG" 2>/dev/null || {
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$CFG"
}

# optional extra storage for Frigate recordings
if [[ -n "$var_record_disk" && "$var_record_disk" -gt 0 ]]; then
  msg_info "Adding ${var_record_disk}G recordings volume …"
  pct set "$CTID" -mp0 "${var_storage:-local-lvm}:${var_record_disk},mp=/mnt/frigate"
fi

pct start "$CTID"
msg_ok  "Container started."

# ---------- install Docker ----------------------------------------------------
msg_info "Installing Docker inside CT $CTID …"
pct exec "$CTID" -- bash -c "
  apt-get update
  apt-get -y upgrade
  # remove conflicting packages
  for p in docker docker.io docker-doc podman-docker containerd runc; do apt-get -y remove \$p || true; done
  apt-get -y install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
"

msg_ok "Docker installed."

# ---------- deploy Frigate ----------------------------------------------------
msg_info "Configuring Frigate (docker‑compose) …"
pct exec "$CTID" -- bash -c "
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
      - '8971:8971'     # Web UI / API
      - '8554:8554'     # RTSP restream
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
      - /dev/dri/card0:/dev/dri/card0
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate:/media/frigate
YML
  cd /opt/frigate
  docker compose up -d
"

msg_ok "Frigate container launched."

# ---------- show result -------------------------------------------------------
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo -e "${INFO}${YW} Frigate UI: http://${CT_IP}:8971 ${CL}"
echo -e "${INFO}${YW} Logs (incl. initial creds): pct exec $CTID -- docker logs frigate ${CL}"
echo -e "${INFO}${GN} ${APP} setup completed successfully! ${CL}"
