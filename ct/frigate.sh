#!/bin/bash
# Frigate One-Shot Install Script for Proxmox LXC
# Original author: …  Modified to add LXC root password prompt
# Date: … 

set -euo pipefail

# === Configuration ===
CTID=150               # Container ID
TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
STORAGE="local-lvm"    # Storage for rootfs
MEMORY=4096            # RAM in MB
CORES=4                # CPU cores
BRIDGE="vmbr0"         # Network bridge
IP="192.168.10.150/24" # Static IP/CIDR
GW="192.168.10.1"      # Gateway
DNS="1.1.1.1 8.8.8.8"  # DNS servers
DOCKER_USER="frigate"  # Docker container user
DOCKER_PASS="password123" # Docker container password

# CHANGED: Prompt for LXC root password securely
read -s -p "Enter LXC root password: " LXC_ROOT_PWD   # Bash -s hides input
echo

# === Remove existing container if present ===
if pct status "$CTID" &>/dev/null; then
  echo "Container $CTID exists; removing..."
  pct stop "$CTID" &>/dev/null || true
  pct destroy "$CTID" &>/dev/null || {
    echo "Error: could not destroy container $CTID"; exit 1
  }
fi

# === Create the LXC ===
echo "Creating LXC $CTID from template $TEMPLATE"
pct create "$CTID" "$TEMPLATE" \
  --storage "$STORAGE" \
  --memory "$MEMORY" --cores "$CORES" \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP",gw="$GW" \
  --nameserver "$DNS" \
  --hostname "frigate-lxc" \
  --unprivileged 0 \
  --onboot 1

# CHANGED: Set LXC root password non-interactively
pct exec "$CTID" -- bash -c "echo root:${LXC_ROOT_PWD} | chpasswd" || {
  echo "Error: Failed to set LXC root password"; exit 1
}

# === Install Docker inside LXC ===
echo "Installing Docker in LXC $CTID"
pct exec "$CTID" -- bash -c '
  apt-get update
  apt-get install -y docker.io
  systemctl enable docker
  systemctl start docker
'

# === Launch Frigate Docker Container ===
echo "Launching Frigate container"
pct exec "$CTID" -- bash -c "
  docker run -d --name frigate \
    --restart unless-stopped \
    -e FRIGATE_RTSP_PASSWORD='${DOCKER_PASS}' \
    -e FRIGATE_USER='${DOCKER_USER}' \
    -v /shared/frigate/config:/config:ro \
    -v /shared/frigate/media:/media/frigate \
    ghcr.io/blakeblackshear/frigate:stable
"

# CHANGED: Display Docker container credentials
echo "------------------------------------------------"
echo "Frigate Docker Container Credentials:"
echo "  Username: ${DOCKER_USER}"
echo "  Password: ${DOCKER_PASS}"
echo "------------------------------------------------"

echo "Installation complete. Access Frigate UI at http://$IP:5000"
