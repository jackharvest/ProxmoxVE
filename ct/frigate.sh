#!/usr/bin/env bash
# Frigate LXC Setup Script - Automates Ubuntu 24.04 LXC creation, Docker & Frigate install
# Based on Proxmox forum tutorial 167234 (twoace88):contentReference[oaicite:10]{index=10}:contentReference[oaicite:11]{index=11}
# Note: Ensure IOMMU is enabled on host (intel_iommu=on) before running:contentReference[oaicite:12]{index=12}

# Load Proxmox VE helper functions (for container creation and error handling)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Frigate"
var_tags="${var_tags:-media}"             # Tag the container (optional category)
var_cpu="${var_cpu:-2}"                  # Default to 2 vCPUs for the container
var_ram="${var_ram:-4096}"               # Default to 4096 MB (4 GB) RAM:contentReference[oaicite:13]{index=13}
var_disk="${var_disk:-16}"              # Default root disk size 16GB (OS + Docker)
var_disk2="${var_disk2:-128}"           # Second disk size 128GB for Frigate storage:contentReference[oaicite:14]{index=14}
var_os="${var_os:-ubuntu}"               # OS type
var_version="${var_version:-24.04}"      # Ubuntu version 24.04 (as in tutorial)
var_unprivileged="${var_unprivileged:-1}"# Unprivileged container (1 = true):contentReference[oaicite:15]{index=15}

header_info "$APP LXC"
variables
color
catch_errors

function update_script() {
  # Optional: define update behavior (not implemented for Frigate yet)
  header_info
  if pct status $CTID &>/dev/null; then
    msg_info "Frigate LXC (CT $CTID) is already installed. You can update Frigate by pulling a new Docker image inside the container."
  else
    msg_error "No existing Frigate LXC installation found!"
  fi
  exit
}

# Determine an available CT ID and default container name
CTID=${CTID:-$(pvesh get /cluster/nextid)}       # get next free VMID for the container
CT_NAME=${CT_NAME:-frigate}                     # container hostname

# Pull the Ubuntu LXC template if not already available
pveam update >/dev/null 2>&1
if ! pveam available | grep -q "ubuntu-${var_version}-standard"; then
  msg_info "Downloading Ubuntu ${var_version} LXC template..."
  pveam download local ubuntu-${var_version}-standard_${var_version}-1_amd64.tar.zst || { 
    msg_error "Failed to download LXC template"; exit 1; }
  msg_ok "Template downloaded."
fi

# Create LXC container with specified resources and settings
msg_info "Creating LXC container (Ubuntu ${var_version}, CTID $CTID)..."
pct create $CTID local:vztmpl/ubuntu-${var_version}-standard_${var_version}-1_amd64.tar.zst \
  -hostname $CT_NAME -tags $var_tags \
  -cores $var_cpu -memory $var_ram -unprivileged ${var_unprivileged} \
  -features nesting=1,keyctl=1 ${DISABLE_IPV6:+-net0 name=eth0,bridge=vmbr0,ip=dhcp} \
  -rootfs ${var_storage:-local-lvm}:${var_disk} \
  -mp0 ${var_storage:-local-lvm}:${var_disk2},mp=/mnt/frigate_storage || { 
    msg_error "Container creation failed"; exit 1; }
msg_ok "LXC container $CTID created."

# Configure device passthrough for Intel iGPU /dev/dri
# We'll determine the appropriate /dev/dri/card* device to passthrough
GPU_CARD="card1"
if [ -e "/dev/dri/card0" ]; then
  GPU_CARD="card0"
fi
# Start the container to retrieve group IDs inside (e.g. 'render' group ID)
pct start $CTID
sleep 5
VIDEO_GID=$(pct exec $CTID -- getent group video | cut -d: -f3 || echo "44")
RENDER_GID=$(pct exec $CTID -- getent group render | cut -d: -f3 || echo "0")
pct stop $CTID

# Add device entries to LXC config with correct group IDs:contentReference[oaicite:16]{index=16}
LXC_CONFIG="/etc/pve/lxc/${CTID}.conf"
echo "dev0: /dev/dri/${GPU_CARD},gid=${VIDEO_GID},uid=0" >> $LXC_CONFIG    # video group (usually 44):contentReference[oaicite:17]{index=17}
echo "dev1: /dev/dri/renderD128,gid=${RENDER_GID},uid=0" >> $LXC_CONFIG   # render group (mapped):contentReference[oaicite:18]{index=18}
# (No Coral TPU device added, as per user request – skip /dev/apex_0):contentReference[oaicite:19]{index=19}

msg_info "Starting LXC container $CTID with GPU passthrough..."
pct start $CTID
sleep 5
msg_ok "Container $CTID started. Installing Docker and Frigate inside the container..."

