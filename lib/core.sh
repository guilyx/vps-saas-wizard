#!/usr/bin/env bash
# core.sh - logging, command execution, config and state handling.
# Sourced by bin/vps-wizard. Requires bash >= 4.

# ---------------------------------------------------------------------------
# Paths (overridable through the environment, mostly for tests)
# ---------------------------------------------------------------------------
: "${WIZARD_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
: "${WIZARD_ETC:=/etc/vps-wizard}"
: "${WIZARD_LOG_DIR:=/var/log/vps-wizard}"
: "${WIZARD_APPS_DIR:=/opt/apps}"
: "${WIZARD_PROXY_DIR:=/opt/proxy}"
: "${WIZARD_CONFIG:=$WIZARD_ETC/wizard.conf}"
: "${WIZARD_STATE:=$WIZARD_ETC/state}"
: "${WIZARD_REPORT:=$WIZARD_ETC/report.md}"

WIZARD_VERSION="1.0.0"
WIZARD_TEMPLATES="$WIZARD_HOME/templates"

# Runtime flags
DRY_RUN="${DRY_RUN:-false}"
NONINTERACTIVE="${NONINTERACTIVE:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
VERBOSE="${VERBOSE:-false}"
WIZARD_LOG_FILE=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_init() {
  if [[ "$DRY_RUN" == true ]]; then
    WIZARD_LOG_FILE="${TMPDIR:-/tmp}/vps-wizard-dry-run.log"
  else
    mkdir -p "$WIZARD_LOG_DIR" 2>/dev/null || WIZARD_LOG_DIR="${TMPDIR:-/tmp}"
    WIZARD_LOG_FILE="$WIZARD_LOG_DIR/wizard-$(date +%Y%m%d-%H%M%S).log"
  fi
  : >"$WIZARD_LOG_FILE" 2>/dev/null || WIZARD_LOG_FILE=/dev/null
  log "vps-wizard $WIZARD_VERSION starting (dry_run=$DRY_RUN noninteractive=$NONINTERACTIVE)"
}

log() {
  [[ -n "$WIZARD_LOG_FILE" ]] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$WIZARD_LOG_FILE"
}

debug() {
  log "DEBUG: $*"
  [[ "$VERBOSE" == true ]] && ui_dim "  $*"
  return 0
}

