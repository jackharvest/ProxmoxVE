#!/usr/bin/env bash
# Frigate Install Script (Modified by jackharvest for LXC Ubuntu 24.04)
# Installs Frigate NVR natively (no Docker) with iGPU and Coral support on arm64/amd64.

set -Eeuo pipefail
STD="&>/dev/null"  # suppress output for cleaner logging

# 1. Update system and install base dependencies
apt-get update $STD
apt-get upgrade -y $STD
# Install required packages: build tools, Git, Python, libraries for FFmpeg and OpenVINO, etc.
apt-get install -y curl sudo git mc gpg software-properties-common $STD
apt-get install -y automake build-essential xz-utils libtool ccache pkg-config $STD
apt-get install -y python3 python3-dev python3-pip python3-venv python3-wheel $STD
apt-get install -y libgtk-3-dev libssl-dev libffi-dev $STD
# FFmpeg libraries (for building or linking)
apt-get install -y libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev libavutil-dev libswresample-dev libswscale-dev $STD
# Intel iGPU drivers and tools (VA-API drivers and GPU tools)
apt-get install -y intel-media-va-driver-non-free vainfo intel-gpu-tools $STD    # for HW video decode/encode
# Coral Edge TPU runtime (USB accelerator support)
apt-get install -y libedgetpu1-std $STD    # Google Coral runtime library:contentReference[oaicite:12]{index=12}

# 2. Retrieve Frigate source code (latest stable release)
FRIGATE_VER="0.15.0"  # example target version (modify as needed)
git clone -b v${FRIGATE_VER} https://github.com/jackharvest/frigate.git /opt/frigate $STD  || {
    echo "Error: Failed to clone Frigate source. Exiting."; exit 1; 
}
cd /opt/frigate

# 3. Build Python wheels for Frigate dependencies (improves install speed)
pip3 install -U pip $STD   # ensure latest pip
pip3 wheel --wheel-dir=/wheels -r /opt/frigate/docker/main/requirements-wheel.txt $STD  # build wheels for heavy deps
pip3 install /wheels/*.whl $STD  # install all built wheels

# 4. Copy preset root filesystem files (service unit, default config, etc.) into system
cp -a /opt/frigate/docker/main/rootfs/. /   # deploy Frigate service files to system:contentReference[oaicite:13]{index=13}

# 5. Set architecture for hardware-specific installs
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "arm64" ]]; then
    export TARGETARCH="arm64"
else
    export TARGETARCH="amd64"
fi
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections  # suppress libc6 prompts:contentReference[oaicite:14]{index=14}

# 6. Install additional Frigate dependencies (OpenVINO, etc.)
# Fetch the install_deps.sh from jackharvest's repo (ensures latest dependency steps)
wget -q -O /opt/frigate/docker/main/install_deps.sh \
  https://raw.githubusercontent.com/jackharvest/frigate/${FRIGATE_VER}/docker/main/install_deps.sh
bash /opt/frigate/docker/main/install_deps.sh $STD  || { echo "Error in install_deps.sh"; exit 1; }

# If CPU supports Intel OpenVINO (SSE4.2 or better), install OpenVINO runtime for iGPU acceleration
if grep -q 'sse4_2' /proc/cpuinfo; then
    pip3 install openvino $STD   # install OpenVINO Python runtime for Intel iGPU:contentReference[oaicite:15]{index=15}
fi

# 7. Install custom FFmpeg (BtbN static build) for enhanced codec support
FFMPEG_URL="$(curl -s https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest \
             | grep browser_download_url \
             | grep linux-${TARGETARCH}-gpl.tar.xz \
             | cut -d '\"' -f 4)"
wget -qO /tmp/ffmpeg.tar.xz "$FFMPEG_URL"
mkdir -p /usr/lib/btbn-ffmpeg && tar -xf /tmp/ffmpeg.tar.xz -C /usr/lib/btbn-ffmpeg --strip-components=1
ln -sf /usr/lib/btbn-ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg   # use custom ffmpeg globally:contentReference[oaicite:16]{index=16}
ln -sf /usr/lib/btbn-ffmpeg/bin/ffprobe /usr/local/bin/ffprobe

# 8. Install Frigate python package and front-end
pip3 install -e /opt/frigate $STD   # install Frigate itself (as editable package)
# (Optional: build Frigate UI if not already built)
make -C /opt/frigate/web build $STD || echo "Web UI build skipped or failed."

# 9. Enable and start Frigate service
systemctl daemon-reload
systemctl enable frigate.service $STD
systemctl start frigate.service $STD

echo -e "\nFrigate installation complete! Frigate is running as a systemd service."
echo "Access the Frigate UI at http://<container-IP>:5000 (or via configured IP/port)."
