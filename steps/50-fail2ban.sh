#!/usr/bin/env bash
# Step: fail2ban - ban brute-forcers on SSH and abusive clients on the proxy.
register_step fail2ban "fail2ban" "ban brute force on SSH · ban 4xx floods on the proxy"

step_fail2ban_config() {
  defcfg FAIL2BAN_ENABLE true "Install fail2ban"
  defcfg FAIL2BAN_BANTIME "1h" "Initial ban duration (doubles for repeat offenders, max 1w)"
  defcfg FAIL2BAN_FINDTIME "10m" "Window in which failures are counted"
  defcfg FAIL2BAN_MAXRETRY "5" "Failures allowed within the window"
  defcfg FAIL2BAN_HTTP_JAIL true "Also ban IPs producing bursts of 4xx on the reverse proxy (bots/scanners)"
  defcfg FAIL2BAN_HTTP_MAXRETRY "60" "4xx responses within findtime before an HTTP ban"
  defcfg FAIL2BAN_IGNOREIP "" "Extra IPs/CIDRs never to ban (your office IP), space separated"
}

step_fail2ban_enabled() { cfg_bool FAIL2BAN_ENABLE; }

step_fail2ban_prompt() {
  ask_yn "Install fail2ban?" "$FAIL2BAN_ENABLE" && FAIL2BAN_ENABLE=true || FAIL2BAN_ENABLE=false
  cfg_bool FAIL2BAN_ENABLE || return 0
  ask "Ban time" "$FAIL2BAN_BANTIME" valid_duration; FAIL2BAN_BANTIME="$REPLY"
  ask "Find time window" "$FAIL2BAN_FINDTIME" valid_duration; FAIL2BAN_FINDTIME="$REPLY"
  ask "Max retries before ban" "$FAIL2BAN_MAXRETRY" valid_int; FAIL2BAN_MAXRETRY="$REPLY"
  if [[ "$PROXY_TYPE" != none ]]; then
    ask_yn "Ban IPs that hammer the proxy with 4xx (scanners, credential stuffing)?" "$FAIL2BAN_HTTP_JAIL" && FAIL2BAN_HTTP_JAIL=true || FAIL2BAN_HTTP_JAIL=false
  else
    FAIL2BAN_HTTP_JAIL=false
  fi
  local def_ignore="$FAIL2BAN_IGNOREIP"
  [[ -z "$def_ignore" && -n "$SSH_CLIENT_IP" ]] && def_ignore="$SSH_CLIENT_IP"
  ask "Never ban these IPs (space separated; your current IP is a good idea)" "$def_ignore"; FAIL2BAN_IGNOREIP="$REPLY"
}

step_fail2ban_plan() {
  ui_bullet "fail2ban: sshd (aggressive) + recidive, ban $FAIL2BAN_BANTIME after $FAIL2BAN_MAXRETRY fails in $FAIL2BAN_FINDTIME, escalating"
  cfg_bool FAIL2BAN_HTTP_JAIL && ui_bullet "HTTP jail on $PROXY_TYPE access log: $FAIL2BAN_HTTP_MAXRETRY 4xx in $FAIL2BAN_FINDTIME → ban"
  return 0
}

step_fail2ban_apply() {
  apt_install fail2ban python3-systemd
  local FAIL2BAN_HTTP_SECTION="" DATEPATTERN
  if cfg_bool FAIL2BAN_HTTP_JAIL && [[ "$PROXY_TYPE" != none ]]; then
    local logdir="$WIZARD_PROXY_DIR/logs"
    case "$PROXY_TYPE" in
      caddy) DATEPATTERN='LEpoch' ;;
      *) DATEPATTERN='%%Y-%%m-%%dT%%H:%%M:%%S' ;;
    esac
    export DATEPATTERN
    render_template fail2ban-filter-http-flood.conf | write_file /etc/fail2ban/filter.d/vps-http-flood.conf 0644
    [[ "$DRY_RUN" == true ]] || { mkdir -p "$logdir"; touch "$logdir/access.log"; }
    FAIL2BAN_HTTP_SECTION=$(cat <<EOF
[vps-http-flood]
enabled  = true
backend  = polling
filter   = vps-http-flood
logpath  = $logdir/access.log
port     = http,https
maxretry = $FAIL2BAN_HTTP_MAXRETRY
findtime = $FAIL2BAN_FINDTIME
bantime  = $FAIL2BAN_BANTIME
banaction = ufw
EOF
)
  fi
  export FAIL2BAN_HTTP_SECTION FAIL2BAN_BANTIME FAIL2BAN_FINDTIME FAIL2BAN_MAXRETRY FAIL2BAN_IGNOREIP SSH_PORT
  render_template fail2ban-jail.local | write_file /etc/fail2ban/jail.d/vps-wizard.local 0644
  # ufw banaction needs the ufw action file (ships with fail2ban) - and the
  # docker forward path: also insert into DOCKER-USER via a small action tweak.
  write_file /etc/fail2ban/action.d/ufw.local 0644 <<'EOF'
# Managed by vps-wizard: ufw bans must also cover Docker-published ports,
# which bypass INPUT. We add/remove a matching DOCKER-USER drop rule.
[Definition]
actionban = ufw <add> <blocktype> from <ip> to <destination>
            iptables -I DOCKER-USER -s <ip> -j DROP 2>/dev/null || true
actionunban = ufw delete <add> <blocktype> from <ip> to <destination>
              iptables -D DOCKER-USER -s <ip> -j DROP 2>/dev/null || true
EOF
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  ui_ok "fail2ban active (sshd, recidive$(cfg_bool FAIL2BAN_HTTP_JAIL && echo ', vps-http-flood'))"
  step_mark_done fail2ban
}

step_fail2ban_status() {
  if have fail2ban-client; then
    ui_kv "fail2ban" "$(service_active fail2ban && echo active || echo inactive)"
    local j
    for j in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/,/,"",$2); print $2}'); do
      ui_kv "  jail $j" "$(fail2ban-client status "$j" 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2" banned"}')"
    done
  else
    ui_kv "fail2ban" "not installed"
  fi
}
