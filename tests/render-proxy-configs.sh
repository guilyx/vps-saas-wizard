#!/usr/bin/env bash
# Renders the proxy + demo app configuration into a sandbox directory without
# touching the system, so CI can validate the generated files with the real
# caddy / traefik / docker compose binaries.
#   PROXY_TYPE=caddy|traefik bash tests/render-proxy-configs.sh /tmp/out
set -uo pipefail
OUT="${1:?usage: render-proxy-configs.sh OUT_DIR}"
export WIZARD_ETC="$OUT/etc" WIZARD_APPS_DIR="$OUT/apps" WIZARD_PROXY_DIR="$OUT/proxy"
export NONINTERACTIVE=true DRY_RUN=false NO_COLOR=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WIZARD_HOME="$ROOT"
. "$ROOT/lib/core.sh"; . "$ROOT/lib/ui.sh"; . "$ROOT/lib/validate.sh"; . "$ROOT/lib/detect.sh"
STEPS=(); declare -A STEP_TITLE STEP_SUB
register_step() { STEPS+=("$1"); STEP_TITLE[$1]="$2"; STEP_SUB[$1]="${3:-}"; }
for f in "$ROOT"/steps/*.sh; do . "$f"; done
for s in "${STEPS[@]}"; do "step_${s}_config"; done
log_init >/dev/null 2>&1 || true

PROXY_TYPE="${PROXY_TYPE:-caddy}"
PROXY_EMAIL=ops@example.com
PROXY_BEHIND_CLOUDFLARE="${PROXY_BEHIND_CLOUDFLARE:-true}"
APP_NAME=demo APP_DOMAIN=app.example.com APP_WWW_REDIRECT=true APP_SERVICE=web APP_PORT=80 APP_HEALTHCHECK_PATH=/health
APP_ENV_VARS="APP_TITLE=Hello World,DATABASE_URL=postgres://u:p@db/app?sslmode=disable"

mkdir -p "$WIZARD_PROXY_DIR/sites" "$WIZARD_PROXY_DIR/dynamic" "$WIZARD_PROXY_DIR/logs" "$WIZARD_APPS_DIR/demo/src"
PROXY_DIR="$WIZARD_PROXY_DIR" PROXY_LOG_DIR="$WIZARD_PROXY_DIR/logs"; export PROXY_DIR PROXY_LOG_DIR PROXY_EMAIL
cf=$(cloudflare_cidrs)
case "$PROXY_TYPE" in
  caddy)
    CADDY_TRUSTED_PROXIES=$'\t\ttrusted_proxies static '"$cf"$'\n\t\tclient_ip_headers CF-Connecting-IP X-Forwarded-For'
    CADDY_MAX_BODY=50MB; export CADDY_TRUSTED_PROXIES CADDY_MAX_BODY
    render_template caddy-Caddyfile | write_file "$PROXY_DIR/Caddyfile" 0644
    render_template caddy-compose.yml | write_file "$PROXY_DIR/compose.yml" 0644 ;;
  traefik)
    TRAEFIK_FORWARDED_HEADERS="    forwardedHeaders:"$'\n'"      trustedIPs: [$(printf '%s' "$cf" | sed 's/ /, /g')]"
    TRAEFIK_IP_DEPTH=1 TRAEFIK_MAX_BODY=$(size_to_bytes 50MB)
    export TRAEFIK_FORWARDED_HEADERS TRAEFIK_IP_DEPTH TRAEFIK_MAX_BODY TRAEFIK_RATE_AVG TRAEFIK_RATE_BURST TRAEFIK_INFLIGHT
    render_template traefik-static.yml | write_file "$PROXY_DIR/traefik.yml" 0644
    render_template traefik-dynamic-middlewares.yml | write_file "$PROXY_DIR/dynamic/00-middlewares.yml" 0644
    render_template traefik-compose.yml | write_file "$PROXY_DIR/compose.yml" 0644 ;;
esac
proxy_write_site "$APP_NAME" "$APP_DOMAIN" "$APP_SERVICE:$APP_PORT" "$APP_HEALTHCHECK_PATH" "$APP_WWW_REDIRECT"
app_scaffold_demo "$WIZARD_APPS_DIR/demo/src"
app_build_env "$WIZARD_APPS_DIR/demo" "$WIZARD_APPS_DIR/demo/src"
APP_COMPOSE_FILE=compose.yml APP_SOURCE="" APP_BRANCH=main
app_write_meta "$WIZARD_APPS_DIR/demo" "$WIZARD_APPS_DIR/demo/src"
echo "rendered $PROXY_TYPE configs into $OUT"
find "$OUT" -type f | sort