die() {
  ui_error "$*"
  log "FATAL: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------
# run_try CMD ARGS... : execute a mutating command. Printed but not executed
# in dry-run mode. Output goes to the log file; failures are reported and the
# exit code returned to the caller.
run_try() {
  local pretty
  pretty=$(printf '%q ' "$@")
  pretty=${pretty% }
  if [[ "$DRY_RUN" == true ]]; then
    ui_cmd "$pretty"
    log "DRY-RUN: $pretty"
    return 0
  fi
  log "RUN: $pretty"
  [[ "$VERBOSE" == true ]] && ui_cmd "$pretty"
  local rc=0
  if [[ "$VERBOSE" == true ]]; then
    "$@" 2>&1 | tee -a "$WIZARD_LOG_FILE"
    rc=${PIPESTATUS[0]}
  else
    "$@" >>"$WIZARD_LOG_FILE" 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    log "FAILED (rc=$rc): $pretty"
    ui_error "Command failed (exit $rc): $pretty"
    ui_dim "  See $WIZARD_LOG_FILE"
    [[ "$VERBOSE" == true ]] || tail -n 15 "$WIZARD_LOG_FILE" | sed 's/^/    │ /' >&2
  fi
  return "$rc"
}

# run CMD ARGS... : like run_try, but a failure aborts the wizard. This is the
# default for every mutating step command.
run() { run_try "$@" || die "Aborting: a required command failed."; }

# run_sh 'shell snippet' : same as run() but through bash -c (pipes, redirects)
run_sh() {
  if [[ "$DRY_RUN" == true ]]; then
    ui_cmd "$1"
    log "DRY-RUN: $1"
    return 0
  fi
  log "RUN: $1"
  [[ "$VERBOSE" == true ]] && ui_cmd "$1"
  local rc=0
  bash -o pipefail -c "$1" >>"$WIZARD_LOG_FILE" 2>&1 || rc=$?
  if (( rc != 0 )); then
    log "FAILED (rc=$rc): $1"
    ui_error "Command failed (exit $rc): $1"
    ui_dim "  See $WIZARD_LOG_FILE"
    tail -n 15 "$WIZARD_LOG_FILE" | sed 's/^/    │ /' >&2
    die "Aborting: a required command failed."
  fi
  return 0
}

# run_quiet : like run but never prints failure (caller handles)
run_quiet() {
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN(quiet): $*"
    return 0
  fi
  log "RUN(quiet): $*"
  "$@" >>"$WIZARD_LOG_FILE" 2>&1
}

# write_file PATH MODE  (content on stdin). Idempotent; dry-run prints a diff.
write_file() {
  local path="$1" mode="${2:-0644}" content tmp
  content=$(cat; printf x)   # keep trailing newlines
  content=${content%x}
  if [[ -f "$path" ]] && [[ "$(cat "$path"; printf x)" == "${content}x" ]]; then
    debug "unchanged: $path"
    [[ "$DRY_RUN" == true ]] || chmod "$mode" "$path" 2>/dev/null || true
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    ui_cmd "write $path (mode $mode)"
    log "DRY-RUN: write $path"
    if [[ "$VERBOSE" == true ]]; then
      printf '%s\n' "$content" | sed 's/^/      │ /'
    fi
    return 0
  fi
  log "WRITE: $path (mode $mode)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    cp -a "$path" "$path.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  tmp=$(mktemp "$(dirname "$path")/.vpsw.XXXXXX")
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

# render_template NAME  : substitutes {{VAR}} placeholders from the environment
# and prints to stdout. Missing variables render empty.
render_template() {
  local file="$WIZARD_TEMPLATES/$1"
  [[ -f "$file" ]] || die "template not found: $file"
  local line out key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    out=$line
    while [[ "$out" =~ \{\{([A-Za-z_][A-Za-z0-9_]*)\}\} ]]; do
      key=${BASH_REMATCH[1]}
      val=${!key-}
      out=${out//"{{$key}}"/$val}
    done
    printf '%s\n' "$out"
  done <"$file"
}

# ---------------------------------------------------------------------------
# Config handling. Config is a flat KEY=VALUE file (shell-sourceable subset).
# ---------------------------------------------------------------------------
CONFIG_KEYS=()

# defcfg KEY DEFAULT "description"  : declares a config key.
declare -A CFG_DEFAULT CFG_DESC
defcfg() {
  local key="$1" def="$2" desc="${3:-}"
  CONFIG_KEYS+=("$key")
  CFG_DEFAULT[$key]="$def"
  CFG_DESC[$key]="$desc"
  # Environment overrides win over defaults; existing values are preserved.
  if [[ -z "${!key+x}" ]]; then
    printf -v "$key" '%s' "$def"
  fi
  export "${key?}"
}

config_load() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%$'\r'}
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || {
      ui_warn "ignoring malformed config line: $line"; continue; }
    key=${BASH_REMATCH[2]}
    val=${BASH_REMATCH[3]}
    # strip quotes, or (for unquoted values) a trailing "# comment" and spaces
    if [[ "$val" =~ ^\"([^\"]*)\" ]] || [[ "$val" =~ ^\'([^\']*)\' ]]; then
      val=${BASH_REMATCH[1]}
    else
      val=${val%%[[:space:]]#*}
      [[ "$val" =~ ^#.*$ ]] && val=""
      val=${val%"${val##*[![:space:]]}"}
    fi
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done <"$file"
  log "config loaded from $file"
  return 0
}

config_dump() {
  local key val
  printf '# vps-wizard configuration (generated %s)\n' "$(date -Is)"
  printf '# Re-apply with: vps-wizard apply --config <this file> --yes\n\n'
  for key in "${CONFIG_KEYS[@]}"; do
    val=${!key-}
    [[ -n "${CFG_DESC[$key]}" ]] && printf '# %s\n' "${CFG_DESC[$key]}"
    printf '%s=%q\n\n' "$key" "$val"
  done
}

config_save() {
  local file="${1:-$WIZARD_CONFIG}"
  if [[ "$DRY_RUN" == true ]]; then
    ui_cmd "save config -> $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  config_dump >"$file.tmp"
  chmod 600 "$file.tmp"
  mv -f "$file.tmp" "$file"
  log "config saved to $file"
}

# cfg_bool KEY : returns 0 if the key is truthy
cfg_bool() {
  local v=${!1-}
  case "${v,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# State: which steps completed, plus arbitrary facts (tailscale ip, etc.)
# ---------------------------------------------------------------------------
state_set() {
  local key="$1" val="$2"
  [[ "$DRY_RUN" == true ]] && return 0
  mkdir -p "$WIZARD_STATE"
  printf '%s\n' "$val" >"$WIZARD_STATE/$key"
}

state_get() {
  local key="$1"
  [[ -f "$WIZARD_STATE/$key" ]] && cat "$WIZARD_STATE/$key"
  return 0
}

state_has() { [[ -f "$WIZARD_STATE/$1" ]]; }

step_mark_done() { state_set "step.$1" "$(date -Is)"; }
step_is_done() { state_has "step.$1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "$(id -u)" == 0 ]]; }

require_root() {
  is_root || die "This command must run as root (try: sudo vps-wizard $*)"
}

gen_secret() {
  local len="${1:-32}"
  if have openssl; then
    openssl rand -hex "$len" | head -c "$((len * 2))"
  else
    head -c "$len" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

join_by() { local IFS="$1"; shift; printf '%s' "$*"; }

# split_list "a, b,c" -> lines
split_list() { printf '%s\n' "$1" | tr ',; ' '\n\n\n' | sed '/^$/d'; }

apt_install() {
  local pkgs=("$@") missing=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  (( ${#missing[@]} == 0 )) && { debug "already installed: ${pkgs[*]}"; return 0; }
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
}

apt_update_once() {
  [[ -n "${_APT_UPDATED:-}" ]] && return 0
  _APT_UPDATED=1
  run env DEBIAN_FRONTEND=noninteractive apt-get update -q
}

# public_ip : best-effort public IPv4 (override with WIZARD_PUBLIC_IP)
public_ip() {
  local ip="${WIZARD_PUBLIC_IP:-}"
  if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
  if have curl; then
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  fi
  [[ -z "$ip" ]] && ip=$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  printf '%s' "$ip"
  return 0
}

tailscale_ip() {
  have tailscale || return 1
  tailscale ip -4 2>/dev/null | head -1
}

tailscale_running() {
  have tailscale || return 1
  tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'
}
