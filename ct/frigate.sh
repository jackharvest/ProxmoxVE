#!/usr/bin/env bash
# Frigate LXC Installer Script for Proxmox VE 8.4
# Manual Ubuntu LXC setup with Intel iGPU passthrough and Frigate docker deployment
# Source: Adapted from Proxmox community and forum instructions

# Configuration defaults
APP="Frigate"
STORAGE="local-lvm"
BRIDGE="vmbr0"
var_cpu="2"
var_ram="2048"
var_disk="16"
var_ostemplate="ubuntu-24.04-standard_24.04-1_amd64.tar.zst"

# Prompt
CTID=$(whiptail --inputbox "Enter new container ID:" 8 40 "101" 3>&1 1>&2 2>&3)
HOSTNAME=$(whiptail --inputbox "Enter hostname for LXC:" 8 40 "frigate-lxc" 3>&1 1>&2 2>&3)

# Optional CIFS
SHARE_PASS=$(whiptail --yesno "Configure CIFS share for /opt/frigate/media?" 8 48 && echo yes || echo no)

# Create LXC manually
echo "Creating LXC CT $CTID using Ubuntu 24.04 template..."
pct create $CTID $STORAGE:vztmpl/$var_ostemplate \
  --hostname $HOSTNAME \
  --cores $var_cpu \
  --memory $var_ram \
  --rootfs $STORAGE:${var_disk} \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1

# Passthrough Intel Alder Lake iGPU
echo "Configuring Intel iGPU passthrough..."
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

# Configure CIFS share
if [[ "$SHARE_PASS" == "yes" ]]; then
  HOST_MNT=$(whiptail --inputbox "Host mount point (e.g., /mnt/frigate_media)" 8 50 "/mnt/frigate_media" 3>&1 1>&2 2>&3)
  SHARE_PATH=$(whiptail --inputbox "CIFS share (//IP/SHARE)" 8 50 "//192.168.1.100/frigate" 3>&1 1>&2 2>&3)
  USERNAME=$(whiptail --inputbox "Share username" 8 40 "user" 3>&1 1>&2 2>&3)
  PASSWD=$(whiptail --passwordbox "Share password" 8 40 3>&1 1>&2 2>&3)
  mkdir -p "$HOST_MNT"
  echo "$SHARE_PATH $HOST_MNT cifs _netdev,noserverino,x-systemd.automount,username=$USERNAME,password=$PASSWD 0 0" >> /etc/fstab
  mount "$HOST_MNT"
  echo "mp0: $HOST_MNT,mp=/opt/frigate/media" >> $CONF
fi

# Start CT and install Frigate
pct start $CTID
pct exec $CTID -- bash -lc "
  apt-get update && apt-get upgrade -y && \
  apt-get install -y docker.io curl && \
  mkdir -p /opt/frigate/config /opt/frigate/media
"

# Deploy Docker-Compose
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

echo "${APP} LXC $CTID configured. Access UI at: http://$(pct exec $CTID hostname -I | awk '{print \$1}'):5000"
