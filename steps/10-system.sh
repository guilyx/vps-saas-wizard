#!/usr/bin/env bash
# Step: system - updates, timezone, hostname, swap, unattended upgrades, journald.
register_step system "System basics" "updates · timezone · swap · auto security updates"

step_system_config() {
  defcfg SYS_UPGRADE true "Run apt full-upgrade during setup (true/false)"
  defcfg SYS_HOSTNAME "" "Hostname to set (empty = keep current)"
  defcfg SYS_TIMEZONE "UTC" "System timezone, e.g. Europe/Paris"
  defcfg SYS_SWAP_GB "auto" "Swap file size in GB: auto, 0 (none) or a number"
  defcfg SYS_UNATTENDED_UPGRADES true "Install unattended-upgrades for automatic security patches"
  defcfg SYS_AUTO_REBOOT false "Allow unattended-upgrades to reboot at 04:30 when required"
}

step_system_enabled() { return 0; }

_swap_target_gb() {
  case "$SYS_SWAP_GB" in
    auto)
      # Small boxes: 2GB safety net for docker builds. Big boxes: 1GB.
      if (( MEM_MB >= 8192 )); then echo 1; else echo 2; fi ;;
    *) echo "$SYS_SWAP_GB" ;;
  esac
}

step_system_prompt() {
  ask "Hostname (empty keeps '$(hostname)')" "$SYS_HOSTNAME" valid_anything; SYS_HOSTNAME="$REPLY"
  ask "Timezone" "$SYS_TIMEZONE" valid_timezone; SYS_TIMEZONE="$REPLY"
  ask_yn "Run apt full-upgrade now?" "$SYS_UPGRADE" && SYS_UPGRADE=true || SYS_UPGRADE=false
  local cur_swap; cur_swap=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
  if (( cur_swap > 0 )); then
    ui_info "Swap already present (${cur_swap}GB); skipping swap creation."
    SYS_SWAP_GB=0
  else
    ask "Swap file size in GB (auto / 0 / number)" "$SYS_SWAP_GB"; SYS_SWAP_GB="$REPLY"
  fi
  ask_yn "Enable automatic security updates (unattended-upgrades)?" "$SYS_UNATTENDED_UPGRADES" && SYS_UNATTENDED_UPGRADES=true || SYS_UNATTENDED_UPGRADES=false
  if cfg_bool SYS_UNATTENDED_UPGRADES; then
    ask_yn "Allow automatic reboots at 04:30 when a kernel update needs it?" "$SYS_AUTO_REBOOT" && SYS_AUTO_REBOOT=true || SYS_AUTO_REBOOT=false
  fi
}

step_system_plan() {
  cfg_bool SYS_UPGRADE && ui_bullet "apt update && apt full-upgrade"
  [[ -n "$SYS_HOSTNAME" ]] && ui_bullet "Set hostname to $SYS_HOSTNAME"
  ui_bullet "Set timezone to $SYS_TIMEZONE, enable NTP"
  local gb; gb=$(_swap_target_gb)
  [[ "$gb" != 0 ]] && ui_bullet "Create ${gb}GB swap file at /swapfile (swappiness 10)"
  cfg_bool SYS_UNATTENDED_UPGRADES && ui_bullet "Enable unattended security upgrades (auto-reboot: $SYS_AUTO_REBOOT)"
  ui_bullet "Bound journald to 500MB / 1 month"
  return 0
}

step_system_apply() {
  apt_update_once
  if cfg_bool SYS_UPGRADE; then
    ui_spin "Upgrading packages (this can take a few minutes)" \
      env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  fi
  if [[ -n "$SYS_HOSTNAME" && "$SYS_HOSTNAME" != "$(hostname)" ]]; then
    run hostnamectl set-hostname "$SYS_HOSTNAME"
    if ! grep -q "$SYS_HOSTNAME" /etc/hosts 2>/dev/null; then
      run_sh "printf '127.0.1.1 %s\n' '$SYS_HOSTNAME' >> /etc/hosts"
    fi
    ui_ok "Hostname set to $SYS_HOSTNAME"
  fi
  run timedatectl set-timezone "$SYS_TIMEZONE"
  run_quiet timedatectl set-ntp true || true
  ui_ok "Timezone $SYS_TIMEZONE"

  local gb; gb=$(_swap_target_gb)
  if [[ "$gb" != 0 ]] && ! [[ -f /swapfile ]] && ! swapon --show 2>/dev/null | grep -q .; then
    ui_spin "Creating ${gb}GB swap file" bash -c "
      fallocate -l ${gb}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((gb*1024)) status=none
      chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi

  if cfg_bool SYS_UNATTENDED_UPGRADES; then
    apt_install unattended-upgrades apt-listchanges
    render_template apt-52vps-wizard-unattended | write_file /etc/apt/apt.conf.d/52vps-wizard-unattended 0644
    run systemctl enable --now unattended-upgrades
    ui_ok "Unattended security upgrades enabled"
  fi

  render_template journald-vps-wizard.conf | write_file /etc/systemd/journald.conf.d/vps-wizard.conf 0644
  run_quiet systemctl restart systemd-journald || true
  step_mark_done system
}

step_system_status() {
  ui_kv "Hostname" "$(hostname)"
  ui_kv "Timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
  ui_kv "Swap" "$(swapon --show --noheadings 2>/dev/null | awk '{print $1" "$3}' | tr '\n' ' ')"
  ui_kv "Unattended upgrades" "$(service_active unattended-upgrades && echo active || echo inactive)"
}
