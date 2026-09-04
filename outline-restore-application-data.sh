#!/bin/bash
set -euo pipefail

# # outline-restore-application-data.sh Description
# This script is designed to restore the application data.
# 1. **Identify Containers**: Similarly to the database restore script, it identifies the service and backups containers by name.
# 2. **List Application Data Backups**: Displays all available application data backups at the specified backup path.
# 3. **Select Backup**: Asks the user to copy and paste the desired backup name for application data restoration.
# 4. **Stop Service**: Stops the service to prevent any conflicts during the restore process.
# 5. **Restore Application Data**: Removes the current application data and then extracts the selected backup to the appropriate application data path.
# 6. **Start Service**: Restarts the service after the application data has been successfully restored.
# To make the `outline-restore-application-data.sh` script executable, run the following command:
# `chmod +x outline-restore-application-data.sh`
# By utilizing this script, you can efficiently restore application data from an existing backup while ensuring proper coordination with the running service.

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

OUTLINE_CONTAINER="$(resolve_container minio)"
OUTLINE_BACKUPS_CONTAINER="$(resolve_container backups-outline)"
BACKUP_PATH="/srv/outline-application-data/backups/"
RESTORE_PATH="/data/"
BACKUP_PREFIX="outline-application-data"

echo "--> All available application data backups:"

for entry in $(docker container exec -it "$OUTLINE_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore application data and press [ENTER]
--> Example: ${BACKUP_PREFIX}-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "

read -r SELECTED_APPLICATION_BACKUP

echo "--> $SELECTED_APPLICATION_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$OUTLINE_CONTAINER"

echo "--> Restoring application data..."
docker exec -it "$OUTLINE_BACKUPS_CONTAINER" sh -c "rm -rf ${RESTORE_PATH}* && tar -zxpf ${BACKUP_PATH}${SELECTED_APPLICATION_BACKUP} -C /"
echo "--> Application data recovery completed..."

echo "--> Starting service..."
docker start "$OUTLINE_CONTAINER"
