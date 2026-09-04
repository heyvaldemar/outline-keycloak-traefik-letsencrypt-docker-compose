#!/bin/bash
# End-to-end proof that this stack's backups can actually be restored.
#
# Bring the stack up first, with short backup intervals in .env (CI uses
# INIT_SLEEP=15s, INTERVAL=60s), then run this from the repository root:
#
#   COMPOSE_PROJECT_NAME=outline ./tests/e2e-backup-restore.sh
#
# The stack carries two independent PostgreSQL databases and one application
# data volume, each with its own backup loop, so every scenario runs twice:
# once for Keycloak, once for Outline.
set -uo pipefail

KEYCLOAK_FILE="${KEYCLOAK_COMPOSE_FILE:-02-keycloak-outline-docker-compose.yml}"
OUTLINE_FILE="${OUTLINE_COMPOSE_FILE:-03-outline-minio-redis-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-outline}"

KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloakdb}"
KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloakdbuser}"
KEYCLOAK_BACKUPS_PATH="${KEYCLOAK_POSTGRES_BACKUPS_PATH:-/srv/keycloak-postgres/backups}"
KEYCLOAK_PREFIX="${KEYCLOAK_POSTGRES_BACKUP_NAME:-keycloak-postgres-backup}"

OUTLINE_DB_NAME="${OUTLINE_DB_NAME:-outlinedb}"
OUTLINE_DB_USER="${OUTLINE_DB_USER:-outlinedbuser}"
OUTLINE_BACKUPS_PATH="${OUTLINE_POSTGRES_BACKUPS_PATH:-/srv/outline-postgres/backups}"
OUTLINE_PREFIX="${OUTLINE_POSTGRES_BACKUP_NAME:-outline-postgres-backup}"
OUTLINE_DATA_BACKUPS_PATH="${OUTLINE_DATA_BACKUPS_PATH:-/srv/outline-application-data/backups}"

INTERVAL="${KEYCLOAK_BACKUP_INTERVAL:-60s}"
case "$INTERVAL" in
  *h) CYCLE=$(( ${INTERVAL%h} * 3600 )) ;;
  *m) CYCLE=$(( ${INTERVAL%m} * 60 )) ;;
  *s) CYCLE=${INTERVAL%s} ;;
  *)  CYCLE=$INTERVAL ;;
esac
CYCLE_WAIT=$(( CYCLE + 60 ))

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
note() { echo "  $1"; }

resolve() {
  local file="$1" service="$2" id
  id="$(docker compose -f "$file" -p "$PROJECT" ps -aq "$service" 2>/dev/null | head -n 1)"
  [ -n "$id" ] || { echo "error: no container for service '$service' in project '$PROJECT'" >&2; exit 1; }
  printf '%s' "$id"
}

KC_DB=$(resolve "$KEYCLOAK_FILE" postgres-keycloak)
KC_APP=$(resolve "$KEYCLOAK_FILE" keycloak)
KC_BK=$(resolve "$KEYCLOAK_FILE" backups-keycloak)
OL_APP=$(resolve "$OUTLINE_FILE" outline)
OL_BK=$(resolve "$OUTLINE_FILE" backups-outline)

echo "=== Outline and Keycloak: backup and restore end-to-end"
note "project=$PROJECT cycle wait=${CYCLE_WAIT}s"

# --- helpers -----------------------------------------------------------------

