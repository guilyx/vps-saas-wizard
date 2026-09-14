#!/usr/bin/env bash
# Test runner: unit tests for lib functions + full dry-run of the wizard.
# Runs anywhere (no root, no docker needed). Usage: bash tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export WIZARD_HOME="$ROOT" WIZARD_ETC="$SANDBOX/etc" WIZARD_APPS_DIR="$SANDBOX/apps" WIZARD_PROXY_DIR="$SANDBOX/proxy"
export NO_COLOR=1 NONINTERACTIVE=true TMPDIR="$SANDBOX" WIZARD_PUBLIC_IP=203.0.113.10

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*" >&2; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3: expected '$2' got '$1'"; fi; }
assert_true() { if "$@" >/dev/null 2>&1; then ok "$*"; else fail "$* (expected success)"; fi; }
assert_false() { if "$@" >/dev/null 2>&1; then fail "$* (expected failure)"; else ok "! $*"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else fail "$3: missing '$2'"; fi; }

# --- load libraries ---------------------------------------------------------
. "$ROOT/lib/core.sh"; . "$ROOT/lib/ui.sh"; . "$ROOT/lib/validate.sh"; . "$ROOT/lib/detect.sh"
STEPS=(); declare -A STEP_TITLE STEP_SUB
register_step() { STEPS+=("$1"); STEP_TITLE[$1]="$2"; STEP_SUB[$1]="${3:-}"; }
for f in "$ROOT"/steps/*.sh; do . "$f"; done
for s in "${STEPS[@]}"; do "step_${s}_config"; done
DRY_RUN=true; log_init

echo "== validators"
assert_true valid_domain app.example.com
assert_true valid_domain sub.app.example.co.uk
assert_false valid_domain localhost
assert_false valid_domain "http://x.com"
assert_true valid_email ops@example.com
assert_false valid_email nope
assert_true valid_port 443
assert_false valid_port 70000
assert_true valid_port_list "8080,9000"
assert_true valid_port_list ""
assert_false valid_port_list "80,abc"
assert_true valid_username deploy
assert_false valid_username Deploy
assert_true valid_slug my-app
assert_false valid_slug "My App"
assert_true valid_hhmm 03:30
assert_false valid_hhmm 24:00
assert_true valid_duration 10m
assert_true valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA x"
assert_false valid_ssh_pubkey "not a key"
assert_true valid_git_or_path_or_empty "git@github.com:me/app.git"
assert_true valid_git_or_path_or_empty ""
assert_false valid_git_or_path_or_empty "/definitely/not/here"

echo "== ui_fill (must stay multibyte-safe: tr would emit only the first byte)"
assert_eq "$(ui_fill '-' 5)" "-----" "ascii glyph repeats"
assert_eq "$(ui_fill '─' 3)" "───" "box-drawing glyph repeats intact"
assert_eq "$(ui_fill '─' 3 | wc -c | tr -d ' ')" 9 "3 glyphs are 9 bytes, not 3"
assert_eq "$(ui_fill '─' 0)" "" "zero count prints nothing"
assert_eq "$(ui_fill '█' 2)" "██" "block glyph repeats intact"

echo "== config load/save"
cat >"$SANDBOX/c.conf" <<'EOF'
# comment
APP_NAME=shop
APP_DOMAIN="shop.example.com"
PROXY_EMAIL='a@b.co'
export SSH_PORT=2222
SYS_SWAP_GB=auto              # inline comment
SYS_HOSTNAME=                 # empty with comment
FAIL2BAN_IGNOREIP="1.2.3.4 5.6.7.8"   # quoted with comment
BAD LINE
EOF
config_load "$SANDBOX/c.conf" 2>/dev/null
assert_eq "$APP_NAME" shop "plain value"
assert_eq "$APP_DOMAIN" shop.example.com "double-quoted value"
assert_eq "$PROXY_EMAIL" a@b.co "single-quoted value"
assert_eq "$SSH_PORT" 2222 "export prefix"
assert_eq "$SYS_SWAP_GB" auto "inline comment stripped"
assert_eq "$SYS_HOSTNAME" "" "empty value with comment"
assert_eq "$FAIL2BAN_IGNOREIP" "1.2.3.4 5.6.7.8" "quoted value keeps spaces, drops comment"
dump=$(config_dump)
assert_contains "$dump" "APP_NAME=shop" "dump contains key"
assert_contains "$dump" "# Public domain for the app" "dump contains description"
config_load "$ROOT/examples/wizard.conf.example" 2>/dev/null
assert_eq "$PROXY_TYPE" caddy "example config loads"
assert_eq "$HARDEN_HTTP_CONNLIMIT" 100 "example config numeric with comment"

echo "== templates"
export CONNTRACK_MAX=131072
out=$(render_template sysctl-99-vps-wizard.conf)
assert_contains "$out" "nf_conntrack_max = 131072" "placeholder substituted"
assert_false grep -q '{{' <<<"$out"
export SSH_PORT=2222 SSH_PERMIT_ROOT=no SSH_PASSWORD_AUTH=no SSH_EXTRA_AUTH_METHODS="" SSH_ALLOW_USERS=deploy
out=$(render_template sshd-hardening.conf)
assert_contains "$out" "Port 2222" "sshd port"
assert_contains "$out" "AuthenticationMethods publickey" "sshd auth methods"
assert_contains "$out" "AllowUsers deploy" "sshd allowusers"

echo "== write_file"
DRY_RUN=false
printf 'hello\n' | write_file "$SANDBOX/f.txt" 0600
assert_eq "$(cat "$SANDBOX/f.txt")" hello "write_file content"
assert_eq "$(stat -c %a "$SANDBOX/f.txt")" 600 "write_file mode"
count_backups() { local n=0 f; for f in "$SANDBOX"/f.txt.bak.*; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }
printf 'hello\n' | write_file "$SANDBOX/f.txt" 0600
assert_eq "$(count_backups)" 0 "unchanged file not backed up"
printf 'world\n' | write_file "$SANDBOX/f.txt" 0600
assert_eq "$(count_backups)" 1 "changed file backed up"
DRY_RUN=true

echo "== env parsing"
cat >"$SANDBOX/.env.example" <<'EOF'
# Database connection
DATABASE_URL=postgres://user:pass@db:5432/app
# Session secret
SESSION_SECRET=
APP_URL=
QUOTED="with spaces"
export EXPORTED=1
EOF
rows=$(parse_env_file "$SANDBOX/.env.example")
assert_eq "$(awk -F"$ENV_SEP" '$1=="DATABASE_URL"{print $3}' <<<"$rows")" "Database connection" "comment captured"
assert_eq "$(awk -F"$ENV_SEP" '$1=="QUOTED"{print $2}' <<<"$rows")" "with spaces" "quotes stripped"
assert_eq "$(awk -F"$ENV_SEP" '$1=="EXPORTED"{print $2}' <<<"$rows")" "1" "export prefix parsed"
assert_eq "$(env_quote simple)" simple "env_quote plain"
assert_eq "$(env_quote 'has space')" '"has space"' "env_quote spaces"
assert_eq "$(env_quote 'a$b')" '"a$$b"' "env_quote dollar"
assert_true is_secret_key SESSION_SECRET
assert_true is_secret_key DB_PASSWORD
assert_true is_secret_key JWT_KEY
assert_false is_secret_key APP_URL
assert_false is_secret_key DATABASE_URL
assert_true is_url_key NEXTAUTH_URL
assert_true is_sensitive_key DATABASE_URL
assert_true is_sensitive_key REDIS_URI
assert_false is_sensitive_key APP_URL
assert_false is_sensitive_key LOG_LEVEL

echo "== app_build_env (non-interactive)"
DRY_RUN=false
mkdir -p "$SANDBOX/apps/demo/src"; cp "$SANDBOX/.env.example" "$SANDBOX/apps/demo/src/.env.example"
APP_NAME=demo APP_DOMAIN=demo.example.com APP_ENV_VARS="DATABASE_URL=postgres://x:y@db/z,EXTRA=1" APP_ENV_AUTOGEN_SECRETS=true
app_build_env "$SANDBOX/apps/demo" "$SANDBOX/apps/demo/src" >/dev/null
envf="$SANDBOX/apps/demo/.env"
assert_eq "$(stat -c %a "$envf")" 600 ".env mode 600"
assert_eq "$(env_lookup "$envf" DATABASE_URL)" "postgres://x:y@db/z" "override applied"
assert_eq "$(env_lookup "$envf" APP_URL)" "https://demo.example.com" "url key defaulted to domain"
secret=$(env_lookup "$envf" SESSION_SECRET)
assert_eq "${#secret}" 64 "secret generated (64 hex)"
assert_eq "$(env_lookup "$envf" EXTRA)" "1" "extra var appended"
# second run keeps the generated secret
first=$(env_lookup "$envf" SESSION_SECRET)
app_build_env "$SANDBOX/apps/demo" "$SANDBOX/apps/demo/src" >/dev/null
assert_eq "$(env_lookup "$envf" SESSION_SECRET)" "$first" "secret preserved on re-run"
DRY_RUN=true

echo "== port_listening (must not report a missing probe tool as a closed port)"
python3 -m http.server 18731 --bind 127.0.0.1 >/dev/null 2>&1 &
probe_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port_listening 18731 && break
  sleep 0.3
done
port_listening 18731; assert_eq $? 0 "detects an open port"
port_listening 18732; assert_eq $? 1 "reports a closed port"
# With ss/lsof/netstat absent it must fall back to /proc, not claim "closed".
mkdir -p "$SANDBOX/minbin"
for t in awk grep; do ln -sf "$(command -v "$t")" "$SANDBOX/minbin/$t"; done
# shellcheck disable=SC2123  # deliberately narrowing PATH to hide the probe tools
( PATH="$SANDBOX/minbin"; port_listening 18731 ); assert_eq $? 0 "falls back to /proc when ss/lsof/netstat are absent"
# shellcheck disable=SC2123
( PATH="$SANDBOX/minbin"; port_listening 18732 ); assert_eq $? 1 "/proc fallback still reports closed ports"
kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null

echo "== compose parsing"
cat >"$SANDBOX/compose.yml" <<'EOF'
services:
  web:
    image: ghcr.io/acme/web:1.2
    ports:
      - "127.0.0.1:8080:3000"
  worker:
    image: ghcr.io/acme/worker
  db:
    image: postgres:16
    expose:
      - "5432"
volumes:
  data:
EOF
assert_eq "$(compose_services "$SANDBOX/compose.yml" | tr '\n' ' ')" "web worker db " "services listed"
assert_eq "$(compose_service_port "$SANDBOX/compose.yml" web)" 3000 "container port from ports"
assert_eq "$(compose_service_port "$SANDBOX/compose.yml" db)" 5432 "container port from expose"
assert_eq "$(compose_service_image "$SANDBOX/compose.yml" db)" postgres:16 "service image"
assert_eq "$(detect_compose_file "$SANDBOX")" compose.yml "compose file detected"

echo "== proxy site rendering"
DRY_RUN=false
mkdir -p "$WIZARD_PROXY_DIR/sites" "$WIZARD_PROXY_DIR/dynamic"
PROXY_TYPE=caddy proxy_write_site shop shop.example.com web:3000 /healthz true
site=$(cat "$WIZARD_PROXY_DIR/sites/shop.caddy")
assert_contains "$site" "shop.example.com, www.shop.example.com {" "caddy hosts incl www"
assert_contains "$site" "reverse_proxy web:3000" "caddy upstream"
assert_contains "$site" "health_uri /healthz" "caddy health"
PROXY_TYPE=traefik proxy_write_site shop shop.example.com web:3000 /healthz true
site=$(cat "$WIZARD_PROXY_DIR/dynamic/shop.yml")
assert_contains "$site" 'rule: "Host(`shop.example.com`) || Host(`www.shop.example.com`)"' "traefik rule"
assert_contains "$site" 'url: "http://web:3000"' "traefik upstream"
assert_contains "$site" "shop-www@file" "traefik www middleware referenced"
assert_eq "$(size_to_bytes 50MB)" 52428800 "size_to_bytes MB"
assert_eq "$(size_to_bytes 1GB)" 1073741824 "size_to_bytes GB"
DRY_RUN=true

echo "== config validation"
PROXY_TYPE=caddy PROXY_EMAIL=ops@example.com APP_ENABLE=true APP_NAME=demo APP_DOMAIN=demo.example.com APP_PORT="" APP_SOURCE="" \
  DEPLOY_USER=deploy SSH_PORT=22 SYS_TIMEZONE=UTC BACKUP_TIME=03:30 DEPLOY_USER_SSH_KEY="ssh-ed25519 AAAA x" TAILSCALE_ENABLE=false TAILSCALE_RESTRICT_SSH=false
assert_true validate_config
APP_DOMAIN=bad; assert_false validate_config; APP_DOMAIN=demo.example.com
TAILSCALE_RESTRICT_SSH=true; assert_false validate_config; TAILSCALE_RESTRICT_SSH=false
PROXY_EMAIL=""; assert_false validate_config; PROXY_EMAIL=ops@example.com

echo "== CLI dry runs"
cat >"$SANDBOX/full.conf" <<'EOF'
PROXY_EMAIL=ops@example.com
APP_DOMAIN=app.example.com
APP_NAME=demo
DEPLOY_USER_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test"
TAILSCALE_ENABLE=true
TAILSCALE_AUTH_KEY=tskey-auth-test
TAILSCALE_RESTRICT_SSH=true
OPS_ENABLE=true
FIREWALL_CLOUDFLARE_ONLY=true
BACKUP_RESTIC_REPOSITORY=s3:s3.example.com/bucket
EOF
out=$("$ROOT/bin/vps-wizard" plan -c "$SANDBOX/full.conf" 2>&1); rc=$?
assert_eq "$rc" 0 "plan exits 0"
assert_contains "$out" "12/12" "plan runs all 12 steps"
assert_contains "$out" "ufw limit 22/tcp" "plan includes ufw ssh rule"
assert_contains "$out" "tailscale up --hostname" "plan includes tailscale"
assert_contains "$out" "--auth-key ****" "auth key redacted"
assert_contains "$out" "Starting caddy" "plan starts caddy"
assert_contains "$out" "demo deployed" "plan deploys app"
assert_false grep -q "tskey-auth-test" <<<"$out"

out=$("$ROOT/bin/vps-wizard" plan -c "$SANDBOX/full.conf" --only firewall,docker 2>&1)
assert_contains "$out" "2/2" "--only limits steps"
out=$(PROXY_TYPE=traefik "$ROOT/bin/vps-wizard" plan -c "$SANDBOX/full.conf" --only proxy 2>&1)
assert_contains "$out" "Starting traefik" "env override switches proxy"
out=$("$ROOT/bin/vps-wizard" plan -c "$SANDBOX/full.conf" --skip tailscale,ops,backups 2>&1)
assert_contains "$out" "9/9" "--skip removes steps"
out=$("$ROOT/bin/vps-wizard" list-steps)
assert_eq "$(head -1 <<<"$out")" preflight "list-steps first"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" 12 "list-steps count"
assert_eq "$("$ROOT/bin/vps-wizard" config APP_NAME -c "$SANDBOX/full.conf")" demo "config KEY"
"$ROOT/bin/vps-wizard" --help >/dev/null 2>&1; assert_eq $? 0 "--help exits 0"
"$ROOT/bin/vps-wizard" bogus >/dev/null 2>&1; assert_eq $? 1 "unknown command exits 1"
out=$("$ROOT/bin/vps-wizard" plan -c "$SANDBOX/missing.conf" 2>&1); assert_contains "$out" "not found" "missing config reported"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
