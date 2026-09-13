#!/usr/bin/env bash
# Step: ops - private observability: container logs (Dozzle) + uptime monitoring (Uptime Kuma).
register_step ops "Ops tools" "Dozzle logs · Uptime Kuma · private (tailnet/localhost only)"

step_ops_config() {
  defcfg OPS_ENABLE false "Install private ops tools (never exposed publicly)"
  defcfg OPS_DOZZLE true "Dozzle: live container logs UI"
  defcfg OPS_UPTIME_KUMA true "Uptime Kuma: uptime checks + alerting"
  defcfg OPS_DOZZLE_PORT "9999" "Port for Dozzle on the private address"
  defcfg OPS_UPTIME_KUMA_PORT "3001" "Port for Uptime Kuma on the private address"
}

step_ops_enabled() { cfg_bool OPS_ENABLE && { cfg_bool OPS_DOZZLE || cfg_bool OPS_UPTIME_KUMA; }; }

step_ops_prompt() {
  ui_note "These bind to your Tailscale IP (or 127.0.0.1 without Tailscale) so only you can reach them."
  ask_yn "Install ops tools (Dozzle, Uptime Kuma)?" "$OPS_ENABLE" && OPS_ENABLE=true || OPS_ENABLE=false
  cfg_bool OPS_ENABLE || return 0
  ask_yn "Dozzle (container logs UI)?" "$OPS_DOZZLE" && OPS_DOZZLE=true || OPS_DOZZLE=false
  ask_yn "Uptime Kuma (uptime monitoring + alerts)?" "$OPS_UPTIME_KUMA" && OPS_UPTIME_KUMA=true || OPS_UPTIME_KUMA=false
}

ops_bind_ip() {
  local ip; ip=$(state_get tailscale.ip)
  [[ -z "$ip" ]] && ip=$(tailscale_ip 2>/dev/null || true)
  printf '%s' "${ip:-127.0.0.1}"
}

step_ops_plan() {
  local ip; ip=$(ops_bind_ip)
  cfg_bool OPS_DOZZLE && ui_bullet "Dozzle on http://$ip:$OPS_DOZZLE_PORT"
  cfg_bool OPS_UPTIME_KUMA && ui_bullet "Uptime Kuma on http://$ip:$OPS_UPTIME_KUMA_PORT"
  return 0
}

step_ops_apply() {
  local dir="$WIZARD_APPS_DIR/../ops"; dir=$(readlink -m "$dir")
  local OPS_BIND_IP OPS_DOZZLE_SERVICE="" OPS_UPTIME_KUMA_SERVICE=""
  OPS_BIND_IP=$(ops_bind_ip)
  if cfg_bool OPS_DOZZLE; then
    OPS_DOZZLE_SERVICE=$(cat <<EOF
  dozzle:
    image: amir20/dozzle:latest
    container_name: ops-dozzle
    restart: unless-stopped
    ports:
      - "$OPS_BIND_IP:$OPS_DOZZLE_PORT:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      DOZZLE_NO_ANALYTICS: "true"
    security_opt:
      - no-new-privileges:true
EOF
)
  fi
  if cfg_bool OPS_UPTIME_KUMA; then
    OPS_UPTIME_KUMA_SERVICE=$(cat <<EOF
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: ops-uptime-kuma
    restart: unless-stopped
    ports:
      - "$OPS_BIND_IP:$OPS_UPTIME_KUMA_PORT:3001"
    volumes:
      - uptime_kuma_data:/app/data
    networks:
      - default
      - proxy
    security_opt:
      - no-new-privileges:true
EOF
)
  fi
  export OPS_BIND_IP OPS_DOZZLE_SERVICE OPS_UPTIME_KUMA_SERVICE
  render_template ops-compose.yml | write_file "$dir/compose.yml" 0644
  ui_spin "Starting ops stack" docker compose --project-name ops -f "$dir/compose.yml" up -d --remove-orphans
  cfg_bool OPS_DOZZLE && ui_ok "Dozzle:      http://$OPS_BIND_IP:$OPS_DOZZLE_PORT"
  cfg_bool OPS_UPTIME_KUMA && ui_ok "Uptime Kuma: http://$OPS_BIND_IP:$OPS_UPTIME_KUMA_PORT"
  state_set ops.bind_ip "$OPS_BIND_IP"
  step_mark_done ops
}

step_ops_status() {
  local ip; ip=$(state_get ops.bind_ip)
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ops-dozzle$' && ui_kv "Dozzle" "http://$ip:$OPS_DOZZLE_PORT"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ops-uptime-kuma$' && ui_kv "Uptime Kuma" "http://$ip:$OPS_UPTIME_KUMA_PORT"
  return 0
}
