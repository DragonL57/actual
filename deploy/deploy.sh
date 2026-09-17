#!/bin/bash
# Deploys the Actual sync server on the personal VPS. Runs ON the VPS, piped in
# by .github/workflows/deploy.yml:
#
#   ssh "$VPS_USER@$VPS_HOST" "IMAGE=... DOMAIN=... bash -s" < deploy/deploy.sh
#
# It is also safe to run by hand from the compose directory. To roll back, pick
# an older sha tag (every deploy pushes one) and run:
#
#   IMAGE=ghcr.io/dragonl57/actual-server:<old-sha> bash deploy.sh
#
# Env: IMAGE (image ref, default the rolling master tag), DOMAIN, COMPOSE_DIR,
#      KEEP_BACKUPS (default 7), SKIP_BACKUP=1 to skip the data snapshot.
set -euo pipefail

export ACTUAL_IMAGE=${IMAGE:-ghcr.io/dragonl57/actual-server:master}
DOMAIN=${DOMAIN:-finance.thelong.online}
COMPOSE_DIR=${COMPOSE_DIR:-$HOME/actual}
KEEP_BACKUPS=${KEEP_BACKUPS:-7}
BACKUP_DIR=$COMPOSE_DIR/backups

cd "$COMPOSE_DIR"
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

log "deploying $ACTUAL_IMAGE to https://$DOMAIN"
docker compose config --quiet

# Pull before stopping anything: a failed pull must not leave the app down.
log 'pulling images'
docker compose pull

if [ "${SKIP_BACKUP:-0}" = "1" ]; then
  log 'skipping data snapshot ([skip-backup] in the commit message)'
else
  mkdir -p "$BACKUP_DIR"
  SNAP="$BACKUP_DIR/actual-data-$(date +%Y%m%d-%H%M%S).tar.gz"
  log "snapshotting actual-data -> $SNAP"
  # Stop the app first: a tar over a live SQLite database can capture a torn
  # write. The container is recreated below anyway, so the stop costs nothing.
  docker compose stop actual_server >/dev/null
  tar czf "$SNAP" -C actual-data .
  if [ ! -s "$SNAP" ] || ! tar tzf "$SNAP" >/dev/null 2>&1; then
    # Not fatal on purpose: the app keeps its own backups of every budget, and
    # refusing to deploy would leave the server down.
    log "WARN: snapshot is empty or unreadable ($SNAP), continuing without it"
    rm -f "$SNAP"
  else
    log "snapshot ok ($(du -h "$SNAP" | cut -f1))"
    ls -1t "$BACKUP_DIR"/actual-data-*.tar.gz 2>/dev/null \
      | tail -n +$((KEEP_BACKUPS + 1)) \
      | while read -r old; do
          log "removing old snapshot $(basename "$old")"
          rm -f "$old"
        done
  fi
fi

log 'starting services'
docker compose up -d --remove-orphans

# A changed Caddyfile needs an explicit reload: compose does not notice edits
# behind a bind mount. This also fails the deploy on an invalid config.
log 'reloading caddy config'
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile

log 'waiting for the app on loopback'
ok=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:5006/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != 1 ]; then
  log 'FATAL: /health on loopback never answered'
  docker compose logs --tail=20 actual_server
  exit 1
fi

log "waiting for https://$DOMAIN"
ok=0
for _ in $(seq 1 12); do
  if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [ "$ok" != 1 ]; then
  log "FATAL: https://$DOMAIN/health never answered"
  exit 1
fi

log "running $(docker compose images actual_server | tail -1)"
# Old sha-tagged images pile up on a 22GB disk; keep two weeks of rollback.
docker image prune -af --filter 'until=336h' >/dev/null 2>&1 || true
log "deploy complete: https://$DOMAIN"
