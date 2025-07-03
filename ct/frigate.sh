#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 tteck
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
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
build_container_setup      # Equivalent of the first half of build_container
build_container_download   # Gets the template
build_container_create     # Actually creates the LXC
build_container_customize  # Mounts devices, sets networking, sets root passwd, etc.
start_container            # Starts the container

# 🧠 Custom step: run your custom Frigate install script inside the container
msg_info "Running jackharvest Frigate installer..."
lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackharvest/ProxmoxVE/main/install/frigate-install.sh)"
msg_ok "Frigate installation complete."

description

msg_ok "Completed Successfully!\n"
echo -e "${BU}Frigate LXC is ready.${CL}"
echo -e "${INFO}${YW} Access the Frigate web interface at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:5000${CL}"
