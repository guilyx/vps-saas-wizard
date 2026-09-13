#!/usr/bin/env bash
# Step: app - deploy a docker-compose application from git behind the proxy.
register_step app "Application" "git clone · .env · compose overlay · TLS site · health check"

step_app_config() {
  defcfg APP_ENABLE true "Deploy an application now"
  defcfg APP_NAME "myapp" "Short app name (slug) - becomes the compose project and /opt/apps/<name>"
  defcfg APP_SOURCE "" "Git URL (https://... or git@...), a local directory, or empty to scaffold a demo app"
  defcfg APP_BRANCH "main" "Git branch to deploy"
  defcfg APP_COMPOSE_FILE "" "Compose file inside the repo (empty = auto-detect compose.yml / docker-compose.yml)"
  defcfg APP_SERVICE "" "Compose service that serves HTTP (empty = auto-detect / first service)"
  defcfg APP_PORT "" "Container port that service listens on (empty = auto-detect from compose ports/expose)"
  defcfg APP_DOMAIN "" "Public domain for the app (DNS A/AAAA record must point at this VPS)"
  defcfg APP_WWW_REDIRECT false "Also serve www.<domain> and redirect it to the apex"
  defcfg APP_HEALTHCHECK_PATH "/" "HTTP path the proxy polls for upstream health"
  defcfg APP_ENV_FILE "" "Path to an existing .env to use for the app (copied to /opt/apps/<name>/.env)"
  defcfg APP_ENV_VARS "" "Extra env values as KEY=VALUE pairs separated by commas (override .env.example defaults)"
  defcfg APP_ENV_AUTOGEN_SECRETS true "Generate random values for empty *SECRET*/*KEY*/*PASSWORD* variables"
  defcfg APP_GIT_SSH_KEY_GENERATE true "For git@ URLs: generate a per-app deploy key and print the public half"
}

step_app_enabled() { cfg_bool APP_ENABLE; }

app_dir() { printf '%s/%s' "$WIZARD_APPS_DIR" "$1"; }

# Keys whose empty value should be auto-generated and typed hidden.
is_secret_key() { [[ "${1^^}" =~ (SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|PRIVATE_KEY|_KEY$|^KEY$|SALT|JWT|AUTH_SECRET|ENCRYPTION) ]]; }
# Keys whose value must never be echoed back. Superset of the above: connection
# strings and DSNs embed credentials but must not be randomly generated.
is_sensitive_key() {
  is_secret_key "$1" && return 0
  is_url_key "$1" && return 1   # public site URLs are safe to show
  [[ "${1^^}" =~ (_URI$|_DSN$|_URL$|CONNECTION_STRING|CREDENTIAL) ]]
}
is_url_key() { [[ "${1^^}" =~ ^(APP_URL|PUBLIC_URL|SITE_URL|BASE_URL|NEXTAUTH_URL|AUTH_URL|NEXT_PUBLIC_APP_URL|NEXT_PUBLIC_SITE_URL|ORIGIN|FRONTEND_URL|WEB_URL)$ ]]; }

# Field separator for parse_env_file output. A non-whitespace character so
# that empty fields survive `read` (tabs would collapse).
ENV_SEP=$'\x1f'

# parse_env_file FILE : prints KEY<SEP>VALUE<SEP>COMMENT for each assignment
parse_env_file() {
  local file="$1" line comment="" key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]?(.*)$ ]]; then comment="${BASH_REMATCH[1]}"; continue; fi
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}; val=${BASH_REMATCH[3]}
      val=${val%%[[:space:]]#*}   # strip trailing comment
      if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
      printf '%s%s%s%s%s\n' "$key" "$ENV_SEP" "$val" "$ENV_SEP" "$comment"
      comment=""
    else
      comment=""
    fi
  done <"$file"
}

# env_lookup FILE KEY : value of KEY in an env file (empty if absent)
env_lookup() { parse_env_file "$1" | awk -F"$ENV_SEP" -v k="$2" '$1==k {print $2; exit}'; }

# env_quote VALUE : quote a value for a docker compose env file
env_quote() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9_./:@+,=-]*$ ]]; then printf '%s' "$v"; return; fi
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}
  printf '"%s"' "$v"
}

