#!/usr/bin/env bash
# Step: firewall - UFW default-deny, docker-aware, optional Cloudflare-only web.
register_step firewall "Firewall" "ufw default-deny · docker-aware · rate-limited SSH"

step_firewall_config() {
  defcfg FIREWALL_ENABLE true "Configure UFW (deny incoming by default)"
  defcfg FIREWALL_SSH_RATE_LIMIT true "Rate-limit new SSH connections (6 per 30s per IP)"
  defcfg FIREWALL_EXTRA_TCP_PORTS "" "Extra public TCP ports to open, comma separated (usually none)"
  defcfg FIREWALL_EXTRA_UDP_PORTS "" "Extra public UDP ports to open, comma separated"
  defcfg FIREWALL_CLOUDFLARE_ONLY false "Only accept 80/443 from Cloudflare's IP ranges (when the domain is proxied through Cloudflare)"
  defcfg FIREWALL_ALLOW_ICMP true "Answer ping (helps monitoring; rate-limited by sysctl)"
}

step_firewall_enabled() { cfg_bool FIREWALL_ENABLE; }

step_firewall_prompt() {
  ui_note "Default policy: deny all incoming, allow SSH + 80/443 for the proxy. Docker is made to respect UFW."
  ask_yn "Configure the firewall (ufw)?" "$FIREWALL_ENABLE" && FIREWALL_ENABLE=true || FIREWALL_ENABLE=false
  cfg_bool FIREWALL_ENABLE || return 0
  ask_yn "Rate-limit SSH connections (blocks brute force bursts)?" "$FIREWALL_SSH_RATE_LIMIT" && FIREWALL_SSH_RATE_LIMIT=true || FIREWALL_SSH_RATE_LIMIT=false
  ask "Extra public TCP ports (comma separated, usually none)" "$FIREWALL_EXTRA_TCP_PORTS" valid_port_list; FIREWALL_EXTRA_TCP_PORTS="$REPLY"
  ask "Extra public UDP ports (comma separated, usually none)" "$FIREWALL_EXTRA_UDP_PORTS" valid_port_list; FIREWALL_EXTRA_UDP_PORTS="$REPLY"
  ui_note "If your DNS is proxied through Cloudflare (orange cloud), attackers can't hit the origin directly when only Cloudflare IPs are allowed."
  ask_yn "Restrict HTTP/HTTPS to Cloudflare IP ranges only?" "$FIREWALL_CLOUDFLARE_ONLY" && FIREWALL_CLOUDFLARE_ONLY=true || FIREWALL_CLOUDFLARE_ONLY=false
}

step_firewall_plan() {
  ui_bullet "ufw: default deny incoming / allow outgoing; allow ${SSH_PORT}/tcp$(cfg_bool FIREWALL_SSH_RATE_LIMIT && echo ' (rate limited)')"
  if cfg_bool FIREWALL_CLOUDFLARE_ONLY; then ui_bullet "Allow 80,443/tcp + 443/udp from Cloudflare ranges only (refreshed weekly)"
  else ui_bullet "Allow 80,443/tcp + 443/udp from anywhere"; fi
  [[ -n "$FIREWALL_EXTRA_TCP_PORTS" ]] && ui_bullet "Allow extra TCP: $FIREWALL_EXTRA_TCP_PORTS"
  [[ -n "$FIREWALL_EXTRA_UDP_PORTS" ]] && ui_bullet "Allow extra UDP: $FIREWALL_EXTRA_UDP_PORTS"
  ui_bullet "Install DOCKER-USER chain rules so published container ports obey ufw"
  return 0
}

CF_IPS_SCRIPT=/usr/local/bin/vps-cloudflare-ips

