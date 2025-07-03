#!/usr/bin/env bash
# Frigate LXC Installer Script for Proxmox VE 8.4
# Fully autonomous: Creates Ubuntu 24.04 LXC, configures iGPU passthrough, installs Docker, and deploys Frigate

set -e
set -o pipefail
set -x

info() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
msg_ok() { echo -e "\e[1;32m[OK]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

STEP=0
TOTAL=5
step() {
  ((STEP++))
  info "Step $STEP/$TOTAL: $*"
}

TEMPLATE_STORAGE="local"
ROOT_STORAGE="local-lvm"
BRIDGE="vmbr0"
APP="Frigate"
CPU=2
RAM=2048
DISK=16
TEMPLATE="ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
CTID=121
HOSTNAME="frigate-lxc"

info "Configuration: CTID=$CTID, HOSTNAME=$HOSTNAME"

step "Checking for template"
if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
  pveam update || error "Failed to update template list"
  pveam download $TEMPLATE_STORAGE $TEMPLATE || error "Failed to download template"
fi

step "Creating container"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" \
  --memory "$RAM" \
  --rootfs "$ROOT_STORAGE:$DISK" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --unprivileged 1 \
  --features nesting=1
msg_ok "LXC created"

step "Configuring iGPU passthrough"
CONF="/etc/pve/lxc/${CTID}.conf"
cat <<EOF >> "$CONF"
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
cat <<'UDEV' > /etc/udev/rules.d/99-intel-chmod666.rules
KERNEL=="renderD128", MODE="0666"
UDEV
chmod 666 /dev/dri/renderD128

pct start "$CTID"
msg_ok "Container started"

step "Installing dependencies"
pct exec "$CTID" -- bash -c "apt-get update && apt-get upgrade -y && \
  apt-get install -y docker.io curl && \
  mkdir -p /opt/frigate/config /opt/frigate/media"
msg_ok "Docker and directories prepared"

step "Deploying Frigate"
pct exec "$CTID" -- bash -c 'cat <<EOF > /opt/frigate/docker-compose.yml
version: "3.9"
services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    privileged: true
    restart: unless-stopped
    shm_size: "128mb"
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - /opt/frigate/config:/config
      - /opt/frigate/media:/media
    ports:
      - "5000:5000"
EOF'

pct exec "$CTID" -- bash -lc "cd /opt/frigate && docker compose up -d"
msg_ok "Frigate running"

step "Completed"
IP=$(pct exec "$CTID" hostname -I | awk '{print $1}')
echo -e "\n${APP} is running: http://$IP:5000"
