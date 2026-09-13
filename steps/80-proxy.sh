#!/usr/bin/env bash
# Step: proxy - edge reverse proxy with automatic TLS (Caddy default, Traefik optional).
register_step proxy "Reverse proxy & TLS" "Caddy or Traefik · Let's Encrypt · security headers · HTTP/3"

step_proxy_config() {
  defcfg PROXY_TYPE "caddy" "Edge proxy: caddy (recommended), traefik, or none"
  defcfg PROXY_EMAIL "" "E-mail for Let's Encrypt expiry notices"
  defcfg PROXY_MAX_BODY "50MB" "Max request body size (uploads) e.g. 50MB"
  defcfg PROXY_BEHIND_CLOUDFLARE "" "Trust Cloudflare as upstream proxy for real client IPs (empty = same as FIREWALL_CLOUDFLARE_ONLY)"
  defcfg TRAEFIK_RATE_AVG "50" "Traefik only: average requests/second per client IP"
  defcfg TRAEFIK_RATE_BURST "100" "Traefik only: request burst per client IP"
  defcfg TRAEFIK_INFLIGHT "50" "Traefik only: max concurrent requests per client IP"
}

step_proxy_enabled() { [[ "$PROXY_TYPE" != none ]]; }

step_proxy_prompt() {
  ui_note "One proxy container owns ports 80/443 and terminates TLS. Apps stay on an internal docker network."
  ask_choice "Reverse proxy" "$PROXY_TYPE" \
    "caddy|Caddy|automatic HTTPS, simplest config, HTTP/3 (recommended)" \
    "traefik|Traefik v3|label/file-driven routing, built-in rate limiting middleware" \
    "none|None|I'll handle ingress myself"
  PROXY_TYPE="$REPLY"
  [[ "$PROXY_TYPE" == none ]] && return 0
  ask_required "E-mail for Let's Encrypt" "$PROXY_EMAIL" valid_email; PROXY_EMAIL="$REPLY"
  ask "Max upload/body size" "$PROXY_MAX_BODY"; PROXY_MAX_BODY="$REPLY"
  local def_cf="$PROXY_BEHIND_CLOUDFLARE"; [[ -z "$def_cf" ]] && def_cf="$FIREWALL_CLOUDFLARE_ONLY"
  ask_yn "Is traffic proxied through Cloudflare (trust CF for real client IPs)?" "$def_cf" && PROXY_BEHIND_CLOUDFLARE=true || PROXY_BEHIND_CLOUDFLARE=false
  if [[ "$PROXY_TYPE" == traefik ]]; then
    ask "Rate limit: avg requests/s per IP" "$TRAEFIK_RATE_AVG" valid_int; TRAEFIK_RATE_AVG="$REPLY"
    ask "Rate limit: burst per IP" "$TRAEFIK_RATE_BURST" valid_int; TRAEFIK_RATE_BURST="$REPLY"
  fi
}

step_proxy_plan() {
  ui_bullet "Deploy $PROXY_TYPE in $WIZARD_PROXY_DIR on the 'proxy' network (80/443 tcp, 443 udp), ACME e-mail $PROXY_EMAIL"
  ui_bullet "Security headers, compression, request limits, JSON access log for fail2ban"
  proxy_behind_cf && ui_bullet "Trust Cloudflare ranges for client IP"
  return 0
}

