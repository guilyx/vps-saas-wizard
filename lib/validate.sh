#!/usr/bin/env bash
# validate.sh - input validators. Each returns 0/1 and sets VALIDATION_ERROR.

VALIDATION_ERROR=""

valid_domain() {
  VALIDATION_ERROR="Enter a fully-qualified domain like app.example.com"
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_domain_or_empty() { [[ -z "$1" ]] || valid_domain "$1"; }

valid_email() {
  VALIDATION_ERROR="Enter a valid e-mail address"
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

valid_port() {
  VALIDATION_ERROR="Port must be a number between 1 and 65535"
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

valid_port_or_empty() { [[ -z "$1" ]] || valid_port "$1"; }

valid_port_list() {
  VALIDATION_ERROR="Use a comma-separated list of ports (e.g. 8080,9000) or leave empty"
  [[ -z "$1" ]] && return 0
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    valid_port "$p" || { VALIDATION_ERROR="Invalid port: $p"; return 1; }
  done < <(split_list "$1")
  return 0
}

valid_username() {
  VALIDATION_ERROR="Usernames: lowercase letters, digits, _ and -, starting with a letter (max 32)"
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

valid_slug() {
  VALIDATION_ERROR="Use lowercase letters, digits and dashes (e.g. my-app)"
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

valid_bool() {
  VALIDATION_ERROR="Use true or false"
  case "${1,,}" in true|false|yes|no|y|n|1|0|on|off) return 0 ;; *) return 1 ;; esac
}

valid_int() {
  VALIDATION_ERROR="Enter a whole number"
  [[ "$1" =~ ^[0-9]+$ ]]
}

valid_timezone() {
  VALIDATION_ERROR="Unknown timezone (see /usr/share/zoneinfo, e.g. Europe/Paris)"
  [[ -z "$1" ]] && return 1
  [[ -f "/usr/share/zoneinfo/$1" ]] || [[ ! -d /usr/share/zoneinfo && "$1" =~ ^[A-Za-z_]+(/[A-Za-z_+-]+)*$ ]]
}

valid_hhmm() {
  VALIDATION_ERROR="Use 24h time as HH:MM (e.g. 03:30)"
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

valid_git_or_path_or_empty() {
  VALIDATION_ERROR="Enter a git URL (https://... or git@...), a local directory, or leave empty"
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^(https?://|git@|ssh://|git://) ]] && return 0
  [[ -d "$1" ]] && return 0
  return 1
}

valid_ssh_pubkey() {
  VALIDATION_ERROR="Enter an OpenSSH public key (ssh-ed25519 AAAA... / ssh-rsa AAAA...) or a path to one"
  [[ -z "$1" ]] && return 1
  [[ "$1" == root ]] && return 0
  [[ -f "$1" ]] && return 0
  [[ "$1" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

valid_duration() {
  VALIDATION_ERROR="Use a duration like 10m, 1h, 1d"
  [[ "$1" =~ ^[0-9]+[smhdw]?$ ]]
}

valid_anything() { return 0; }

# validate_config : runs validators over the loaded config; prints all errors.
validate_config() {
  local errors=0
  _vc() { # key validator
    local key="$1" fn="$2" val=${!1-}
    if ! "$fn" "$val"; then
      ui_error "$key='$val': $VALIDATION_ERROR"
      errors=$((errors + 1))
    fi
  }
  _vc DEPLOY_USER valid_username
  _vc SSH_PORT valid_port
  _vc FIREWALL_EXTRA_TCP_PORTS valid_port_list
  _vc FIREWALL_EXTRA_UDP_PORTS valid_port_list
  _vc SYS_TIMEZONE valid_timezone
  _vc BACKUP_TIME valid_hhmm
  _vc BACKUP_RETENTION_DAYS valid_int
  _vc FAIL2BAN_BANTIME valid_duration
  _vc FAIL2BAN_FINDTIME valid_duration
  _vc FAIL2BAN_MAXRETRY valid_int
  if cfg_bool APP_ENABLE; then
    _vc APP_NAME valid_slug
    _vc APP_DOMAIN valid_domain
    _vc APP_PORT valid_port_or_empty
    _vc APP_SOURCE valid_git_or_path_or_empty
  fi
  if [[ "$PROXY_TYPE" != none ]]; then
    _vc PROXY_EMAIL valid_email
    case "$PROXY_TYPE" in caddy|traefik) ;; *) ui_error "PROXY_TYPE must be caddy, traefik or none"; errors=$((errors+1)) ;; esac
  fi
  if cfg_bool SSH_DISABLE_PASSWORD_AUTH && [[ -z "$DEPLOY_USER_SSH_KEY" ]] && ! [[ -s /root/.ssh/authorized_keys ]]; then
    ui_error "SSH_DISABLE_PASSWORD_AUTH=true but no SSH public key is available (set DEPLOY_USER_SSH_KEY). Refusing to lock you out."
    errors=$((errors + 1))
  fi
  if cfg_bool TAILSCALE_RESTRICT_SSH && ! cfg_bool TAILSCALE_ENABLE; then
    ui_error "TAILSCALE_RESTRICT_SSH requires TAILSCALE_ENABLE=true"
    errors=$((errors + 1))
  fi
  unset -f _vc
  (( errors == 0 ))
}
