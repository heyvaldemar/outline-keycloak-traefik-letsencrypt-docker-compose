#!/bin/bash

# Copy every attachment out of the MinIO volume this stack used before v2.0.0
# and into Garage, then verify the two agree.
#
#     chmod +x outline-minio-to-garage.sh
#     ./outline-minio-to-garage.sh --dry-run     # count both sides, copy nothing
#     ./outline-minio-to-garage.sh
#
# RUN IT AFTER `up -d` ON v2.0.0 AND BEFORE ANYONE UPLOADS ANYTHING NEW.
# Garage has to be running, because this copies into it over S3. MinIO does
# not: the old container is gone from the compose file, so this starts a
# throwaway one against the `minio-data` volume, reads through it, and removes
# it again. Nothing is written to that volume and nothing is deleted from it —
# the old objects are still there afterwards, which is what makes this safe to
# re-run and safe to abandon half way.
#
# WHY NOT COPY THE FILES DIRECTLY. MinIO and Garage lay bytes out on disk
# differently; neither can read the other's directory. The copy has to go
# through the S3 API on both sides, which is also what proves the objects are
# readable rather than merely present.
set -euo pipefail
cd "$(dirname "$0")"

DRY=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

[ -f .env ] || { echo ".env not found beside this script" >&2; exit 1; }
# Read, do not execute: a compose .env is key=value with literal values.
while IFS='=' read -r k v; do [ -n "$k" ] && export "${k}=${v}"; done \
  < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-03-outline-garage-redis-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-outline}"
NET="${OUTLINE_NETWORK:-outline-network}"
BUCKET="${OUTLINE_S3_BUCKET_NAME:-data}"
OLD_BUCKET="${OUTLINE_MINIO_BUCKET_NAME:-data}"
MINIO_VOLUME="${OUTLINE_MINIO_VOLUME:-${PROJECT}_minio-data}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.71}"
MINIO_IMAGE="${OUTLINE_MINIO_IMAGE_TAG:-minio/minio:RELEASE.2025-09-07T16-13-09Z}"

for v in OUTLINE_MINIO_ADMIN_PASSWORD OUTLINE_S3_ACCESS_KEY OUTLINE_S3_SECRET_KEY; do
  [ -n "${!v:-}" ] || { echo "$v is not set in .env — it is needed to read the old bucket" >&2; exit 1; }
done

docker volume inspect "$MINIO_VOLUME" > /dev/null 2>&1 || {
  echo "no volume named $MINIO_VOLUME — nothing to migrate."
  echo "If your project name differs, set OUTLINE_MINIO_VOLUME to the volume holding the old objects:"
  docker volume ls --format '  {{.Name}}' | grep -i minio || true
  exit 1
}

GARAGE="$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q garage | head -n1)"
[ -n "$GARAGE" ] || { echo "garage is not running — start the stack first" >&2; exit 1; }

echo "--> starting a throwaway MinIO against $MINIO_VOLUME (read only path, nothing is written)"
OLD="outline-minio-migration-$$"
cleanup() { docker rm -f "$OLD" > /dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$OLD" --network "$NET" \
  -e MINIO_ROOT_USER="${OUTLINE_MINIO_ADMIN:-minioadmin}" \
  -e MINIO_ROOT_PASSWORD="$OUTLINE_MINIO_ADMIN_PASSWORD" \
  -v "$MINIO_VOLUME:/data" \
  "$MINIO_IMAGE" server /data > /dev/null

for _ in $(seq 1 30); do
  docker run --rm --network "$NET" "$MINIO_IMAGE" \
    sh -c "curl -fsS http://$OLD:9000/minio/health/live" > /dev/null 2>&1 && break
  sleep 2
done

rclone() {
  docker run --rm --network "$NET" \
    -e RCLONE_CONFIG_OLD_TYPE=s3 -e RCLONE_CONFIG_OLD_PROVIDER=Minio \
    -e RCLONE_CONFIG_OLD_ENDPOINT="http://$OLD:9000" \
    -e RCLONE_CONFIG_OLD_ACCESS_KEY_ID="${OUTLINE_MINIO_ADMIN:-minioadmin}" \
    -e RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY="$OUTLINE_MINIO_ADMIN_PASSWORD" \
    -e RCLONE_CONFIG_NEW_TYPE=s3 -e RCLONE_CONFIG_NEW_PROVIDER=Other \
    -e RCLONE_CONFIG_NEW_ENDPOINT="http://garage:3900" \
    -e RCLONE_CONFIG_NEW_REGION=garage \
    -e RCLONE_CONFIG_NEW_FORCE_PATH_STYLE=true \
    -e RCLONE_CONFIG_NEW_ACCESS_KEY_ID="$OUTLINE_S3_ACCESS_KEY" \
    -e RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY="$OUTLINE_S3_SECRET_KEY" \
    "$RCLONE_IMAGE" "$@"
}

before_old="$(rclone size "OLD:$OLD_BUCKET" --json 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
before_new="$(rclone size "NEW:$BUCKET"     --json 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
echo "--> MinIO holds ${before_old:-0} objects; Garage holds ${before_new:-0}"

if [ "${before_old:-0}" -eq 0 ]; then
  echo "--> nothing to copy."
  exit 0
fi

if [ "$DRY" = "true" ]; then
  echo "--> dry run; these would be copied:"
  rclone ls "OLD:$OLD_BUCKET" | head -20
  [ "${before_old:-0}" -gt 20 ] && echo "    ... and $(( before_old - 20 )) more"
  exit 0
fi

echo "--> copying"
rclone copy "OLD:$OLD_BUCKET" "NEW:$BUCKET" --progress --transfers 4 --checkers 8

echo "--> verifying that every object arrived and matches"
echo "    (rclone will say some hashes could not be checked: MinIO and Garage"
echo "     compute ETags differently, so it falls back to comparing sizes."
echo "     'differences found' is the line that matters, and it must be 0.)"
# `check` compares sizes, and hashes where both sides expose a comparable one.
# A copy that ran to the end and produced truncated objects would pass a count
# comparison and fail here.
rclone check "OLD:$OLD_BUCKET" "NEW:$BUCKET" --one-way

after_new="$(rclone size "NEW:$BUCKET" --json 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
echo
echo "--> done: ${before_old} objects in MinIO, ${after_new:-0} now in Garage."
echo "--> The MinIO volume is untouched. Keep it until you have opened a few"
echo "--> documents with attachments and seen the images load, then:"
echo "--> docker volume rm $MINIO_VOLUME"