proxy_behind_cf() {
  local v="$PROXY_BEHIND_CLOUDFLARE"; [[ -z "$v" ]] && v="$FIREWALL_CLOUDFLARE_ONLY"
  case "${v,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

# Cloudflare ranges (fetched live; falls back to the published list)
cloudflare_cidrs() {
  local list=""
  if have curl && [[ "$DRY_RUN" != true ]]; then
    list=$( { curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4; echo; curl -fsS --max-time 15 https://www.cloudflare.com/ips-v6; } 2>/dev/null | grep -E '^[0-9a-f.:/]+$' || true)
  fi
  if [[ -z "$list" ]]; then
    list="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
  fi
  printf '%s\n' "$list" | tr '\n' ' ' | sed 's/ *$//'
}

proxy_compose() { docker compose --project-name proxy -f "$WIZARD_PROXY_DIR/compose.yml" "$@"; }

proxy_reload() {
  [[ "$PROXY_TYPE" == none ]] && return 0
  case "$PROXY_TYPE" in
    caddy)
      if [[ "$DRY_RUN" != true ]] && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^proxy-caddy$'; then
        ui_warn "proxy-caddy is not running; start it with: vps-wizard step proxy"; return 1
      fi
      if ! run_try docker exec proxy-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
        ui_error "Caddyfile validation failed; not reloading."; return 1
      fi
      run_try docker exec proxy-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile ;;
    traefik) debug "traefik watches the dynamic dir; nothing to do" ;;
  esac
}

# proxy_write_site NAME DOMAIN UPSTREAM(host:port) HEALTH_PATH WWW_REDIRECT(true|false)
proxy_write_site() {
  local APP_NAME="$1" domain="$2" APP_UPSTREAM="$3" APP_HEALTHCHECK_PATH="${4:-/}" www="${5:-false}"
  export APP_NAME APP_UPSTREAM APP_HEALTHCHECK_PATH
  case "$PROXY_TYPE" in
    caddy)
      local SITE_HOSTS="$domain" SITE_WWW_REDIRECT=""
      if [[ "$www" == true ]]; then
        SITE_HOSTS="$domain, www.$domain"
        SITE_WWW_REDIRECT=$'\t@www host www.'"$domain"$'\n\tredir @www https://'"$domain"'{uri} permanent'
      fi
      export SITE_HOSTS SITE_WWW_REDIRECT
      render_template caddy-site.caddy | write_file "$WIZARD_PROXY_DIR/sites/$APP_NAME.caddy" 0644 ;;
    traefik)
      local TRAEFIK_RULE="Host(\`$domain\`)" TRAEFIK_WWW_MIDDLEWARE_REF="" TRAEFIK_WWW_MIDDLEWARE=""
      if [[ "$www" == true ]]; then
        TRAEFIK_RULE="Host(\`$domain\`) || Host(\`www.$domain\`)"
        TRAEFIK_WWW_MIDDLEWARE_REF="        - $APP_NAME-www@file"
        # Single-quoted YAML scalars keep regex backslashes literal.
        TRAEFIK_WWW_MIDDLEWARE=$(printf "  middlewares:\n    %s-www:\n      redirectRegex:\n        regex: '^https?://www\\\\.%s/(.*)'\n        replacement: 'https://%s/\${1}'\n        permanent: true" "$APP_NAME" "${domain//./\\.}" "$domain")
      fi
      export TRAEFIK_RULE TRAEFIK_WWW_MIDDLEWARE_REF TRAEFIK_WWW_MIDDLEWARE
      render_template traefik-site.yml | write_file "$WIZARD_PROXY_DIR/dynamic/$APP_NAME.yml" 0644 ;;
    none) return 0 ;;
  esac
}

proxy_remove_site() {
  local name="$1"
  run rm -f "$WIZARD_PROXY_DIR/sites/$name.caddy" "$WIZARD_PROXY_DIR/dynamic/$name.yml"
}