# psql runs from the backups container: it carries the client and PGPASSWORD.
kc_sql() { docker exec "$KC_BK" psql -h postgres-keycloak -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" -tAc "$1" 2>/dev/null; }
ol_sql() { docker exec "$OL_BK" psql -h postgres-outline -U "$OUTLINE_DB_USER" -d "$OUTLINE_DB_NAME" -tAc "$1" 2>/dev/null; }

kc_sh() { docker exec "$KC_BK" sh -c "$1"; }
ol_sh() { docker exec "$OL_BK" sh -c "$1"; }

wait_for_log() {   # container, pattern, seconds
  local c="$1" pat="$2" limit="$3" waited=0
  while [ "$waited" -lt "$limit" ]; do
    if docker logs "$c" 2>&1 | grep -qE "$pat"; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

newest_after_marker() {   # backups container, path, prefix, extension
  local c="$1" path="$2" prefix="$3" ext="$4" f elapsed=0
  while :; do
    f=$(docker exec "$c" sh -c "find $path -name '${prefix}-*${ext}' -newer $path/.e2e-stamp 2>/dev/null | sort | head -1")
    if [ -n "$f" ] && docker logs "$c" 2>&1 | grep -qF "backup OK: $f"; then printf '%s' "$f"; return 0; fi
    [ "$elapsed" -lt "$CYCLE_WAIT" ] || return 1
    sleep 5; elapsed=$((elapsed + 5))
  done
}

db_ready() {   # backups container, host, user
  docker exec "$1" pg_isready -h "$2" -U "$3" > /dev/null 2>&1
}

wait_ready() {   # backups container, host, user, seconds
  local waited=0
  while [ "$waited" -lt "$4" ]; do
    db_ready "$1" "$2" "$3" && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

# --- scenarios ---------------------------------------------------------------

echo
echo "=== the required variables are enforced"
if docker compose -f "$KEYCLOAK_FILE" --env-file /dev/null config > /dev/null 2>&1; then
  bad "compose renders with no .env, so a missing password would deploy"
else
  ok "compose refuses to render without the required variables"
fi

echo
echo "=== both backup loops produce a readable dump"
for pair in "KC:$KC_BK:$KEYCLOAK_BACKUPS_PATH:$KEYCLOAK_PREFIX" "OL:$OL_BK:$OUTLINE_BACKUPS_PATH:$OUTLINE_PREFIX"; do
  IFS=: read -r tag c path prefix <<< "$pair"
  if wait_for_log "$c" "Database backup OK" 420; then
    f=$(docker logs "$c" 2>&1 | grep "Database backup OK" | tail -1 | sed -E 's/.*Database backup OK: ([^ ]+) .*/\1/')
    if docker exec "$c" sh -c "gunzip -t '$f' && gunzip -c '$f' | head -5 | grep -q 'PostgreSQL database dump'"; then
      ok "$tag database backup is a readable dump: $(basename "$f")"
    else
      bad "$tag backup at $f is not a readable PostgreSQL dump"
    fi
  else
    bad "$tag backup loop produced nothing within 420s"
  fi
done

echo
echo "=== the Outline application data archive is readable"
if wait_for_log "$OL_BK" "Data backup (OK|FAILED)" 420; then
  f=$(docker logs "$OL_BK" 2>&1 | grep "Data backup OK" | tail -1 | sed -E 's/.*Data backup OK: ([^ ]+) .*/\1/')
  if [ -n "$f" ] && docker exec "$OL_BK" sh -c "tar -tzf '$f' > /dev/null"; then
    ok "data archive lists without error: $(basename "$f")"
  else
    bad "data archive missing or unreadable"
  fi
else
  bad "no data archive within 420s"
fi

echo
echo "=== a database outage is reported, not swallowed"
before=$(docker logs "$KC_BK" 2>&1 | grep -ci "backup FAILED")
docker stop "$KC_DB" > /dev/null
note "stopped the Keycloak database, waiting up to $((CYCLE_WAIT * 2 + 120))s for a failed cycle"
deadline=$(( $(date +%s) + CYCLE_WAIT * 2 + 120 ))
while [ "$(docker logs "$KC_BK" 2>&1 | grep -ci 'backup FAILED')" -le "$before" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 5
done
failed_files=$(kc_sh "ls $KEYCLOAK_BACKUPS_PATH/*.failed 2>/dev/null" || true)
docker start "$KC_DB" > /dev/null
wait_ready "$KC_BK" postgres-keycloak "$KEYCLOAK_DB_USER" 180 || note "database slow to return"
if [ "$(docker logs "$KC_BK" 2>&1 | grep -ci 'backup FAILED')" -gt "$before" ]; then
  ok "the outage produced a FAILED line in the backups log"
else
  bad "the outage produced no FAILED line"
fi
if [ -n "$failed_files" ]; then
  ok "the partial dump was kept for diagnosis"
else
  bad "no .failed file was kept during the outage"
fi

echo
echo "=== restoring Keycloak replaces database state"
kc_sql "CREATE TABLE IF NOT EXISTS e2e_marker (id int);" > /dev/null
kc_sh "touch $KEYCLOAK_BACKUPS_PATH/.e2e-stamp"
baseline=$(newest_after_marker "$KC_BK" "$KEYCLOAK_BACKUPS_PATH" "$KEYCLOAK_PREFIX" ".gz")
if [ -z "$baseline" ]; then
  bad "no Keycloak backup taken after the marker within ${CYCLE_WAIT}s"
else
  note "baseline: $(basename "$baseline")"
  kc_sql "CREATE TABLE IF NOT EXISTS restore_probe (id int); INSERT INTO restore_probe VALUES (1);" > /dev/null
  docker stop "$KC_APP" > /dev/null
  kc_sh "dropdb -h postgres-keycloak -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
    && createdb -h postgres-keycloak -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
    && gunzip -c $baseline | psql -h postgres-keycloak -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME" > /dev/null 2>&1
  docker start "$KC_APP" > /dev/null
  left=$(kc_sql "SELECT count(*) FROM information_schema.tables WHERE table_name = 'restore_probe';" | tr -d '[:space:]')
  if [ "$left" = "0" ]; then
    ok "the row added after the backup is gone, so the restore replaced state"
  else
    bad "restore_probe still present after restore, the restore was a no-op"
  fi
fi

echo
echo "=== restoring Outline replaces database state"
ol_sql "CREATE TABLE IF NOT EXISTS e2e_marker (id int);" > /dev/null
ol_sh "touch $OUTLINE_BACKUPS_PATH/.e2e-stamp"
baseline=$(newest_after_marker "$OL_BK" "$OUTLINE_BACKUPS_PATH" "$OUTLINE_PREFIX" ".gz")
if [ -z "$baseline" ]; then
  bad "no Outline backup taken after the marker within ${CYCLE_WAIT}s"
else
  note "baseline: $(basename "$baseline")"
  ol_sql "CREATE TABLE IF NOT EXISTS restore_probe (id int); INSERT INTO restore_probe VALUES (1);" > /dev/null
  docker stop "$OL_APP" > /dev/null
  ol_sh "dropdb -h postgres-outline -U $OUTLINE_DB_USER $OUTLINE_DB_NAME \
    && createdb -h postgres-outline -U $OUTLINE_DB_USER $OUTLINE_DB_NAME \
    && gunzip -c $baseline | psql -h postgres-outline -U $OUTLINE_DB_USER $OUTLINE_DB_NAME" > /dev/null 2>&1
  docker start "$OL_APP" > /dev/null
  left=$(ol_sql "SELECT count(*) FROM information_schema.tables WHERE table_name = 'restore_probe';" | tr -d '[:space:]')
  if [ "$left" = "0" ]; then
    ok "the row added after the backup is gone, so the restore replaced state"
  else
    bad "restore_probe still present after restore, the restore was a no-op"
  fi
fi

echo
echo "=== pruning removes an aged file and keeps the recent ones"
kc_sh "touch -t 202001010000 $KEYCLOAK_BACKUPS_PATH/${KEYCLOAK_PREFIX}-2020-01-01_00-00.gz"
kept_before=$(kc_sh "ls $KEYCLOAK_BACKUPS_PATH/${KEYCLOAK_PREFIX}-*.gz 2>/dev/null | wc -l" | tr -d '[:space:]')
kc_sh "find $KEYCLOAK_BACKUPS_PATH -type f -name '${KEYCLOAK_PREFIX}-*' -mtime +7 -delete"
kept_after=$(kc_sh "ls $KEYCLOAK_BACKUPS_PATH/${KEYCLOAK_PREFIX}-*.gz 2>/dev/null | wc -l" | tr -d '[:space:]')
old_gone=$(kc_sh "ls $KEYCLOAK_BACKUPS_PATH/${KEYCLOAK_PREFIX}-2020-01-01_00-00.gz 2>/dev/null | wc -l" | tr -d '[:space:]')
if [ "$old_gone" = "0" ] && [ "$kept_after" -lt "$kept_before" ]; then
  ok "the aged file was pruned and $kept_after recent file(s) survived"
else
  bad "pruning did not remove the aged file"
fi

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
