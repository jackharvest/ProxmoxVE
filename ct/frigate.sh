#!/usr/bin/env bash
# Frigate LXC Installer Script for Proxmox VE 8.4
# Standalone installer without build.func
# Automates Ubuntu 24.04 LXC creation, Intel iGPU passthrough, optional CIFS share, and Frigate Docker deployment

set -euo pipefail

########################################
# Helper functions
########################################

info() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
msg_ok() { echo -e "\e[1;32m[OK]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

# Prompt wrapper
prompt() {
  whiptail "$@" 3>&1 1>&2 2>&3
}

# Step tracker
STEP=0
TOTAL=6
step() {
  ((STEP++))
  info "Step $STEP/$TOTAL: $*"
}

########################################
# User configuration
########################################

# Defaults
STORAGE="local-lvm"
BRIDGE="vmbr0"
APP="Frigate"
CPU=2
RAM=2048
DISK=16  # in GB
TEMPLATE="ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
UNPRIV=1
NESTING=1

CTID=$(prompt --inputbox "Enter new LXC ID:" 8 40 "101")
HOSTNAME=$(prompt --inputbox "Enter LXC hostname:" 8 40 "frigate-lxc")

# CIFS share prompt
SHARE=$(prompt --yesno "Configure CIFS share for /opt/frigate/media?" 8 48 && echo yes || echo no)

########################################
# Create LXC
########################################
step "Creating LXC $CTID ($HOSTNAME) with Ubuntu 24.04..."
pct create $CTID \
  $STORAGE:vztmpl/$TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CPU \
  --memory $RAM \
  --rootfs $STORAGE:${DISK} \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  --unprivileged $UNPRIV \
  --features nesting=$NESTING
msg_ok "LXC created"

########################################
# Passthrough Intel iGPU
########################################
step "Configuring Intel Alder Lake iGPU passthrough..."
CONF="/etc/pve/lxc/${CTID}.conf"
cat <<EOF >> $CONF
# Intel iGPU passthrough
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
cat <<'UDEV' >/etc/udev/rules.d/99-intel-chmod666.rules
KERNEL=="renderD128", MODE="0666"
UDEV
chmod 666 /dev/dri/renderD128
msg_ok "iGPU passthrough configured"

########################################
# Optional CIFS share
########################################
if [[ "$SHARE" == "yes" ]]; then
  step "Configuring CIFS share for media storage..."
  HOST_MNT=$(prompt --inputbox "Enter host mount point:" 8 50 "/mnt/frigate_media")
  SHARE_PATH=$(prompt --inputbox "Enter CIFS share (//IP/SHARE)" 8 50 "//192.168.1.100/frigate")
  USERNAME=$(prompt --inputbox "Enter share username" 8 40 "user")
  PASSWD=$(prompt --passwordbox "Enter share password" 8 40)
  mkdir -p "$HOST_MNT"
  echo "$SHARE_PATH $HOST_MNT cifs _netdev,noserverino,x-systemd.automount,username=$USERNAME,password=$PASSWD 0 0" \
    >> /etc/fstab
  mount "$HOST_MNT"
  echo "mp0: $HOST_MNT,mp=/opt/frigate/media" >> $CONF
  msg_ok "CIFS share configured"
else
  step "Skipping CIFS share setup"
  msg_ok "No CIFS share"
fi

########################################
# Start and install dependencies
########################################
step "Starting container $CTID..."
pct start $CTID
duration=0
until pct exec $CTID -- true; do sleep 1; ((duration++)); [[ $duration -gt 60 ]] && error "Container failed to start"; done
msg_ok "Container running"

step "Installing Docker, curl, and preparing directories..."
pct exec $CTID -- bash -lc "
  apt-get update && apt-get upgrade -y && \
  apt-get install -y docker.io curl && \
  mkdir -p /opt/frigate/config /opt/frigate/media
"
msg_ok "Dependencies installed"

########################################
# Deploy Frigate via Docker Compose
########################################
step "Deploying Frigate via Docker Compose..."
pct exec $CTID -- tee /opt/frigate/docker-compose.yml <<'YAML'
version: '3.9'
services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    privileged: true
    restart: unless-stopped
    shm_size: '128mb'
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - /opt/frigate/config:/config
      - /opt/frigate/media:/media
    ports:
      - "5000:5000"
YAML
pct exec $CTID -- bash -lc "cd /opt/frigate && docker-compose up -d"
msg_ok "Frigate deployed"

########################################
# Final
########################################
step "Finalizing setup..."
IP=$(pct exec $CTID hostname -I | awk '{print \$1}')
echo -e "\n${APP} is up! Access the UI at: http://$IP:5000"
msg_ok "All steps completed"
