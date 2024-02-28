# Outline with Keycloak and Let's Encrypt Using Docker Compose

📙 The complete installation guide is available on my [website](https://www.heyvaldemar.com/install-outline-and-keycloak-using-docker-compose/).

❗ Change variables in the `.env` to meet your requirements.

💡 Note that the `.env` file should be in the same directory as `01-traefik-outline-letsencrypt-docker-compose.yml`, `02-keycloak-outline-docker-compose.yml`, and `03-outline-minio-redis-docker-compose.yml`.

❗ The value for the `OUTLINE_OIDC_CLIENT_SECRET` variable can be obtained after installing Keycloak using `02-keycloak-outline-docker-compose.yml`.

❗ Additionally, you need to specify your values for `OUTLINE_SECRET_KEY` and `OUTLINE_UTILS_SECRET`.

The values for `OUTLINE_SECRET_KEY` and `OUTLINE_UTILS_SECRET` can be generated using the command:

`openssl rand -hex 32`

Create networks for your services before deploying the configuration using the commands:

`docker network create traefik-network`

`docker network create keycloak-network`

`docker network create outline-network`

Deploy Traefik using Docker Compose:

`docker compose -f 01-traefik-outline-letsencrypt-docker-compose.yml -p traefik up -d`

Deploy Keycloak using Docker Compose:

`docker compose -f 02-keycloak-outline-docker-compose.yml -p keycloak up -d`

Create a new `Realm` on Keycloak and name it `outline` (case sensitive).

Create a `Client` in the new realm and configure it:

1. Client type: `OpenID Connect`
2. Client ID: `outline` (case sensitive)
3. Client authentication: `on`
4. Authentication flow: uncheck all other options and leave only `Standard flow`
5. Set URLs:

- In the `Root URL` field, enter `https://outline.heyvaldemar.net/`
- In the `Home URL` field, enter `https://outline.heyvaldemar.net/`
- In the `Valid redirect URIs` field, enter `https://outline.heyvaldemar.net/*`

💡 Please note, outline.heyvaldemar.net is the domain name of my service. Accordingly, you need to specify your domain name, which points to the IP address of your server with the installed Traefik service, which will redirect the request to Outline.

Get a `Client secret` value on the `Credentials` tab of the `Client` that you created.

Specify the `OUTLINE_OIDC_CLIENT_SECRET` variable in the `.env`.

Create a user on Keycloak for Outline.

Note that you have to specify an email address and a username.

Set a password for the new user.

Deploy Keycloak using Docker Compose:

`docker compose -f 03-outline-minio-redis-docker-compose.yml -p outline up -d`

Log in to Outline with the Username or Email specified on the Keycloak.

# Backups

The `backups-keycloak` container in the configuration is responsible for the following:

1. **Database Backup**: Creates compressed backups of the PostgreSQL database using pg_dump.
Customizable backup path, filename pattern, and schedule through variables like `KEYCLOAK_POSTGRES_BACKUPS_PATH`, `KEYCLOAK_POSTGRES_BACKUP_NAME`, and `KEYCLOAK_BACKUP_INTERVAL`.

2. **Backup Pruning**: Periodically removes backups exceeding a specified age to manage storage. Customizable pruning schedule and age threshold with `KEYCLOAK_POSTGRES_BACKUP_PRUNE_DAYS`.

The `backups-outline` container in the configuration is responsible for the following:

1. **Application Data Backup**: Compresses and stores backups of the application data on the same schedule. Controlled via variables such as `OUTLINE_DATA_BACKUPS_PATH`, `OUTLINE_DATA_BACKUP_NAME`, and `OUTLINE_BACKUP_INTERVAL`.

2. **Backup Pruning**: Periodically removes backups exceeding a specified age to manage storage. Customizable pruning schedule and age threshold with `OUTLINE_DATA_BACKUP_PRUNE_DAYS`.

By utilizing these containers, consistent and automated backups of the essential components of your instance are ensured. Moreover, efficient management of backup storage and tailored backup routines can be achieved through easy and flexible configuration using environment variables.

# keycloak-restore-database.sh Description

This script facilitates the restoration of a database backup:

1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.

2. **List Backups**: Displays all available database backups located at the specified backup path.

3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.

4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.

5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.

6. **Start Service**: Restarts the service after the restoration is completed.

To make the `keycloak-restore-database.shh` script executable, run the following command:

`chmod +x keycloak-restore-database.sh`

Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

# outline-restore-database.sh Description

This script facilitates the restoration of a database backup:

1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.

2. **List Backups**: Displays all available database backups located at the specified backup path.

3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.

4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.

5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.

6. **Start Service**: Restarts the service after the restoration is completed.

To make the `outline-restore-database.shh` script executable, run the following command:

`chmod +x outline-restore-database.sh`

Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

# outline-restore-application-data.sh Description

This script is designed to restore the application data:

1. **Identify Containers**: Similarly to the database restore script, it identifies the service and backups containers by name.

2. **List Application Data Backups**: Displays all available application data backups at the specified backup path.

3. **Select Backup**: Asks the user to copy and paste the desired backup name for application data restoration.

4. **Stop Service**: Stops the service to prevent any conflicts during the restore process.

5. **Restore Application Data**: Removes the current application data and then extracts the selected backup to the appropriate application data path.

6. **Start Service**: Restarts the service after the application data has been successfully restored.

To make the `outline-restore-application-data.sh` script executable, run the following command:

`chmod +x outline-restore-application-data.sh`

By utilizing this script, you can efficiently restore application data from an existing backup while ensuring proper coordination with the running service.

# Author

I’m Vladimir Mikhalev, the [Docker Captain](https://www.docker.com/captains/vladimir-mikhalev/), but my friends can call me Valdemar.

🌐 My [website](https://www.heyvaldemar.com/) with detailed IT guides\
🎬 Follow me on [YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1)\
🐦 Follow me on [Twitter](https://twitter.com/heyValdemar)\
🎨 Follow me on [Instagram](https://www.instagram.com/heyvaldemar/)\
🧵 Follow me on [Threads](https://www.threads.net/@heyvaldemar)\
🐘 Follow me on [Mastodon](https://mastodon.social/@heyvaldemar)\
🧊 Follow me on [Bluesky](https://bsky.app/profile/heyvaldemar.bsky.social)\
🎸 Follow me on [Facebook](https://www.facebook.com/heyValdemarFB/)\
🎥 Follow me on [TikTok](https://www.tiktok.com/@heyvaldemar)\
💻 Follow me on [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)\
🐈 Follow me on [GitHub](https://github.com/heyvaldemar)

# Communication

👾 Chat with IT pros on [Discord](https://discord.gg/AJQGCCBcqf)\
📧 Reach me at ask@sre.gg

# Give Thanks

💎 Support on [GitHub](https://github.com/sponsors/heyValdemar)\
🏆 Support on [Patreon](https://www.patreon.com/heyValdemar)\
🥤 Support on [BuyMeaCoffee](https://www.buymeacoffee.com/heyValdemar)\
🍪 Support on [Ko-fi](https://ko-fi.com/heyValdemar)\
💖 Support on [PayPal](https://www.paypal.com/paypalme/heyValdemarCOM)
