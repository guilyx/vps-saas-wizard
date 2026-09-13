#!/usr/bin/env bash
# Step: hardening - sysctl network/kernel hardening and connection rate limits.
register_step hardening "Anti-DDoS & kernel hardening" "syncookies · rp_filter · per-IP connection limits · BBR"

step_hardening_config() {
  defcfg HARDEN_SYSCTL true "Apply kernel/network sysctl hardening (SYN cookies, anti-spoofing, BBR)"
  defcfg HARDEN_CONN_LIMITS true "Per-IP connection limits on ports 80/443 (iptables connlimit + hashlimit)"
  defcfg HARDEN_HTTP_CONNLIMIT "100" "Max concurrent connections per client IP to 80/443"
  defcfg HARDEN_HTTP_NEWCONN_RATE "30" "Max NEW connections per second per client IP to 80/443"
  defcfg HARDEN_HTTP_NEWCONN_BURST "100" "Burst allowance for new connections per client IP"
}

step_hardening_enabled() { cfg_bool HARDEN_SYSCTL || cfg_bool HARDEN_CONN_LIMITS; }

step_hardening_prompt() {
  ui_note "A VPS cannot absorb a volumetric DDoS alone (that's Cloudflare's job) but these make it survive floods, scans and slowloris-style abuse."
  ask_yn "Apply kernel network hardening via sysctl?" "$HARDEN_SYSCTL" && HARDEN_SYSCTL=true || HARDEN_SYSCTL=false
  ask_yn "Add per-IP connection limits on 80/443?" "$HARDEN_CONN_LIMITS" && HARDEN_CONN_LIMITS=true || HARDEN_CONN_LIMITS=false
  if cfg_bool HARDEN_CONN_LIMITS; then
    if cfg_bool FIREWALL_CLOUDFLARE_ONLY; then
      ui_warn "Behind Cloudflare all traffic comes from a few Cloudflare IPs; raising limits so legit traffic isn't throttled."
      [[ "$HARDEN_HTTP_CONNLIMIT" == 100 ]] && HARDEN_HTTP_CONNLIMIT=2000
      [[ "$HARDEN_HTTP_NEWCONN_RATE" == 30 ]] && HARDEN_HTTP_NEWCONN_RATE=500
      [[ "$HARDEN_HTTP_NEWCONN_BURST" == 100 ]] && HARDEN_HTTP_NEWCONN_BURST=1000
    fi
    ask "Max concurrent connections per IP" "$HARDEN_HTTP_CONNLIMIT" valid_int; HARDEN_HTTP_CONNLIMIT="$REPLY"
    ask "Max new connections per second per IP" "$HARDEN_HTTP_NEWCONN_RATE" valid_int; HARDEN_HTTP_NEWCONN_RATE="$REPLY"
    ask "Burst of new connections per IP" "$HARDEN_HTTP_NEWCONN_BURST" valid_int; HARDEN_HTTP_NEWCONN_BURST="$REPLY"
  fi
}

step_hardening_plan() {
  cfg_bool HARDEN_SYSCTL && ui_bullet "Write /etc/sysctl.d/99-vps-wizard.conf (SYN cookies, rp_filter, no redirects, BBR, conntrack sizing, kernel restrictions)"
  cfg_bool HARDEN_CONN_LIMITS && ui_bullet "ufw before.rules: max $HARDEN_HTTP_CONNLIMIT conns/IP, $HARDEN_HTTP_NEWCONN_RATE new conns/s/IP (burst $HARDEN_HTTP_NEWCONN_BURST), drop bogus TCP flags"
  return 0
}

step_hardening_apply() {
  if cfg_bool HARDEN_SYSCTL; then
    local CONNTRACK_MAX
    CONNTRACK_MAX=$(( MEM_MB * 64 )); (( CONNTRACK_MAX < 65536 )) && CONNTRACK_MAX=65536; (( CONNTRACK_MAX > 1048576 )) && CONNTRACK_MAX=1048576
    export CONNTRACK_MAX
    run_quiet modprobe nf_conntrack || true
    run_quiet modprobe tcp_bbr || true
    render_template sysctl-99-vps-wizard.conf | write_file /etc/sysctl.d/99-vps-wizard.conf 0644
    # sysctl --system returns non-zero if a single key is missing (e.g. no conntrack yet); tolerate.
    run_quiet sysctl --system || ui_warn "Some sysctl keys were not accepted on this kernel (see log); the rest are applied."
    ui_ok "sysctl hardening applied"
  fi
  if cfg_bool HARDEN_CONN_LIMITS; then
    apt_install ufw
    local HTTP_CONNLIMIT="$HARDEN_HTTP_CONNLIMIT" HTTP_NEWCONN_RATE="$HARDEN_HTTP_NEWCONN_RATE" HTTP_NEWCONN_BURST="$HARDEN_HTTP_NEWCONN_BURST"
    export HTTP_CONNLIMIT HTTP_NEWCONN_RATE HTTP_NEWCONN_BURST
    ufw_install_block /etc/ufw/before.rules ufw-before-ratelimit.rules
    if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then run ufw reload; fi
    ui_ok "Per-IP connection limits installed"
  fi
  step_mark_done hardening
}

step_hardening_status() {
  ui_kv "sysctl profile" "$([[ -f /etc/sysctl.d/99-vps-wizard.conf ]] && echo installed || echo missing)"
  ui_kv "tcp_syncookies" "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)"
  ui_kv "congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  ui_kv "conn limits" "$(grep -q 'VPS-WIZARD RATELIMIT' /etc/ufw/before.rules 2>/dev/null && echo installed || echo missing)"
}
