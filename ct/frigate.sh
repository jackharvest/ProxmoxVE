#!/usr/bin/env bash
# Frigate LXC Installer Script for Proxmox VE 8.4 using build.func
# Automates Ubuntu LXC with Intel iGPU passthrough and Frigate docker deployment
# Source: Proxmox Community Scripts & https://forum.proxmox.com/threads/167234

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Disable default header banner to prevent hanging on ASCII art
header_info() { :; }

APP="Frigate"
var_tags="security"
var_cpu="2"
var_ram="2048"
var_disk="16"
var_os="ubuntu"
var_version="24.04"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

# Override build.func default installer to prevent community script pull
install_script() {
  # no-op: custom install steps follow
  return 0
}

# Prompt for CIFS share
SHARE_PASS=$(whiptail --yesno "Configure CIFS share for Frigate media?" 8 48 --yes-button Yes --no-button Skip && echo yes || echo no)

# Start LXC creation
start
build_container
CTID="$CTID"
description

# Intel Alder Lake iGPU passthrough
msg_info "Configuring Intel iGPU passthrough..."
CONF="/etc/pve/lxc/${CTID}.conf"
cat <<EOF >> $CONF
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
cat <<'UDEVRULE' >/etc/udev/rules.d/99-intel-chmod666.rules
KERNEL=="renderD128", MODE="0666"
UDEVRULE
chmod 666 /dev/dri/renderD128
msg_ok "Intel iGPU passthrough configured"

# Optional CIFS share mounting
if [[ "$SHARE_PASS" == "yes" ]]; then
  HOST_MNT=$(whiptail --inputbox "Host mount point (e.g., /mnt/frigate_media)" 8 50 "/mnt/frigate_media" 3>&1 1>&2 2>&3)
  SHARE_PATH=$(whiptail --inputbox "CIFS share (//IP/SHARE)" 8 50 "//192.168.1.100/frigate" 3>&1 1>&2 2>&3)
  USERNAME=$(whiptail --inputbox "Share username" 8 40 "user" 3>&1 1>&2 2>&3)
  PASSWD=$(whiptail --passwordbox "Share password" 8 40 3>&1 1>&2 2>&3)
  mkdir -p "$HOST_MNT"
  echo "$SHARE_PATH $HOST_MNT cifs _netdev,noserverino,x-systemd.automount,username=$USERNAME,password=$PASSWD 0 0" >> /etc/fstab
  mount "$HOST_MNT"
  echo "mp0: $HOST_MNT,mp=/opt/frigate/media" >> $CONF
  msg_ok "CIFS share configured"
fi

# Launch container and perform custom install
start_container
msg_info "Installing Docker & Frigate..."
pct exec $CTID -- bash -lc "
  apt-get update && apt-get upgrade -y && \
  apt-get install -y docker.io curl && \
  mkdir -p /opt/frigate/config /opt/frigate/media
"

# Deploy docker-compose
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
msg_ok "Frigate installation complete"

echo -e "${INFO} Access Frigate UI at http://$(pct exec $CTID hostname -I | awk '{print \$1}'):5000"
