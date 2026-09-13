#!/usr/bin/env bash
# Step: tailscale - private network for admin access; optionally hide SSH from the internet.
register_step tailscale "Tailscale" "private admin network · optional SSH lock-down"

step_tailscale_config() {
  defcfg TAILSCALE_ENABLE false "Install Tailscale and join your tailnet"
  defcfg TAILSCALE_AUTH_KEY "" "Tailscale auth key (tskey-auth-...). Empty = interactive login URL"
  defcfg TAILSCALE_HOSTNAME "" "Machine name on the tailnet (empty = system hostname)"
  defcfg TAILSCALE_SSH true "Enable Tailscale SSH (auth via tailnet identity, no keys to manage)"
  defcfg TAILSCALE_RESTRICT_SSH false "Close the public SSH port; only allow SSH over Tailscale (arms the rollback safety net)"
  defcfg TAILSCALE_ADVERTISE_TAGS "" "ACL tags to advertise, e.g. tag:server (needs a tagged auth key)"
}

step_tailscale_enabled() { cfg_bool TAILSCALE_ENABLE; }

step_tailscale_prompt() {
  ui_note "Tailscale gives you a private WireGuard network: reach dashboards, databases and SSH without exposing them publicly."
  ask_yn "Install Tailscale?" "$TAILSCALE_ENABLE" && TAILSCALE_ENABLE=true || TAILSCALE_ENABLE=false
  cfg_bool TAILSCALE_ENABLE || { TAILSCALE_RESTRICT_SSH=false; return 0; }
  ui_note "Create a key at https://login.tailscale.com/admin/settings/keys (reusable off, ephemeral off, pre-approved on). Leave empty to get a login URL instead."
  ask_secret "Tailscale auth key (tskey-auth-...)" "$TAILSCALE_AUTH_KEY"; TAILSCALE_AUTH_KEY="$REPLY"
  ask "Machine name on the tailnet" "${TAILSCALE_HOSTNAME:-${SYS_HOSTNAME:-$(hostname)}}"; TAILSCALE_HOSTNAME="$REPLY"
  ask "ACL tags to advertise (empty for none)" "$TAILSCALE_ADVERTISE_TAGS"; TAILSCALE_ADVERTISE_TAGS="$REPLY"
  ask_yn "Enable Tailscale SSH?" "$TAILSCALE_SSH" && TAILSCALE_SSH=true || TAILSCALE_SSH=false
  ui_note "Locking SSH to Tailscale removes the public port entirely. The safety net re-opens it after ${ACCESS_ROLLBACK_MINUTES}m unless you confirm."
  ask_yn "Close the public SSH port and only allow SSH via Tailscale?" "$TAILSCALE_RESTRICT_SSH" && TAILSCALE_RESTRICT_SSH=true || TAILSCALE_RESTRICT_SSH=false
}

step_tailscale_plan() {
  have tailscale || ui_bullet "Install tailscale (pkgs.tailscale.com)"
  ui_bullet "tailscale up$(cfg_bool TAILSCALE_SSH && echo ' --ssh') --hostname ${TAILSCALE_HOSTNAME:-$(hostname)}$( [[ -n "$TAILSCALE_AUTH_KEY" ]] && echo ' --authkey ****' || echo ' (interactive login URL)')"
  cfg_bool TAILSCALE_RESTRICT_SSH && ui_bullet "ufw: remove public ${SSH_PORT}/tcp, keep SSH on tailscale0 only (rollback armed)"
  return 0
}

