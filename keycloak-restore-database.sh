#!/bin/bash
set -euo pipefail

# # keycloak-restore-database.sh Description
# This script facilitates the restoration of a database backup.
# 1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.
# 2. **List Backups**: Displays all available database backups located at the specified backup path.
# 3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.
# 4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.
# 5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.
# 6. **Start Service**: Restarts the service after the restoration is completed.
# To make the `keycloak-restore-database.shh` script executable, run the following command:
# `chmod +x keycloak-restore-database.sh`
# Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

# Containers are resolved through Compose, not through a name filter. Every
# service in this stack deploys under one project ("outline" in the README), so
# a filter like "name=keycloak-keycloak" matches nothing and the script then
# runs docker stop and docker exec against an empty id.
COMPOSE_FILE="02-keycloak-outline-docker-compose.yml"
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

KEYCLOAK_CONTAINER="$(resolve_container keycloak)"
KEYCLOAK_BACKUPS_CONTAINER="$(resolve_container backups-keycloak)"
KEYCLOAK_DB_NAME="keycloakdb"
KEYCLOAK_DB_USER="keycloakdbuser"
BACKUP_PATH="/srv/keycloak-postgres/backups/"

echo "--> All available database backups:"

for entry in $(docker container exec "$KEYCLOAK_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: keycloak-postgres-backup-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "

read -r SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$KEYCLOAK_CONTAINER"

echo "--> Restoring database..."
docker exec "$KEYCLOAK_BACKUPS_CONTAINER" sh -c "dropdb -h postgres-keycloak -p 5432 $KEYCLOAK_DB_NAME -U $KEYCLOAK_DB_USER \
&& createdb -h postgres-keycloak -p 5432 $KEYCLOAK_DB_NAME -U $KEYCLOAK_DB_USER \
&& gunzip -c ${BACKUP_PATH}${SELECTED_DATABASE_BACKUP} | psql -h postgres-keycloak -p 5432 $KEYCLOAK_DB_NAME -U $KEYCLOAK_DB_USER"
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start "$KEYCLOAK_CONTAINER"
