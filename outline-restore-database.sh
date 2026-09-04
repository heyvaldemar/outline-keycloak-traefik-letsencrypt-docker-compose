#!/bin/bash
set -euo pipefail

# # outline-restore-database.sh Description
# This script facilitates the restoration of a database backup.
# 1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.
# 2. **List Backups**: Displays all available database backups located at the specified backup path.
# 3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.
# 4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.
# 5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.
# 6. **Start Service**: Restarts the service after the restoration is completed.
# To make the `outline-restore-database.shh` script executable, run the following command:
# `chmod +x outline-restore-database.sh`
# Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

# Containers are resolved through Compose, not through a name filter. Every
# service in this stack deploys under one project ("outline" in the README), so
# a filter like "name=keycloak-keycloak" matches nothing and the script then
# runs docker stop and docker exec against an empty id.
COMPOSE_FILE="03-outline-minio-redis-docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-outline}"

resolve_container() {
  local service="$1" id
  id="$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q "$service" 2>/dev/null | head -n 1)"
  if [ -z "$id" ]; then
    echo "error: no container for service '$service' in project '$PROJECT'." >&2
    echo "       Run this script from the directory holding $COMPOSE_FILE, and set" >&2
    echo "       COMPOSE_PROJECT_NAME if you deployed under a different project name." >&2
    exit 1
  fi
  printf '%s' "$id"
}

OUTLINE_CONTAINER="$(resolve_container outline)"
OUTLINE_BACKUPS_CONTAINER="$(resolve_container backups-outline)"
OUTLINE_DB_NAME="outlinedb"
OUTLINE_DB_USER="outlinedbuser"
BACKUP_PATH="/srv/outline-postgres/backups/"

echo "--> All available database backups:"

for entry in $(docker container exec "$OUTLINE_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: outline-postgres-backup-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "

read -r SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$OUTLINE_CONTAINER"

echo "--> Restoring database..."
docker exec "$OUTLINE_BACKUPS_CONTAINER" sh -c "dropdb -h postgres-outline -p 5432 $OUTLINE_DB_NAME -U $OUTLINE_DB_USER \
&& createdb -h postgres-outline -p 5432 $OUTLINE_DB_NAME -U $OUTLINE_DB_USER \
&& gunzip -c ${BACKUP_PATH}${SELECTED_DATABASE_BACKUP} | psql -h postgres-outline -p 5432 $OUTLINE_DB_NAME -U $OUTLINE_DB_USER"
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start "$OUTLINE_CONTAINER"
