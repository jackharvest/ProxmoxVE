#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 tteck (tteckster)
# License: MIT - https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Description: Proxmox VE LXC Script for Frigate NVR on Ubuntu 24.04 with iGPU passthrough

APP="Frigate"
var_tags="${var_tags:-nvr}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"  # Unprivileged by default

header_info "$APP"
variables
color
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

start

# Step 1: Create container using standard helper
build_container

# Step 2: Run custom Frigate installer inside container
msg_info "Running jackharvest custom Frigate installer..."
if ! curl --output /dev/null --silent --head --fail https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/install/frigate-install.sh; then
  msg_error "Custom installer script not found. Check your GitHub URL."
  exit 1
fi

lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/install/frigate-install.sh)"
msg_ok "Frigate installation complete."

description

msg_ok "Completed Successfully!\n"
echo -e "${BU}Frigate LXC is ready.${CL}"
echo -e "${INFO}${YW} Access the Frigate web interface at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:5000${CL}"