step_tailscale_apply() {
  if ! have tailscale; then
    ui_spin "Installing Tailscale" bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  fi
  run systemctl enable --now tailscaled
  local args=(up --hostname "${TAILSCALE_HOSTNAME:-$(hostname)}" --accept-dns=true --reset)
  cfg_bool TAILSCALE_SSH && args+=(--ssh)
  [[ -n "$TAILSCALE_ADVERTISE_TAGS" ]] && args+=(--advertise-tags="$TAILSCALE_ADVERTISE_TAGS")
  if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
    args+=(--auth-key "$TAILSCALE_AUTH_KEY")
    if [[ "$DRY_RUN" == true ]]; then ui_cmd "tailscale ${args[*]/$TAILSCALE_AUTH_KEY/****}"
    else
      log "RUN: tailscale up (auth key redacted)"
      tailscale "${args[@]}" >>"$WIZARD_LOG_FILE" 2>&1 || die "tailscale up failed (see $WIZARD_LOG_FILE). Check the auth key."
    fi
  else
    if [[ "$NONINTERACTIVE" == true && "$DRY_RUN" != true ]]; then
      if tailscale_running; then ui_ok "Tailscale already connected"
      else die "TAILSCALE_AUTH_KEY is required in non-interactive mode (or connect tailscale manually first)."; fi
    elif [[ "$DRY_RUN" == true ]]; then
      ui_cmd "tailscale ${args[*]}  (prints a login URL)"
    elif tailscale_running; then
      ui_ok "Tailscale already connected as $(tailscale_ip)"
      run_quiet tailscale set --ssh="$(cfg_bool TAILSCALE_SSH && echo true || echo false)" || true
    else
      ui_info "Open the URL below in your browser to authorise this machine:"
      tailscale "${args[@]}" 2>&1 | tee -a "$WIZARD_LOG_FILE" | sed 's/^/      /' || die "tailscale up failed"
    fi
  fi
  local tsip; tsip=$(tailscale_ip || true)
  [[ -n "$tsip" ]] && state_set tailscale.ip "$tsip"
  ui_ok "Tailscale up${tsip:+ ($tsip)}"

  if have ufw; then
    run ufw allow in on tailscale0 comment 'tailscale'
    run ufw allow 41641/udp comment 'tailscale direct'
  fi

  if cfg_bool TAILSCALE_RESTRICT_SSH; then
    if [[ "$DRY_RUN" != true ]] && ! tailscale_running; then
      ui_warn "Tailscale is not connected; NOT closing the public SSH port."
    else
      if [[ "$NONINTERACTIVE" != true ]]; then
        ui_blank
        ui_box "Verify before we close the public SSH port" \
          "Open a NEW terminal and connect over Tailscale:" \
          "  ssh $DEPLOY_USER@${tsip:-<tailscale-ip>}" \
          "Keep this session open. Only continue if that works."
        ask_yn "Tailscale SSH verified - close public SSH port now?" false || { ui_info "Leaving public SSH open. Set TAILSCALE_RESTRICT_SSH=true and re-run 'vps-wizard step tailscale' later."; step_mark_done tailscale; return 0; }
      fi
      run_quiet ufw --force delete allow "$SSH_PORT/tcp" || true
      run_quiet ufw --force delete limit "$SSH_PORT/tcp" || true
      run ufw allow in on tailscale0 to any port "$SSH_PORT" proto tcp comment 'ssh via tailscale'
      run ufw reload
      state_set ssh.restricted_to_tailscale "true"
      safety_arm "$ACCESS_ROLLBACK_MINUTES"
      ui_ok "Public SSH closed; SSH only via Tailscale (${tsip:-tailscale0})"
    fi
  fi
  step_mark_done tailscale
}

step_tailscale_status() {
  if have tailscale; then
    ui_kv "Tailscale" "$(tailscale_running && echo "connected $(tailscale_ip)" || echo 'not connected')"
    ui_kv "Tailscale SSH" "$(tailscale status --json 2>/dev/null | grep -q '"tailscale.com/cap/ssh"' && echo on || echo off)"
    ui_kv "Public SSH" "$([[ "$(state_get ssh.restricted_to_tailscale)" == true ]] && echo 'closed (tailnet only)' || echo open)"
  else
    ui_kv "Tailscale" "not installed"
  fi
}