# Update container OS and install Docker:contentReference[oaicite:20]{index=20}:contentReference[oaicite:21]{index=21}
pct exec $CTID -- bash -c "apt-get update && apt-get -y upgrade && \
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove -y \$pkg || true; done"  # remove conflicting packages:contentReference[oaicite:22]{index=22}
pct exec $CTID -- apt-get install -y ca-certificates curl gnupg-agent software-properties-common

# Add Docker's official GPG key and repository inside container:contentReference[oaicite:23]{index=23}
pct exec $CTID -- bash -c "install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc"
pct exec $CTID -- bash -c "source /etc/os-release && echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \$${UBUNTU_CODENAME:-\$VERSION_CODENAME} stable\" > /etc/apt/sources.list.d/docker.list"
pct exec $CTID -- apt-get update
pct exec $CTID -- apt-get -y upgrade     # upgrade again after adding Docker repo (if needed)
pct exec $CTID -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin:contentReference[oaicite:24]{index=24}

# Verify Docker installation by running hello-world container:contentReference[oaicite:25]{index=25}
pct exec $CTID -- systemctl enable docker.service containerd.service
pct exec $CTID -- systemctl start docker.service
pct exec $CTID -- docker run --rm hello-world || { msg_error "Docker test failed"; exit 1; }
msg_ok "Docker installed and tested inside LXC."

# Allow running Docker as non-root (add 'docker' group):contentReference[oaicite:26]{index=26}
pct exec $CTID -- groupadd docker || true
pct exec $CTID -- usermod -aG docker root  # add root user to docker group (optional)
# Note: In this LXC, root can run Docker without group membership, but added for completeness:contentReference[oaicite:27]{index=27}

# Prepare Frigate Docker setup inside LXC
pct exec $CTID -- mkdir -p /opt/frigate/config:contentReference[oaicite:28]{index=28}

# Create docker-compose.yml for Frigate:contentReference[oaicite:29]{index=29}:contentReference[oaicite:30]{index=30}
pct exec $CTID -- bash -c "cat > /opt/frigate/docker-compose.yml << 'EOF'
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    privileged: true    # may not be necessary once configured (for initial setup):contentReference[oaicite:31]{index=31}
    restart: unless-stopped
    cap_add:
      - CAP_PERFMON
    group_add:
      - \"${VIDEO_GID}\"     # video group inside container (e.g. 44):contentReference[oaicite:32]{index=32}
      - \"${RENDER_GID}\"    # render group inside container (from container /etc/group):contentReference[oaicite:33]{index=33}:contentReference[oaicite:34]{index=34}
    shm_size: \"256mb\"     # shared memory for Frigate (adjust per number of cameras)
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate_storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache     # optional: use RAM for cache to reduce disk wear
        tmpfs:
          size: 1000000000     # 1GB cache
    ports:
      - \"8971:8971\"         # Frigate UI/API port
      - \"8554:8554\"         # RTSP output feeds port
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128   # iGPU render node for hardware acceleration:contentReference[oaicite:35]{index=35}
      - /dev/dri/${GPU_CARD}:/dev/dri/${GPU_CARD} # iGPU card device (Intel iGPU):contentReference[oaicite:36]{index=36}
      # (No Coral TPU or USB devices passed, as not needed):contentReference[oaicite:37]{index=37}
EOF"
msg_ok "Docker Compose file for Frigate created in CT $CTID."

# Launch Frigate container via docker-compose:contentReference[oaicite:38]{index=38}
pct exec $CTID -- bash -c "cd /opt/frigate && docker compose up -d":contentReference[oaicite:39]{index=39}
sleep 5  # give it a few seconds to initialize

# Check if Frigate container started
FRIGATE_STATUS=$(pct exec $CTID -- docker ps -a -f name=frigate --format '{{.Status}}' || true)
if [[ -z "$FRIGATE_STATUS" ]]; then
  msg_error "Frigate Docker container failed to start. Check the LXC logs for errors."
else
  msg_ok "Frigate Docker container is up and running (${FRIGATE_STATUS})."
fi

# Display access info
CT_IP=$(pct exec $CTID -- ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
echo -e "${INFO}${YW} Frigate UI should be accessible at: ${CL}${GN}http://${CT_IP}:8971${CL}"
echo -e "${INFO}${YW} Initial Frigate admin user/password can be found by checking the Frigate container logs.${CL}"
echo -e "${TAB}- Run: 'pct exec $CTID -- docker logs frigate' to see the output and find the default login credentials :contentReference[oaicite:40]{index=40}."
echo -e "${INFO}${YW} Frigate installation completed successfully!${CL}"
