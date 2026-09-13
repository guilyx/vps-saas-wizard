#!/usr/bin/env bash
# Step: preflight - sanity checks, nothing is changed.
register_step preflight "Preflight" "checks before we touch anything"

step_preflight_config() { :; }

step_preflight_enabled() { return 0; }

step_preflight_prompt() {
  ui_box "Host" "$(detect_summary_lines)"
  ui_blank
  local problems=0
  if ! is_root; then
    ui_error "Run as root (sudo -i) - the wizard installs packages and edits system config."
    problems=$((problems+1))
  fi
  if ! os_supported; then
    ui_warn "Untested OS: $OS_PRETTY. Debian 11-13 / Ubuntu 20.04-26.04 are supported; continuing anyway."
  fi
  if (( MEM_MB < 900 )); then
    ui_warn "Only ${MEM_MB}MB RAM. Docker builds may OOM - a swap file will be created."
  fi
  if (( DISK_FREE_GB < 8 )); then
    ui_warn "Only ${DISK_FREE_GB}GB free on /. Docker images need room; consider a bigger disk."
  fi
  if [[ "$ARCH" != x86_64 && "$ARCH" != aarch64 ]]; then
    ui_warn "Architecture $ARCH is unusual; Docker packages may not be available."
  fi
  if ! have systemctl; then
    ui_error "systemd is required."
    problems=$((problems+1))
  fi
  if [[ "$DRY_RUN" != true ]] && ! (have curl && curl -fsS --max-time 8 -o /dev/null https://download.docker.com/ 2>/dev/null); then
    if have curl; then ui_warn "Cannot reach download.docker.com - check outbound network."; fi
  fi
  if (( problems > 0 )) && [[ "$DRY_RUN" != true ]]; then
    die "Preflight found $problems blocking problem(s)."
  fi
  ui_ok "Preflight passed"
}

step_preflight_plan() {
  ui_bullet "Verify OS, resources and connectivity (no changes)"
}

step_preflight_apply() {
  apt_update_once
  apt_install ca-certificates curl gnupg lsb-release git jq unzip openssl apt-transport-https
  step_mark_done preflight
}

step_preflight_status() {
  ui_kv "OS" "$OS_PRETTY ($ARCH)"
  ui_kv "Resources" "$CPU_COUNT vCPU / ${MEM_MB}MB / ${DISK_FREE_GB}GB free"
  ui_kv "Public IP" "${HOST_PUBLIC_IP:-unknown}"
}
