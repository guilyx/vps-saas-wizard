#!/usr/bin/env bash
# vps-backup - managed by vps-wizard.
# Backs up every app under APPS_DIR: database dumps (postgres/mysql/mariadb
# containers detected automatically), named docker volumes, the app's .env
# and compose files. Keeps RETENTION_DAYS locally and optionally pushes to a
# restic repository (S3, B2, SFTP, ...) when RESTIC_REPOSITORY is set.
#
# Usage: vps-backup [--app NAME] [--no-remote]
set -euo pipefail

CONF=/etc/vps-wizard/backup.env
[[ -f "$CONF" ]] && { set -a; . "$CONF"; set +a; }

APPS_DIR=${APPS_DIR:-/opt/apps}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/vps-wizard}
RETENTION_DAYS=${RETENTION_DAYS:-7}
ONLY_APP=""; REMOTE=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) ONLY_APP="$2"; shift 2 ;;
    --no-remote) REMOTE=false; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_DIR/$STAMP"
mkdir -p "$DEST"; chmod 700 "$BACKUP_DIR" "$DEST"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

backup_app() {
  local app_dir="$1" name; name=$(basename "$app_dir")
  [[ -f "$app_dir/app.conf" ]] || return 0
  # shellcheck disable=SC1091
  . "$app_dir/app.conf"
  local out="$DEST/$name"; mkdir -p "$out"
  log "[$name] config"
  cp -a "$app_dir/.env" "$out/env" 2>/dev/null || true
  cp -a "$app_dir/app.conf" "$out/app.conf"
  [[ -f "$app_dir/compose.wizard.yml" ]] && cp -a "$app_dir/compose.wizard.yml" "$out/"
  local project="${COMPOSE_PROJECT:-$name}"
  local cid image svc
  # Database dumps
  while read -r cid image svc; do
    [[ -n "$cid" ]] || continue
    case "$image" in
      *postgres*|*timescale*|*pgvector*)
        log "[$name] pg_dumpall from $svc"
        docker exec -i "$cid" sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' | gzip >"$out/$svc.pgdumpall.sql.gz" || log "[$name] WARN pg dump failed for $svc" ;;
      *mysql*|*mariadb*)
        log "[$name] mysqldump from $svc"
        docker exec -i "$cid" sh -c 'exec mysqldump --all-databases --single-transaction -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"' | gzip >"$out/$svc.mysqldump.sql.gz" || log "[$name] WARN mysql dump failed for $svc" ;;
      *redis*|*valkey*)
        log "[$name] redis BGSAVE $svc"
        docker exec "$cid" sh -c 'redis-cli -a "${REDIS_PASSWORD:-}" --no-auth-warning BGSAVE' >/dev/null 2>&1 || true ;;
    esac
  done < <(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.ID}} {{.Image}} {{.Label "com.docker.compose.service"}}')
  # Named volumes
  local vol
  while read -r vol; do
    [[ -n "$vol" ]] || continue
    log "[$name] volume $vol"
    docker run --rm -v "$vol:/from:ro" -v "$out:/to" alpine:3 \
      sh -c "cd /from && tar czf /to/volume-$vol.tgz ." || log "[$name] WARN volume $vol failed"
  done < <(docker volume ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}')
}

if [[ -n "$ONLY_APP" ]]; then
  backup_app "$APPS_DIR/$ONLY_APP"
else
  for d in "$APPS_DIR"/*/; do [[ -d "$d" ]] && backup_app "${d%/}"; done
fi

# Proxy state (certificates) - cheap and saves a rate-limit headache on restore
if docker volume inspect proxy_caddy_data >/dev/null 2>&1; then
  docker run --rm -v proxy_caddy_data:/from:ro -v "$DEST:/to" alpine:3 sh -c 'cd /from && tar czf /to/proxy-caddy-data.tgz .' || true
fi
if docker volume inspect proxy_traefik_acme >/dev/null 2>&1; then
  docker run --rm -v proxy_traefik_acme:/from:ro -v "$DEST:/to" alpine:3 sh -c 'cd /from && tar czf /to/proxy-traefik-acme.tgz .' || true
fi
cp -a /etc/vps-wizard/wizard.conf "$DEST/wizard.conf" 2>/dev/null || true

log "local backup written to $DEST ($(du -sh "$DEST" | cut -f1))"

# Retention
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

# Remote (restic)
if [[ "$REMOTE" == true && -n "${RESTIC_REPOSITORY:-}" ]] && command -v restic >/dev/null; then
  export RESTIC_REPOSITORY RESTIC_PASSWORD
  restic snapshots >/dev/null 2>&1 || restic init
  log "restic backup -> $RESTIC_REPOSITORY"
  restic backup --tag vps-wizard --host "$(hostname)" "$DEST"
  restic forget --tag vps-wizard --keep-daily "${RESTIC_KEEP_DAILY:-7}" --keep-weekly "${RESTIC_KEEP_WEEKLY:-4}" --keep-monthly "${RESTIC_KEEP_MONTHLY:-6}" --prune
fi
log "done"
