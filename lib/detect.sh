#!/usr/bin/env bash
# detect.sh - host facts: OS, arch, memory, disk, network, existing services.

declare -g OS_ID="" OS_VERSION="" OS_PRETTY="" OS_CODENAME="" ARCH="" MEM_MB=0 DISK_FREE_GB=0
declare -g CPU_COUNT=1 HOST_PUBLIC_IP="" HOST_PRIMARY_IFACE="" SSH_CLIENT_IP=""

detect_host() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-}"; OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  fi
  ARCH=$(uname -m)
  MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  CPU_COUNT=$(nproc 2>/dev/null || echo 1)
  DISK_FREE_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  DISK_FREE_GB=${DISK_FREE_GB:-0}
  HOST_PRIMARY_IFACE=$( { ip -4 route show default 2>/dev/null || true; } | awk '{print $5; exit}')
  SSH_CLIENT_IP=${SSH_CONNECTION:-}; SSH_CLIENT_IP=${SSH_CLIENT_IP%% *}
  export OS_ID OS_VERSION OS_PRETTY OS_CODENAME ARCH MEM_MB CPU_COUNT DISK_FREE_GB HOST_PRIMARY_IFACE SSH_CLIENT_IP
}

os_supported() {
  case "$OS_ID" in
    ubuntu) [[ "$OS_VERSION" =~ ^(20\.04|22\.04|24\.04|24\.10|25\.04|26\.04)$ ]] ;;
    debian) [[ "${OS_VERSION%%.*}" =~ ^(11|12|13)$ ]] ;;
    *) return 1 ;;
  esac
}

# detect_compose_file DIR : prints the compose file name if found
detect_compose_file() {
  local dir="$1" f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [[ -f "$dir/$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# compose_services FILE : list top-level service names (best-effort YAML parse)
compose_services() {
  local file="$1"
  awk '
    /^services:[[:space:]]*$/ { in_s=1; next }
    in_s && /^[^[:space:]#]/ { in_s=0 }
    in_s && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { gsub(/[: ]/,"",$1); print $1 }
  ' "$file"
}

# compose_service_image FILE SERVICE : image of a service (best-effort)
compose_service_image() {
  local file="$1" svc="$2"
  awk -v svc="$svc" '
    /^services:[[:space:]]*$/ { in_s=1; next }
    in_s && /^[^[:space:]#]/ { in_s=0 }
    in_s && $0 ~ "^  "svc":[[:space:]]*$" { cur=1; next }
    in_s && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur=0 }
    cur && /^    image:/ { sub(/^    image:[[:space:]]*/,""); gsub(/["'\'']/,""); print; exit }
  ' "$file"
}

# compose_service_exposed_port FILE SERVICE : first container port from
# expose:/ports: (best-effort)
compose_service_port() {
  local file="$1" svc="$2"
  awk -v svc="$svc" '
    /^services:[[:space:]]*$/ { in_s=1; next }
    in_s && /^[^[:space:]#]/ { in_s=0 }
    in_s && $0 ~ "^  "svc":[[:space:]]*$" { cur=1; next }
    in_s && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur=0; list="" }
    cur && /^    (ports|expose):/ { list=1; next }
    cur && list && /^      - / {
      v=$0; sub(/^      - /,"",v); gsub(/["'\'']/,"",v)
      n=split(v,a,":"); p=a[n]; sub(/\/.*/,"",p); sub(/-.*/,"",p)
      if (p ~ /^[0-9]+$/) { print p; exit }
    }
    cur && list && !/^      / { list="" }
  ' "$file"
}

ssh_current_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
  printf '%s' "${p:-22}"
}

# service_active NAME
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

detect_summary_lines() {
  local lines=()
  lines+=("$(printf '%sOS%s        %s (%s)' "$C_GRAY" "$C_RESET" "$OS_PRETTY" "$ARCH")")
  lines+=("$(printf '%sResources%s %s vCPU, %s MB RAM, %s GB free on /' "$C_GRAY" "$C_RESET" "$CPU_COUNT" "$MEM_MB" "$DISK_FREE_GB")")
  lines+=("$(printf '%sPublic IP%s %s  %s(iface %s)%s' "$C_GRAY" "$C_RESET" "${HOST_PUBLIC_IP:-unknown}" "$C_DIM" "${HOST_PRIMARY_IFACE:-?}" "$C_RESET")")
  [[ -n "$SSH_CLIENT_IP" ]] && lines+=("$(printf '%sYour IP%s   %s %s(this SSH session)%s' "$C_GRAY" "$C_RESET" "$SSH_CLIENT_IP" "$C_DIM" "$C_RESET")")
  local have_list=()
  have docker && have_list+=("docker $(docker --version 2>/dev/null | sed -E 's/.*version ([0-9.]+).*/\1/')")
  have ufw && have_list+=("ufw")
  have fail2ban-client && have_list+=("fail2ban")
  have tailscale && have_list+=("tailscale")
  have caddy && have_list+=("caddy(host)")
  (( ${#have_list[@]} )) && lines+=("$(printf '%sPresent%s   %s' "$C_GRAY" "$C_RESET" "${have_list[*]}")")
  printf '%s\n' "${lines[@]}"
}
