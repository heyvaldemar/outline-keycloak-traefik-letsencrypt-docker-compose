#!/usr/bin/env bash
# outline-restore-application-data.sh [backup-file-name]
#
# Replaces Outline's attachments - Garage's metadata and data directories -
# with one of the archives the backups service wrote.
#
#   ./outline-restore-application-data.sh               list and ask
#   ./outline-restore-application-data.sh <file-name>   restore that one
#
# EVERY PATH AND NAME COMES FROM THE RUNNING BACKUPS CONTAINER.
# The previous version looked for a service called minio, which this stack has
# not had since Garage replaced MinIO in 2.0.0, so it stopped before doing
# anything. It could not have helped anyway: until 2.1.0 the backup loop
# archived the old minio-data volume, and the attachments in Garage were in no
# backup at all.
#
# THE METADATA COMES FROM GARAGE'S OWN SNAPSHOT. The archive is taken while
# Garage runs, so the db.sqlite in it can be caught mid-write. Garage writes a
# consistent copy to meta/snapshots/<time>/db.sqlite every hour (garage.toml), and
# putting the newest one back as db.sqlite is Garage's documented recovery.
# An attachment uploaded after that snapshot and before the backup has its data
# in the archive but no metadata, and does not come back.
#
# CI runs this exact file: an object stored before a backup must be readable
# through S3 after the restore, and one stored after it must be gone.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than outline.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-outline}"

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid outline)"; GARAGE="$(cid garage)"; BKP="$(cid backups-outline)"
[ -n "$BKP" ] || { echo "error: no backups-outline container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no outline container in compose project '$PROJECT'" >&2; exit 1; }
[ -n "$GARAGE" ] || { echo "error: no garage container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of OUTLINE_DATA_BACKUPS_PATH)"; NAME="$(env_of OUTLINE_DATA_BACKUP_NAME)"; DATA="$(env_of OUTLINE_DATA_PATH)"
case "$DATA" in ""|/) echo "error: OUTLINE_DATA_PATH is '$DATA'; refusing to clear it" >&2; exit 1 ;; esac

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Attachment backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.tar\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" tar -tzf "$DIR/$SELECTED" > /dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping Outline and Garage so nothing writes while the attachments are replaced"
docker stop "$APP" "$GARAGE" > /dev/null
restart() {
  docker start "$GARAGE" > /dev/null && echo "Started Garage"
  docker start "$APP" > /dev/null && echo "Started Outline"
}
trap 'restart' EXIT
echo "Restoring $SELECTED into $DATA"
# meta and data are mount points in the backups container, so their contents
# are cleared rather than the directories themselves. The archive holds both
# relative to /, so it is extracted at /.
if ! docker exec "$BKP" sh -c "set -eu
    find '$DATA/meta' '$DATA/data' -mindepth 1 -delete
    tar -xzpf '$DIR/$SELECTED' -C /
    snap=\$(ls -1 '$DATA/meta/snapshots' 2>/dev/null | sort | tail -n 1)
    if [ -n \"\$snap\" ] && [ -f '$DATA/meta/snapshots/'\"\$snap\"/db.sqlite ]; then
      rm -f '$DATA/meta/db.sqlite-wal' '$DATA/meta/db.sqlite-shm'
      cp '$DATA/meta/snapshots/'\"\$snap\"/db.sqlite '$DATA/meta/db.sqlite'
      echo \"Metadata from Garage's snapshot \$snap\"
    else
      echo 'This archive holds no Garage snapshot; the metadata is the live copy it was taken from' >&2
    fi"; then
  echo "error: the restore failed part-way; $DATA may be incomplete. Restore another archive before using Outline." >&2
  exit 1
fi
echo "Restored $SELECTED into $DATA"