step_proxy_apply() {
  local PROXY_DIR="$WIZARD_PROXY_DIR" PROXY_LOG_DIR="$WIZARD_PROXY_DIR/logs"
  export PROXY_DIR PROXY_LOG_DIR PROXY_EMAIL
  [[ "$DRY_RUN" == true ]] || { mkdir -p "$PROXY_DIR/sites" "$PROXY_DIR/dynamic" "$PROXY_LOG_DIR"; chmod 755 "$PROXY_LOG_DIR"; }
  if [[ "$DRY_RUN" == true ]] || ! docker network inspect proxy >/dev/null 2>&1; then
    run docker network create --driver bridge --opt com.docker.network.bridge.name=br-proxy proxy
  fi
  local cf=""; proxy_behind_cf && cf=$(cloudflare_cidrs)
  case "$PROXY_TYPE" in
    caddy)
      local CADDY_TRUSTED_PROXIES="" CADDY_MAX_BODY="$PROXY_MAX_BODY"
      if [[ -n "$cf" ]]; then
        CADDY_TRUSTED_PROXIES=$'\t\ttrusted_proxies static '"$cf"$'\n\t\tclient_ip_headers CF-Connecting-IP X-Forwarded-For'
      fi
      export CADDY_TRUSTED_PROXIES CADDY_MAX_BODY
      render_template caddy-Caddyfile | write_file "$PROXY_DIR/Caddyfile" 0644
      # Keep the sites/*.caddy import glob non-empty before any app exists.
      write_file "$PROXY_DIR/sites/_placeholder.caddy" 0644 <<<'# Managed by vps-wizard: keeps the sites import glob valid. Do not delete.'
      render_template caddy-compose.yml | write_file "$PROXY_DIR/compose.yml" 0644
      if [[ "$DRY_RUN" != true ]]; then
        run_try docker run --rm -v "$PROXY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$PROXY_DIR/sites:/etc/caddy/sites:ro" caddy:2-alpine \
          caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || die "Generated Caddyfile is invalid (see log)."
      fi ;;
    traefik)
      local TRAEFIK_FORWARDED_HEADERS="" TRAEFIK_IP_DEPTH=0 TRAEFIK_MAX_BODY
      TRAEFIK_MAX_BODY=$(size_to_bytes "$PROXY_MAX_BODY")
      if [[ -n "$cf" ]]; then
        TRAEFIK_FORWARDED_HEADERS="    forwardedHeaders:"$'\n'"      trustedIPs: [$(printf '%s' "$cf" | sed 's/ /, /g')]"
        TRAEFIK_IP_DEPTH=1
      fi
      export TRAEFIK_FORWARDED_HEADERS TRAEFIK_IP_DEPTH TRAEFIK_MAX_BODY TRAEFIK_RATE_AVG TRAEFIK_RATE_BURST TRAEFIK_INFLIGHT
      render_template traefik-static.yml | write_file "$PROXY_DIR/traefik.yml" 0644
      render_template traefik-dynamic-middlewares.yml | write_file "$PROXY_DIR/dynamic/00-middlewares.yml" 0644
      render_template traefik-compose.yml | write_file "$PROXY_DIR/compose.yml" 0644 ;;
  esac
  ui_spin "Starting $PROXY_TYPE" docker compose --project-name proxy -f "$PROXY_DIR/compose.yml" up -d --remove-orphans
  state_set proxy.type "$PROXY_TYPE"
  ui_ok "$PROXY_TYPE is serving 80/443 (sites: $PROXY_DIR/$( [[ $PROXY_TYPE == caddy ]] && echo sites || echo dynamic)/)"
  step_mark_done proxy
}

size_to_bytes() {
  local s="${1^^}" n unit
  n=${s//[^0-9]/}; unit=${s//[0-9]/}
  case "$unit" in
    KB|K) echo $((n * 1024)) ;;
    MB|M|"") echo $((n * 1024 * 1024)) ;;
    GB|G) echo $((n * 1024 * 1024 * 1024)) ;;
    *) echo $((n)) ;;
  esac
}

step_proxy_status() {
  local t; t=$(state_get proxy.type); t=${t:-$PROXY_TYPE}
  ui_kv "Proxy" "$t"
  [[ "$t" == none ]] && return 0
  ui_kv "Container" "$(docker ps --filter "name=proxy-$t" --format '{{.Status}}' 2>/dev/null || echo 'not running')"
  local f
  for f in "$WIZARD_PROXY_DIR"/sites/*.caddy "$WIZARD_PROXY_DIR"/dynamic/*.yml; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in 00-middlewares.yml|_placeholder.caddy) continue ;; esac
    ui_kv "  site" "$(basename "${f%.*}")"
  done
  return 0
}