step_app_prompt() {
  ui_note "The app is cloned to $WIZARD_APPS_DIR/<name>/src, gets a private .env, a compose overlay joining the proxy network, and a TLS site."
  ask_yn "Deploy an application now?" "$APP_ENABLE" && APP_ENABLE=true || APP_ENABLE=false
  cfg_bool APP_ENABLE || return 0
  ask "App name (slug)" "$APP_NAME" valid_slug; APP_NAME="$REPLY"
  ask "Source: git URL, local path, or empty for a demo app" "$APP_SOURCE" valid_git_or_path_or_empty; APP_SOURCE="$REPLY"
  if [[ "$APP_SOURCE" =~ ^(https?://|git@|ssh://|git://) ]]; then
    ask "Branch" "$APP_BRANCH"; APP_BRANCH="$REPLY"
  fi
  if [[ -d "$APP_SOURCE" ]]; then
    local cf; cf=$(detect_compose_file "$APP_SOURCE" || true)
    ask "Compose file" "${APP_COMPOSE_FILE:-$cf}"; APP_COMPOSE_FILE="$REPLY"
    if [[ -f "$APP_SOURCE/$APP_COMPOSE_FILE" ]]; then
      local svcs; svcs=$(compose_services "$APP_SOURCE/$APP_COMPOSE_FILE" | tr '\n' ' ')
      [[ -n "$svcs" ]] && ui_info "Services found: $svcs"
      ask "Service that serves HTTP" "${APP_SERVICE:-${svcs%% *}}"; APP_SERVICE="$REPLY"
      ask "Container port of $APP_SERVICE" "${APP_PORT:-$(compose_service_port "$APP_SOURCE/$APP_COMPOSE_FILE" "$APP_SERVICE")}" valid_port; APP_PORT="$REPLY"
    fi
  elif [[ -n "$APP_SOURCE" ]]; then
    ask "Compose file in repo (empty = auto-detect)" "$APP_COMPOSE_FILE"; APP_COMPOSE_FILE="$REPLY"
    ask "Service that serves HTTP (empty = auto-detect)" "$APP_SERVICE"; APP_SERVICE="$REPLY"
    ask "Container port of that service (empty = auto-detect)" "$APP_PORT"; APP_PORT="$REPLY"
    [[ -n "$APP_PORT" ]] && ! valid_port "$APP_PORT" && die "invalid APP_PORT"
  else
    APP_SERVICE=web; APP_PORT=80; APP_COMPOSE_FILE=compose.yml
    ui_info "A demo 'whoami' app will be scaffolded so you can verify TLS and routing end-to-end."
  fi
  if [[ "$PROXY_TYPE" != none ]]; then
    ask_required "Public domain (DNS must already point to ${HOST_PUBLIC_IP:-this server})" "$APP_DOMAIN" valid_domain; APP_DOMAIN="$REPLY"
    ask_yn "Also serve www.$APP_DOMAIN (redirect to apex)?" "$APP_WWW_REDIRECT" && APP_WWW_REDIRECT=true || APP_WWW_REDIRECT=false
    ask "Health check path" "$APP_HEALTHCHECK_PATH"; APP_HEALTHCHECK_PATH="$REPLY"
    app_check_dns "$APP_DOMAIN" || true
  fi
  ask "Existing .env file to use (empty = build from .env.example)" "$APP_ENV_FILE"; APP_ENV_FILE="$REPLY"
  ask_yn "Auto-generate random values for empty secrets?" "$APP_ENV_AUTOGEN_SECRETS" && APP_ENV_AUTOGEN_SECRETS=true || APP_ENV_AUTOGEN_SECRETS=false
}

app_check_dns() {
  local domain="$1" resolved
  resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
  if [[ -z "$resolved" ]]; then
    ui_warn "$domain does not resolve yet. TLS issuance will fail until the A record points to ${HOST_PUBLIC_IP:-this server}."
    return 1
  fi
  if [[ -n "$HOST_PUBLIC_IP" && "$resolved" != "$HOST_PUBLIC_IP" ]]; then
    if proxy_behind_cf 2>/dev/null; then ui_info "$domain resolves to $resolved (Cloudflare proxy) - OK."
    else ui_warn "$domain resolves to $resolved, but this server is $HOST_PUBLIC_IP. Fix DNS or enable Cloudflare mode."; return 1; fi
  else
    ui_ok "$domain resolves to this server"
  fi
  return 0
}

step_app_plan() {
  local dir; dir=$(app_dir "$APP_NAME")
  if [[ -z "$APP_SOURCE" ]]; then ui_bullet "Scaffold demo app (traefik/whoami) in $dir/src"
  else ui_bullet "Clone/sync $APP_SOURCE${APP_BRANCH:+ ($APP_BRANCH)} into $dir/src"; fi
  ui_bullet "Build .env from .env.example (secrets auto-generated: $APP_ENV_AUTOGEN_SECRETS) at $dir/.env (mode 600)"
  ui_bullet "Compose overlay: service ${APP_SERVICE:-auto} joins 'proxy' network; restart policy, log rotation"
  [[ "$PROXY_TYPE" != none ]] && ui_bullet "Publish https://$APP_DOMAIN → ${APP_SERVICE:-auto}:${APP_PORT:-auto}$(cfg_bool APP_WWW_REDIRECT && echo ' (+www redirect)')"
  ui_bullet "docker compose build + up, wait for healthy"
  return 0
}

app_scaffold_demo() {
  local src="$1"
  write_file "$src/compose.yml" 0644 <<'EOF'
# Demo app scaffolded by vps-wizard. Replace with your real stack.
services:
  web:
    image: traefik/whoami:latest
    environment:
      WHOAMI_NAME: ${APP_TITLE:-vps-wizard demo}
    expose:
      - "80"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:80/health"]
      interval: 15s
      timeout: 3s
      retries: 3
EOF
  write_file "$src/.env.example" 0644 <<'EOF'
# Display name shown by the demo app
APP_TITLE=vps-wizard demo
EOF
}

app_sync_source() {
  local src="$1"
  if [[ -z "$APP_SOURCE" ]]; then
    [[ -f "$src/compose.yml" ]] || app_scaffold_demo "$src"
    return 0
  fi
  if [[ -d "$APP_SOURCE" ]]; then
    if [[ "$(readlink -f "$APP_SOURCE")" != "$(readlink -f "$src")" ]]; then
      if have rsync; then run rsync -a --delete --exclude .git --exclude node_modules "$APP_SOURCE/" "$src/"
      else run mkdir -p "$src"; run cp -a "$APP_SOURCE/." "$src/"; fi
    fi
    return 0
  fi
  local git_env=()
  if [[ "$APP_SOURCE" =~ ^(git@|ssh://) ]] && cfg_bool APP_GIT_SSH_KEY_GENERATE; then
    local keyfile; keyfile="$(app_dir "$APP_NAME")/deploy_key"
    if [[ ! -f "$keyfile" && "$DRY_RUN" != true ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "vps-wizard deploy key for $APP_NAME" -f "$keyfile"
      ui_blank
      ui_box "Add this deploy key (read-only) to the repository" "$(cat "$keyfile.pub")"
      ui_note "GitHub: repo → Settings → Deploy keys → Add. GitLab: Settings → Repository → Deploy keys."
      ui_pause "Press Enter once the key is added"
    fi
    git_env=(env GIT_SSH_COMMAND="ssh -i $keyfile -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")
  fi
  if [[ -d "$src/.git" ]]; then
    ui_spin "Updating source ($APP_BRANCH)" "${git_env[@]}" git -C "$src" fetch --depth 1 origin "$APP_BRANCH"
    run "${git_env[@]}" git -C "$src" checkout -q -B "$APP_BRANCH" "origin/$APP_BRANCH"
  else
    run rm -rf "$src"
    ui_spin "Cloning $APP_SOURCE ($APP_BRANCH)" "${git_env[@]}" git clone --depth 1 --branch "$APP_BRANCH" "$APP_SOURCE" "$src"
  fi
}

# app_build_env DIR SRC : produces DIR/.env from example + overrides + prompts
app_build_env() {
  local dir="$1" src="$2" example="" f
  for f in .env.example .env.sample .env.template .env.dist example.env; do
    [[ -f "$src/$f" ]] && { example="$src/$f"; break; }
  done
  local target="$dir/.env" existing="$dir/.env"
  local -A override
  local kv
  while IFS= read -r kv; do [[ "$kv" == *=* ]] && override["${kv%%=*}"]="${kv#*=}"; done < <(printf '%s\n' "$APP_ENV_VARS" | tr ',' '\n')
  if [[ -n "$APP_ENV_FILE" && -f "$APP_ENV_FILE" ]]; then
    while IFS="$ENV_SEP" read -r k v _; do [[ -n "${override[$k]+x}" ]] || override[$k]="$v"; done < <(parse_env_file "$APP_ENV_FILE")
  fi
  local -a lines=() keys=()
  local k v c val
  if [[ -n "$example" ]]; then
    ui_section "Environment for $APP_NAME (from $(basename "$example"))"
    [[ "$NONINTERACTIVE" == true ]] || ui_note "Enter values. Empty secrets are generated automatically."
    while IFS="$ENV_SEP" read -r k v c; do
      keys+=("$k")
      val="$v"
      [[ -f "$existing" ]] && { local cur; cur=$(env_lookup "$existing" "$k"); [[ -n "$cur" ]] && val="$cur"; }
      [[ -n "${override[$k]+x}" ]] && val="${override[$k]}"
      if [[ -z "$val" ]] && is_url_key "$k" && [[ -n "$APP_DOMAIN" ]]; then val="https://$APP_DOMAIN"; fi
      if [[ -z "$val" ]] && is_secret_key "$k" && cfg_bool APP_ENV_AUTOGEN_SECRETS; then val=$(gen_secret 32); c="${c:+$c }(generated)"; fi
      if [[ "$NONINTERACTIVE" != true ]]; then
        [[ -n "$c" ]] && ui_note "$c"
        if is_secret_key "$k"; then ask_secret "$k" "$val"; else ask "$k" "$val"; fi
        val="$REPLY"
      fi
      [[ -z "$val" ]] && ui_warn "$k is empty"
      lines+=("$k=$(env_quote "$val")")
    done < <(parse_env_file "$example")
  else
    ui_info "No .env.example found - writing overrides only."
  fi
  for k in "${!override[@]}"; do
    local seen=false; for kk in "${keys[@]}"; do [[ "$kk" == "$k" ]] && seen=true; done
    [[ "$seen" == true ]] || lines+=("$k=$(env_quote "${override[$k]}")")
  done
  { printf '# %s environment - managed by vps-wizard (edit: vps-wizard env %s edit)\n' "$APP_NAME" "$APP_NAME"; printf '%s\n' "${lines[@]}"; } | write_file "$target" 0600
  ui_ok ".env written ($((${#lines[@]})) vars, mode 600)"
}

app_write_meta() {
  local dir="$1" src="$2"
  export APP_NAME APP_SERVICE
  render_template app-compose.wizard.yml | write_file "$dir/compose.wizard.yml" 0644
  {
    printf '# %s - managed by vps-wizard\n' "$APP_NAME"
    printf 'APP_NAME=%q\nCOMPOSE_PROJECT=%q\nSRC_DIR=%q\nCOMPOSE_FILE=%q\nAPP_SERVICE=%q\nAPP_PORT=%q\nAPP_DOMAIN=%q\nAPP_SOURCE=%q\nBRANCH=%q\nHEALTHCHECK_PATH=%q\nWWW_REDIRECT=%q\n' \
      "$APP_NAME" "$APP_NAME" "$src" "$APP_COMPOSE_FILE" "$APP_SERVICE" "$APP_PORT" "$APP_DOMAIN" "$APP_SOURCE" "$APP_BRANCH" "$APP_HEALTHCHECK_PATH" "$APP_WWW_REDIRECT"
  } | write_file "$dir/app.conf" 0644
  render_template app-deploy.sh | write_file "$dir/deploy.sh" 0755
}

step_app_apply() {
  local dir src; dir=$(app_dir "$APP_NAME"); src="$dir/src"
  [[ "$DRY_RUN" == true ]] || mkdir -p "$dir"
  app_sync_source "$src"

  # Detect compose details now that we have the source
  local detected=""; [[ -d "$src" ]] && detected=$(detect_compose_file "$src" || true)
  if [[ -f "$src/${APP_COMPOSE_FILE:-$detected}" ]]; then
    [[ -z "$APP_COMPOSE_FILE" ]] && APP_COMPOSE_FILE="$detected"
    local svcs; svcs=$(compose_services "$src/$APP_COMPOSE_FILE")
    if [[ -z "$APP_SERVICE" ]]; then
      local s
      for s in web app frontend api server nginx; do grep -qx "$s" <<<"$svcs" && { APP_SERVICE="$s"; break; }; done
      [[ -z "$APP_SERVICE" ]] && APP_SERVICE=$(head -1 <<<"$svcs")
      ui_info "Using service '$APP_SERVICE' (services: $(tr '\n' ' ' <<<"$svcs"))"
    fi
    grep -qx "$APP_SERVICE" <<<"$svcs" || die "Service '$APP_SERVICE' not in $APP_COMPOSE_FILE (services: $(tr '\n' ' ' <<<"$svcs"))"
    if [[ -z "$APP_PORT" ]]; then
      APP_PORT=$(compose_service_port "$src/$APP_COMPOSE_FILE" "$APP_SERVICE")
      [[ -z "$APP_PORT" ]] && case "$(compose_service_image "$src/$APP_COMPOSE_FILE" "$APP_SERVICE")" in
        *nginx*|*caddy*|*httpd*|*whoami*) APP_PORT=80 ;; *node*) APP_PORT=3000 ;; *python*|*uvicorn*) APP_PORT=8000 ;; *) APP_PORT=3000 ;; esac
      ui_info "Using container port $APP_PORT for $APP_SERVICE"
    fi
  elif [[ "$DRY_RUN" == true ]]; then
    APP_COMPOSE_FILE=${APP_COMPOSE_FILE:-compose.yml}; APP_SERVICE=${APP_SERVICE:-web}; APP_PORT=${APP_PORT:-3000}
  else
    die "No compose file found in $src (looked for compose.yml / docker-compose.yml). Set APP_COMPOSE_FILE."
  fi

  app_build_env "$dir" "$src"
  app_write_meta "$dir" "$src"

  if [[ "$PROXY_TYPE" != none ]]; then
    proxy_write_site "$APP_NAME" "$APP_DOMAIN" "$APP_SERVICE:$APP_PORT" "$APP_HEALTHCHECK_PATH" "$APP_WWW_REDIRECT"
    proxy_reload || ui_warn "Proxy reload failed; check $WIZARD_PROXY_DIR"
  fi

  if id "$DEPLOY_USER" >/dev/null 2>&1 && [[ "$DRY_RUN" != true ]]; then
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$dir"; chmod 700 "$dir"
  fi

  ui_spin "Building and starting $APP_NAME" bash "$dir/deploy.sh" --no-pull || die "Deployment failed. Inspect: vps-wizard app logs $APP_NAME"
  state_set "app.$APP_NAME.domain" "$APP_DOMAIN"
  if [[ "$PROXY_TYPE" != none && "$DRY_RUN" != true ]]; then
    app_check_dns "$APP_DOMAIN" >/dev/null 2>&1 && app_wait_https "$APP_DOMAIN"
  fi
  ui_ok "$APP_NAME deployed${APP_DOMAIN:+ → https://$APP_DOMAIN}"
  step_mark_done app
}

app_wait_https() {
  local domain="$1" i code
  have curl || return 0
  for i in $(seq 1 20); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$domain$APP_HEALTHCHECK_PATH" 2>/dev/null || echo 000)
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then ui_ok "https://$domain answers $code (TLS issued)"; return 0; fi
    (( i == 1 )) && printf '  %s%s%s waiting for TLS certificate + upstream' "$C_GRAY" "$G_ARROW" "$C_RESET"
    printf '.'; sleep 6
  done
  printf '\n'
  ui_warn "https://$domain not healthy yet (last status $code). Check: docker logs proxy-$PROXY_TYPE --tail 50"
}

step_app_status() {
  local d
  for d in "$WIZARD_APPS_DIR"/*/; do
    [[ -f "$d/app.conf" ]] || continue
    local name; name=$(basename "$d")
    local domain; domain=$(awk -F= '/^APP_DOMAIN=/{print $2}' "$d/app.conf" | tr -d "'\"")
    local state; state=$(docker compose --project-name "$name" ls --format json 2>/dev/null | grep -o '"Status":"[^"]*"' | head -1 | cut -d'"' -f4)
    ui_kv "$name" "${state:-not running}${domain:+  https://$domain}"
  done
  return 0
}
