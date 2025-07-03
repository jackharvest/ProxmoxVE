#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 tteck (tteckster)
# License: MIT - https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Description: Proxmox VE LXC Script for Frigate NVR on Ubuntu 24.04 with iGPU passthrough

APP="Frigate"
var_tags="${var_tags:-nvr}"              # Tag the container as NVR
var_cpu="${var_cpu:-4}"                  # Default 4 vCPUs
var_ram="${var_ram:-4096}"               # Default 4GB RAM
var_disk="${var_disk:-20}"               # Default 20GB disk
var_os="${var_os:-ubuntu}"              # Use Ubuntu base template
var_version="${var_version:-24.04}"     # Ubuntu 24.04 LTS
var_unprivileged="${var_unprivileged:-1}"  # 1 = Unprivileged container (recommended)

# Display header
header_info "$APP"
# Load default variables and colors
variables
color
# Enable error handling
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /etc/systemd/system/frigate.service ]]; then
    msg_error "No ${APP} installation found!"
    exit
  fi
  msg_error "To update Frigate, create a new container and transfer your configuration."
  exit
}

# Start the container creation process
start
export var_install="https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/install/frigate-install.sh"
build_container   # This will download the Ubuntu 24.04 template and create the LXC, then install Frigate
description       # Set the container description (with links to docs/community)

# If we reached here, installation succeeded
msg_ok "Completed Successfully!\n"
echo -e "${BU}Frigate LXC is ready.${CL}"
echo -e "${INFO}${YW} Access the Frigate web interface at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:5000${CL}"
