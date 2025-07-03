#!/usr/bin/env bash
# Frigate LXC Installer Script for Proxmox VE 8.4
# Automates Ubuntu LXC setup with Intel iGPU passthrough and Frigate docker deployment
# Source: https://forum.proxmox.com/threads/ubuntu-lxc-ct-setup-with-device-passthrough-on-proxmox-ve-8-4-for-frigate-installation.167234/

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

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

# Prompt for CIFS network share mounting inside LXC
SHARE_PASS=$(whiptail --yesno "Configure CIFS network share for Frigate media storage?" 8 48 --yes-button "Yes" --no-button "Skip" && echo yes || echo no)

# Create LXC container
start
build_container
CTID="$CTID"
description

msg_info "Configuring Intel Alder Lake iGPU passthrough..."
CONF="/etc/pve/lxc/${CTID}.conf"
# Allow DRM and render devices
cat <<EOF >> $CONF
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
# Host udev rule to ensure render permissions
cat <<'UDEV' >/etc/udev/rules.d/99-intel-chmod666.rules
KERNEL=="renderD128", MODE="0666"
UDEV
chmod 666 /dev/dri/renderD128
msg_ok "Intel iGPU passthrough configured"

# Optionally configure CIFS share
if [[ "$SHARE_PASS" == "yes" ]]; then
  HOST_MNT=$(whiptail --inputbox "Enter host mount point (e.g., /mnt/lxc_shares/frigate)" 8 60 "/mnt/lxc_shares/frigate" 3>&1 1>&2 2>&3)
  SHARE_PATH=$(whiptail --inputbox "Enter CIFS share (e.g., //192.168.1.100/frigate)" 8 60 "//192.168.1.100/frigate" 3>&1 1>&2 2>&3)
  SHARE_USER=$(whiptail --inputbox "Enter share username" 8 40 "username" 3>&1 1>&2 2>&3)
  SHARE_PASSWD=$(whiptail --passwordbox "Enter share password" 8 40 3>&1 1>&2 2>&3)

  mkdir -p "$HOST_MNT"
  echo "$SHARE_PATH $HOST_MNT cifs _netdev,noserverino,x-systemd.automount,noatime,uid=100000,gid=110000,dir_mode=0770,file_mode=0770,username=$SHARE_USER,password=$SHARE_PASSWD 0 0" >> /etc/fstab
  mount "$HOST_MNT"
  echo "mp0: $HOST_MNT,mp=/opt/frigate/media" >> "/etc/pve/lxc/${CTID}.conf"
  msg_ok "CIFS share configured"
fi

# Start container and install dependencies
pct start $CTID
msg_info "Installing Docker and deploying Frigate in LXC..."
pct exec $CTID -- bash -c "
  apt-get update && apt-get upgrade -y && \
  apt-get install -y docker.io curl && \
  mkdir -p /opt/frigate/config /opt/frigate/media
"

# Create docker-compose for Frigate
cat <<'EOF' >/opt/frigate/docker-compose.yml
version: '3.9'
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:stable
    shm_size: '128mb'
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - /opt/frigate/config:/config
      - /opt/frigate/media:/media
    ports:
      - "5000:5000"
EOF
pct push $CTID /opt/frigate/docker-compose.yml /opt/frigate/docker-compose.yml
pct exec $CTID -- bash -c "cd /opt/frigate && docker-compose up -d"
msg_ok "Frigate installation complete!"

echo -e "${INFO} Access Frigate UI at http://$(pct exec $CTID hostname -I | awk '{print \$1}'):5000"