_install_cloudflare_refresher() {
  write_file "$CF_IPS_SCRIPT" 0755 <<'EOF'
#!/usr/bin/env bash
# Managed by vps-wizard: (re)apply ufw rules allowing web traffic only from Cloudflare.
set -euo pipefail
tmp=$(mktemp)
{ curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4; echo; curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6; echo; } >"$tmp"
grep -Eq '^[0-9a-f.:/]+$' "$tmp" || { echo "bad cloudflare list" >&2; exit 1; }
# Remove previous cloudflare rules
while read -r num; do yes | ufw delete "$num" >/dev/null 2>&1 || true
done < <(ufw status numbered | grep -i 'cloudflare' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
while read -r cidr; do
  [[ -n "$cidr" ]] || continue
  ufw allow proto tcp from "$cidr" to any port 80,443 comment 'cloudflare' >/dev/null
  ufw allow proto udp from "$cidr" to any port 443 comment 'cloudflare' >/dev/null
  ufw route allow proto tcp from "$cidr" to any port 80,443 comment 'cloudflare' >/dev/null
  ufw route allow proto udp from "$cidr" to any port 443 comment 'cloudflare' >/dev/null
done <"$tmp"
rm -f "$tmp"
echo "cloudflare ranges applied: $(ufw status | grep -c cloudflare) rules"
EOF
  write_file /etc/systemd/system/vps-cloudflare-ips.service 0644 <<EOF
[Unit]
Description=Refresh Cloudflare IP allow-list in ufw
After=network-online.target
[Service]
Type=oneshot
ExecStart=$CF_IPS_SCRIPT
EOF
  write_file /etc/systemd/system/vps-cloudflare-ips.timer 0644 <<'EOF'
[Unit]
Description=Weekly Cloudflare IP refresh
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now vps-cloudflare-ips.timer
}

# ufw_install_block FILE TEMPLATE : inserts/refreshes a marked block in a ufw rules file
ufw_install_block() {
  local file="$1" tmpl="$2" begin end content
  content=$(render_template "$tmpl")
  begin=$(printf '%s\n' "$content" | head -1)
  end=$(printf '%s\n' "$content" | tail -1)
  if [[ "$DRY_RUN" == true ]]; then ui_cmd "install block $tmpl into $file"; return 0; fi
  if [[ ! -f "$file" ]]; then
    ui_warn "$file does not exist (is ufw installed?); skipping $tmpl"
    return 1
  fi
  local body
  if [[ "$file" == *after.rules ]]; then
    # Appended after the existing tables; must be after the final COMMIT.
    body=$(sed "/^$begin\$/,/^$end\$/d" "$file")
    printf '%s\n\n%s\n' "$body" "$content" | write_file "$file" 0640
  else
    # before.rules: our block must live inside the *filter table, before COMMIT.
    body=$(sed "/^$begin\$/,/^$end\$/d" "$file")
    printf '%s\n' "$body" | awk -v blk="$content" '
      /^COMMIT/ && !done { print blk; done=1 }
      { print }' | write_file "$file" 0640
  fi
}

step_firewall_apply() {
  apt_install ufw
  # Reset stance without dropping the current session: ufw keeps ESTABLISHED.
  run ufw --force default deny incoming
  run ufw --force default allow outgoing
  run ufw --force default deny routed
  run_sh "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw"
  # Reduce log noise from the DOCKER block rule
  run ufw logging low

  # SSH
  if cfg_bool FIREWALL_SSH_RATE_LIMIT; then run ufw limit "$SSH_PORT/tcp" comment 'ssh'
  else run ufw allow "$SSH_PORT/tcp" comment 'ssh'; fi
  # Drop stale rule for the previous port if it changed
  local prev; prev=$(state_get ssh.previous_port)
  if [[ -n "$prev" && "$prev" != "$SSH_PORT" ]]; then
    run_quiet ufw --force delete allow "$prev/tcp" || true
    run_quiet ufw --force delete limit "$prev/tcp" || true
  fi

  # Web
  if cfg_bool FIREWALL_CLOUDFLARE_ONLY; then
    run_quiet ufw --force delete allow 80,443/tcp || true
    run_quiet ufw --force delete allow 443/udp || true
    _install_cloudflare_refresher
    run "$CF_IPS_SCRIPT"
  else
    if [[ "$PROXY_TYPE" != none ]]; then
      run ufw allow 80,443/tcp comment 'web'
      run ufw allow 443/udp comment 'http3'
      run ufw route allow proto tcp from any to any port 80,443 comment 'web (docker)'
      run ufw route allow proto udp from any to any port 443 comment 'http3 (docker)'
    fi
  fi

  local p
  while IFS= read -r p; do [[ -n "$p" ]] && run ufw allow "$p/tcp" comment 'extra' && run ufw route allow proto tcp from any to any port "$p" comment 'extra (docker)'; done < <(split_list "$FIREWALL_EXTRA_TCP_PORTS")
  while IFS= read -r p; do [[ -n "$p" ]] && run ufw allow "$p/udp" comment 'extra' && run ufw route allow proto udp from any to any port "$p" comment 'extra (docker)'; done < <(split_list "$FIREWALL_EXTRA_UDP_PORTS")

  # Tailscale traffic is trusted on its own interface
  if cfg_bool TAILSCALE_ENABLE; then
    run ufw allow in on tailscale0 comment 'tailscale'
    run ufw allow 41641/udp comment 'tailscale direct'
  fi

  cfg_bool FIREWALL_ALLOW_ICMP || run_sh "sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules"

  # Docker integration
  ufw_install_block /etc/ufw/after.rules ufw-after-docker.rules

  run ufw --force enable
  run ufw reload
  ui_ok "ufw active: deny incoming, ssh ${SSH_PORT}/tcp, web $(cfg_bool FIREWALL_CLOUDFLARE_ONLY && echo 'cloudflare-only' || echo 'open')"
  step_mark_done firewall
}

step_firewall_status() {
  if have ufw; then
    ui_kv "ufw" "$(ufw status 2>/dev/null | head -1 | sed 's/Status: //')"
    ufw status 2>/dev/null | awk 'NR>4 && NF' | sed 's/^/        /' | head -20
  else
    ui_kv "ufw" "not installed"
  fi
}
