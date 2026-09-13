#!/usr/bin/env bash
# deploy.sh for "{{APP_NAME}}" - managed by vps-wizard.
# Pull the latest code, rebuild and roll the stack with zero manual steps.
#   ./deploy.sh            # git pull + build + up
#   ./deploy.sh --no-pull  # redeploy current checkout
#   ./deploy.sh --logs     # tail logs after deploy
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./app.conf

PULL=true; LOGS=false
for a in "$@"; do
  case "$a" in
    --no-pull) PULL=false ;;
    --logs) LOGS=true ;;
  esac
done

COMPOSE=(docker compose --project-name "$COMPOSE_PROJECT" --env-file ./.env -f "$SRC_DIR/$COMPOSE_FILE" -f ./compose.wizard.yml)

if [[ "$PULL" == true && -d "$SRC_DIR/.git" ]]; then
  echo "» git pull ($BRANCH)"
  git -C "$SRC_DIR" fetch --quiet origin "$BRANCH"
  git -C "$SRC_DIR" reset --quiet --hard "origin/$BRANCH"
fi

echo "» build"
"${COMPOSE[@]}" build --pull
echo "» up"
"${COMPOSE[@]}" up -d --remove-orphans
echo "» waiting for $APP_SERVICE"
for _ in $(seq 1 30); do
  state=$("${COMPOSE[@]}" ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null | awk -v s="$APP_SERVICE" '$1==s {print $2" "$3}')
  case "$state" in
    "running healthy"|"running ") echo "  $APP_SERVICE is up"; break ;;
    exited*|dead*) echo "  $APP_SERVICE failed to start"; "${COMPOSE[@]}" logs --tail=50 "$APP_SERVICE"; exit 1 ;;
  esac
  sleep 2
done
docker image prune -f >/dev/null 2>&1 || true
echo "» deployed $(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo '(no git)') at $(date '+%F %T')"
[[ "$LOGS" == true ]] && exec "${COMPOSE[@]}" logs -f --tail=100
exit 0
