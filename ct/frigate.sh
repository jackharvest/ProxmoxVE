#!/usr/bin/env bash
# ==============================================================================
#  Frigate NVR – one-shot Proxmox LXC installer (Ubuntu 24.04 + Intel iGPU)
# ==============================================================================

set -eE
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# ─── defaults ─────────────────────────────────────────────────────────────────
APP="Frigate"
CT_NAME="${CT_NAME:-frigate}"
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
var_cpu="${var_cpu:-2}"  var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}" var_record_disk="${var_record_disk:-128}"
var_storage="${var_storage:-local-lvm}" var_tags="${var_tags:-media}"
var_unprivileged="${var_unprivileged:-1}"

# ─── banner ───────────────────────────────────────────────────────────────────
header_info "$APP"
echo -e "  🆔  Container ID: $CTID"
echo -e "  💾  Root Disk   : ${var_disk} GB ($var_storage)"
[[ "$var_record_disk" -gt 0 ]] && echo -e "  📹  Record Disk : ${var_record_disk} GB ($var_storage)"
echo -e "  🧠  RAM         : ${var_ram} MiB"
echo -e "  🧮  vCPUs       : ${var_cpu}\n"

# ─── template ────────────────────────────────────────────────────────────────
pveam update -q
tmpl=$(pveam available | grep "ubuntu-24.04-standard" | sort -Vr | head -n1 | awk '{print $2}')
[[ -z "$tmpl" ]] && { msg_error "Ubuntu 24.04 template not found"; exit 1; }
if ! ls /var/lib/vz/template/cache | grep -q "$(basename "$tmpl")"; then
  msg_info "Downloading template…"; pveam download local "$tmpl"; msg_ok "Template ready."
fi
tmpl_file="local:vztmpl/$(basename "$tmpl")"

# ─── create LXC ───────────────────────────────────────────────────────────────
msg_info "Creating LXC $CTID …"
pct create "$CTID" "$tmpl_file" \
  -hostname "$CT_NAME" -tags "$var_tags" \
  -cores "$var_cpu" -memory "$var_ram" \
  -rootfs "${var_storage}:${var_disk}" \
  -features nesting=1,keyctl=1 -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -unprivileged "$var_unprivileged"
msg_ok "Container created."

[[ "$var_record_disk" -gt 0 ]] && {
  msg_info "Adding ${var_record_disk} GB recordings volume…"
  pct set "$CTID" -mp0 "${var_storage}:${var_record_disk},mp=/mnt/frigate"
}

CFG="/etc/pve/lxc/${CTID}.conf"
grep -q "/dev/dri" "$CFG" || {
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >>"$CFG"
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$CFG"
}

# ─── start & gather group IDs ────────────────────────────────────────────────
pct start "$CTID"; sleep 5
VIDEO_GID=$(pct exec "$CTID" -- getent group video  | awk -F: '{print $3}' || echo 44)
RENDER_GID=$(pct exec "$CTID" -- getent group render| awk -F: '{print $3}' || echo 0)

# ─── install Docker ──────────────────────────────────────────────────────────
msg_info "Installing Docker…"
pct exec "$CTID" -- bash -s <<'EOS'
set -e
apt-get update && apt-get -y upgrade
for p in docker docker.io podman-docker containerd runc; do apt-get -y remove "$p" || true; done
apt-get -y install ca-certificates curl gnupg
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
EOS
msg_ok "Docker installed."

# ─── deploy Frigate ──────────────────────────────────────────────────────────
msg_info "Deploying Frigate…"
pct exec "$CTID" -- bash -s <<EOS
set -e
mkdir -p /opt/frigate/config
cat >/opt/frigate/docker-compose.yml <<YML
version: "3.9"
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    privileged: true
    restart: unless-stopped
    shm_size: 256m
    ports:
      - "8971:8971"
      - "8554:8554"
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "$VIDEO_GID"
      - "$RENDER_GID"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /mnt/frigate:/media/frigate
YML
cd /opt/frigate
docker compose up -d
EOS
msg_ok "Frigate container launched."

# ─── extract generated admin credentials ─────────────────────────────────────
msg_info "Waiting for Frigate to create default admin user…"
FRIGATE_PASS=""
for _ in {1..20}; do
  CREDS=$(pct exec "$CTID" -- docker logs frigate 2>&1 | grep -m1 "Created user admin with password" || true)
  [[ -n "$CREDS" ]] && { FRIGATE_PASS=$(echo "$CREDS" | awk '{print $NF}'); break; }
  sleep 3
done
[[ -z "$FRIGATE_PASS" ]] && FRIGATE_PASS="<check logs>"

# ─── summary ─────────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo -e "${INFO}${YW} Frigate UI: http://${CT_IP}:8971 ${CL}"
echo -e "${INFO}${YW} Login → user: ${GN}admin${CL}  pass: ${GN}${FRIGATE_PASS}${CL}"
echo -e "${INFO}${GN} Provisioning finished successfully!${CL}"
