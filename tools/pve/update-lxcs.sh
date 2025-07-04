#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# Exit on error, undefined var, or pipefail, and print failures
set -eEuo pipefail
trap 'echo -e "\n\033[01;31m[Error] Script failed on line $LINENO with exit code $?\033[m"' ERR

function header_info() {
  clear
  cat <<"EOF"
   __  __          __      __          __   _  ________
  / / / /___  ____/ /___ _/ /____     / /  | |/ / ____/
 / / / / __ \/ __  / __ `/ __/ _ \   / /   |   / /
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / /___/   / /___
\____/ .___/\__,_/\__,_/\__/\___/  /_____/_/|_\____/
    /_/

EOF
}

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
CM='\xE2\x9C\x94\033'
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

header_info
echo "Loading..."
whiptail --backtitle "Proxmox VE Helper Scripts" --title "Proxmox VE LXC Updater" --yesno "This Will Update Running LXC Containers. Proceed?" 10 58

NODE=$(hostname)
EXCLUDE_MENU=()
MSG_MAX_LENGTH=0

# Build whiptail checklist
while read -r TAG ITEM; do
  OFFSET=2
  ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
  EXCLUDE_MENU+=("$TAG" "$ITEM " "OFF")
done < <(pct list | awk 'NR>1')

excluded_containers=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Containers on $NODE" \
  --checklist "\nSelect containers to skip from updates:\n" \
  16 $((MSG_MAX_LENGTH + 23)) 6 "${EXCLUDE_MENU[@]}" \
  3>&1 1>&2 2>&3 | tr -d '"')

function update_container() {
  container=$1
  header_info
  name=$(pct exec "$container" hostname)
  os=$(pct config "$container" | awk '/^ostype/ {print $2}')

  if [[ "$os" == "ubuntu" || "$os" == "debian" || "$os" == "fedora" ]]; then
    disk_info=$(pct exec "$container" df /boot 2>/dev/null | awk 'NR==2{gsub("%","",$5); printf "%s %.1fG %.1fG %.1fG", $5, $3/1024/1024, $2/1024/1024, $4/1024/1024 }') || true
    read -ra disk_info_array <<<"$disk_info"
    echo -e "${BL}[Info]${GN} Updating ${BL}$container${CL} : ${GN}$name${CL} - ${YW}Boot Disk: ${disk_info_array[0]}% full [${disk_info_array[1]}/${disk_info_array[2]} used, ${disk_info_array[3]} free]${CL}\n"
  else
    echo -e "${BL}[Info]${GN} Updating ${BL}$container${CL} : ${GN}$name${CL} - ${YW}[No disk info for ${os}]${CL}\n"
  fi

  case "$os" in
    alpine) pct exec "$container" -- ash -c "apk -U upgrade" ;;
    archlinux) pct exec "$container" -- bash -c "pacman -Syyu --noconfirm" ;;
    fedora | rocky | centos | alma)
      pct exec "$container" -- bash -c "dnf -y update || true; dnf -y upgrade || true" ;;
    ubuntu | debian | devuan)
      pct exec "$container" -- bash -c "apt-get update || true; apt list --upgradable || true; apt-get -yq dist-upgrade || true; rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED || true" ;;
    opensuse) pct exec "$container" -- bash -c "zypper ref && zypper --non-interactive dup" ;;
    *) echo -e "${RD}[Error] Unknown OS type for container $container. Skipping.${CL}"; return ;;
  esac
}

containers_needing_reboot=()
header_info

# Main loop through containers
for container in $(pct list | awk '{if(NR>1) print $1}'); do
  if [[ " ${excluded_containers[@]} " =~ " $container " ]]; then
    echo -e "${BL}[Info]${GN} Skipping ${BL}$container${CL}"
    continue
  fi

  status=$(pct status "$container")
  template=$(pct config "$container" | grep -q "template:" && echo "true" || echo "false")

  if [ "$template" == "true" ]; then
    echo -e "${YW}[Skip]${CL} $container is a template."
    continue
  fi

  if [ "$status" == "status: running" ]; then
    echo -e "${YW}[Run]${CL} Updating $container..."
    update_container "$container"

    if pct exec "$container" -- [ -e "/var/run/reboot-required" ]; then
      container_hostname=$(pct exec "$container" hostname)
      containers_needing_reboot+=("$container ($container_hostname)")
    fi
  else
    echo -e "${YW}[Skip]${CL} $container is not running."
  fi
done

# Final output
header_info
echo -e "${GN}The process is complete. Updated all running containers.${CL}\n"

if [ "${#containers_needing_reboot[@]}" -gt 0 ]; then
  echo -e "${RD}The following containers require a reboot:${CL}"
  for container_name in "${containers_needing_reboot[@]}"; do
    echo "$container_name"
  done
fi

echo ""
