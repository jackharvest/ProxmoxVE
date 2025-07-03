#!/usr/bin/env bash
# LXC Creation Script for Frigate (Modified by jackharvest)
# Based on community-scripts/ProxmoxVE version, adapted for Ubuntu 24.04 and iGPU/Coral support
# Copyright (c) 2021-2025 tteck/jackharvest - License: MIT

source <(curl -s https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/misc/build.func)  # use jackharvest fork URL
function header_info {
  clear
  cat <<"EOF"
   ______     _       __    
  / ____/____(_)___  / /____
 / /_   / ___/ / __ \/ __/ _ \
/ __/  / /  / / /_/ / /_/  __/
/_/    /_/  /_/\__,_/\__/\___/   LXC
EOF
}
header_info
echo -e "Loading LXC container configuration..."

# Container base image and default resources
APP="Frigate"
var_disk="20"
var_cpu="4"
var_ram="4096"
var_os="ubuntu"              # Use Ubuntu as base OS (was "debian")
var_version="24.04"          # Ubuntu 24.04 LTS base image:contentReference[oaicite:5]{index=5}
variables                   # (from build.func – sets up container config variables)
color
catch_errors

function default_settings() {
  CT_TYPE="1"                # Container type (1 = Unprivileged, 0 = Privileged)
  PW=""
  CT_ID=$NEXTID
  HN=$NSAPP
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  DISABLEIP6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  echo_default      # print defaults for confirmation
}

function update_script() {
  if [[ ! -f /etc/systemd/system/frigate.service ]]; then 
    msg_error "No ${APP} installation found!"; exit 
  fi
  msg_error "There is currently no scripted update path – please deploy a new container for updates.:contentReference[oaicite:6]{index=6}"
  exit
}

# Begin container creation
start
build_container     # uses the configured vars to create the LXC and run install script
description

# Enable device passthrough for iGPU/Coral (if applicable)
# Mount Intel iGPU devices (VA-API):
pct set $CTID -mp0 /dev/dri,mp=/dev/dri
# Mount all USB buses for Coral support (optional – safe for USB Coral) 
pct set $CTID -mp1 /dev/bus/usb,mp=/dev/bus/usb

# Finalize and display access info
msg_info "Setting container to normal resource limits..."
pct set $CTID -memory 1024   # reduce memory to 1GB after installation (as per upstream):contentReference[oaicite:7]{index=7}
msg_ok "Container resources set to default limits."

msg_ok "Frigate LXC creation completed successfully!\n"
echo -e "Frigate UI should be reachable at: ${BL}http://${IP}:5000${CL}"
echo -e "go2rtc (RTSP) UI at: ${BL}http://${IP}:1984${CL}\n"
