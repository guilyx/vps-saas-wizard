#!/usr/bin/env bash
# Step: backups - nightly dumps of databases, volumes and config; optional restic offsite.
register_step backups "Backups" "nightly db dumps + volumes · retention · optional restic offsite"

step_backups_config() {
  defcfg BACKUP_ENABLE true "Install the nightly backup job"
  defcfg BACKUP_DIR "/var/backups/vps-wizard" "Local backup directory"
  defcfg BACKUP_TIME "03:30" "Daily backup time (server local time, HH:MM)"
  defcfg BACKUP_RETENTION_DAYS "7" "Days of local backups to keep"
  defcfg BACKUP_RESTIC_REPOSITORY "" "Optional restic repo for offsite copies, e.g. s3:s3.amazonaws.com/bucket/vps or b2:bucket:path or sftp:user@host:/backups"
  defcfg BACKUP_RESTIC_PASSWORD "" "restic repository password (generated if empty and a repo is set)"
  defcfg BACKUP_RESTIC_ENV "" "Extra env for restic as KEY=VALUE pairs separated by commas (AWS_ACCESS_KEY_ID=...,AWS_SECRET_ACCESS_KEY=...)"
}

step_backups_enabled() { cfg_bool BACKUP_ENABLE; }

step_backups_prompt() {
  ui_note "Local snapshots are not a backup if the disk dies. Add a restic repository for offsite copies (S3/B2/SFTP)."
  ask_yn "Install nightly backups?" "$BACKUP_ENABLE" && BACKUP_ENABLE=true || BACKUP_ENABLE=false
  cfg_bool BACKUP_ENABLE || return 0
  ask "Backup time (HH:MM)" "$BACKUP_TIME" valid_hhmm; BACKUP_TIME="$REPLY"
  ask "Local retention (days)" "$BACKUP_RETENTION_DAYS" valid_int; BACKUP_RETENTION_DAYS="$REPLY"
  ask "restic repository for offsite copies (empty to skip)" "$BACKUP_RESTIC_REPOSITORY"; BACKUP_RESTIC_REPOSITORY="$REPLY"
  if [[ -n "$BACKUP_RESTIC_REPOSITORY" ]]; then
    ask_secret "restic password (empty = generate)" "$BACKUP_RESTIC_PASSWORD"; BACKUP_RESTIC_PASSWORD="$REPLY"
    ask "restic credentials env (KEY=VALUE,KEY=VALUE)" "$BACKUP_RESTIC_ENV"; BACKUP_RESTIC_ENV="$REPLY"
  fi
}

step_backups_plan() {
  ui_bullet "Install /usr/local/bin/vps-backup + systemd timer daily at $BACKUP_TIME, keep ${BACKUP_RETENTION_DAYS}d in $BACKUP_DIR"
  [[ -n "$BACKUP_RESTIC_REPOSITORY" ]] && ui_bullet "Push snapshots to restic repo $BACKUP_RESTIC_REPOSITORY (7d/4w/6m retention)"
  return 0
}

step_backups_apply() {
  write_file /usr/local/bin/vps-backup 0755 <"$WIZARD_TEMPLATES/backup.sh"
  {
    printf '# Managed by vps-wizard - backup settings (sourced by vps-backup)\n'
    printf 'APPS_DIR=%q\nBACKUP_DIR=%q\nRETENTION_DAYS=%q\n' "$WIZARD_APPS_DIR" "$BACKUP_DIR" "$BACKUP_RETENTION_DAYS"
    if [[ -n "$BACKUP_RESTIC_REPOSITORY" ]]; then
      [[ -z "$BACKUP_RESTIC_PASSWORD" ]] && BACKUP_RESTIC_PASSWORD=$(gen_secret 24)
      printf 'RESTIC_REPOSITORY=%q\nRESTIC_PASSWORD=%q\n' "$BACKUP_RESTIC_REPOSITORY" "$BACKUP_RESTIC_PASSWORD"
      local kv
      while IFS= read -r kv; do [[ "$kv" == *=* ]] && printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done < <(printf '%s\n' "$BACKUP_RESTIC_ENV" | tr ',' '\n')
    fi
  } | write_file "$WIZARD_ETC/backup.env" 0600
  if [[ -n "$BACKUP_RESTIC_REPOSITORY" ]]; then
    apt_install restic
    ui_warn "Store the restic password somewhere safe: without it offsite backups are unreadable. It is in $WIZARD_ETC/backup.env"
  fi
  export BACKUP_TIME
  write_file /etc/systemd/system/vps-backup.service 0644 <"$WIZARD_TEMPLATES/vps-backup.service"
  render_template vps-backup.timer | write_file /etc/systemd/system/vps-backup.timer 0644
  run systemctl daemon-reload
  run systemctl enable --now vps-backup.timer
  [[ "$DRY_RUN" == true ]] || { mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; }
  ui_ok "Backups scheduled daily at $BACKUP_TIME (run now: vps-backup)"
  step_mark_done backups
}

step_backups_status() {
  ui_kv "Backup timer" "$(systemctl is-enabled vps-backup.timer 2>/dev/null || echo 'not installed')"
  ui_kv "Next run" "$(systemctl list-timers vps-backup.timer --no-legend 2>/dev/null | awk '{print $1" "$2" "$3}')"
  ui_kv "Latest" "$(ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | head -1)"
  ui_kv "Offsite" "$(grep -q RESTIC_REPOSITORY "$WIZARD_ETC/backup.env" 2>/dev/null && echo restic || echo none)"
}
