# Outline + Keycloak + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Configuring the Keycloak realm for Outline](#configuring-the-keycloak-realm-for-outline)
- [Features](#features)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **Outline** (team wiki) with **Keycloak** as its OIDC identity provider, **MinIO** for file storage, **PostgreSQL** ×2 and **Redis**, all behind **Traefik** with automatic **Let's Encrypt TLS** — three compose files deployed in order, with scheduled backups and restore scripts. The full self-hosted knowledge-base experience with real SSO at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-outline-and-keycloak-using-docker-compose/](https://www.heyvaldemar.com/install-outline-and-keycloak-using-docker-compose/).

## Why this stack?

| Need | This stack | Outline's own compose | Manual assembly |
|------|-----------|----------------------|-----------------|
| Real SSO out of the box | ✅ Keycloak OIDC | ❌ bring your own IdP | Hours of wiring |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME | ❌ | Manual certbot |
| S3-compatible file storage included | ✅ MinIO | ❌ external S3 | Separate setup |
| Scheduled backups (2 DBs + files) + restore scripts | ✅ | ❌ | Manual cron |
| All images pinned by `sha256` digest | ✅ 7 pins | ❌ floating | Rare |
| Weekly pin-freshness check in CI | ✅ | ❌ | Rare |
| CI-verified deployment on every push | ✅ 3 stacks booted | ❌ | Rare |

Nine services across three compose files, deployed in strict order. Heavier than a single-app template — this is a complete platform.

## Prerequisites

- **A Linux server** with a public IP and **~4 GB free RAM** for the full stack.
- **Docker Engine 24+ and Docker Compose 2.20+.**
- **A domain you control,** with **five** `A` records pointing at your server's public IP: Outline, Keycloak, MinIO S3, MinIO console, and the Traefik dashboard (see `.env.example`). DNS must propagate before deploy.
- **Ports 80 and 443 open** on the server's firewall.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose
cd outline-keycloak-traefik-letsencrypt-docker-compose

# 2. Create the three Docker networks the stacks expect
docker network create traefik-network
docker network create keycloak-network
docker network create outline-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ See .env.example — hostnames, passwords, Outline secrets, and the
#   OIDC endpoints (the client secret arrives in the realm step below).

# 4. Deploy in order
docker compose -f 01-traefik-outline-letsencrypt-docker-compose.yml -p outline up -d
docker compose -f 02-keycloak-outline-docker-compose.yml -p outline up -d
docker compose -f 03-outline-minio-redis-docker-compose.yml -p outline up -d
```

Keycloak, MinIO, and Outline come up with fresh Let's Encrypt certificates. Outline's login page appears immediately; signing in works after the realm step below.

## Configuring the Keycloak realm for Outline

1. Log in to `https://${KEYCLOAK_HOSTNAME}` with `KEYCLOAK_ADMIN_USERNAME` / `KEYCLOAK_ADMIN_PASSWORD`.
2. Create a realm named `outline`.
3. In the realm, create a client `outline`: client type OpenID Connect, client authentication ON, valid redirect URI `https://${OUTLINE_HOSTNAME}/auth/oidc.callback`.
4. Copy the client secret (client → Credentials) into `OUTLINE_OIDC_CLIENT_SECRET` in `.env`.
5. Create your users in the realm (email required — Outline maps accounts by the email claim).
6. Recreate Outline: `docker compose -f 03-outline-minio-redis-docker-compose.yml -p outline up -d --force-recreate`.

Sign in on Outline via the Keycloak button — first user in becomes the workspace admin.

### What success looks like

```bash
# All nine services healthy / up:
docker ps --filter name=outline

# Keycloak health:
docker inspect -f '{{.State.Health.Status}}' "$(docker ps -qf name=keycloak | head -1)"

# MinIO liveness through Traefik:
curl -fsS "https://${OUTLINE_MINIO_HOSTNAME}/minio/health/live" -o /dev/null -w "%{http_code}\n"

# Outline front page:
curl -fsSL "https://${OUTLINE_HOSTNAME}/" -o /dev/null -w "%{http_code}\n"
```

### Common first-deploy issues

- **Cert issuance fails.** One of the five DNS records hasn't propagated, or port 80 isn't reachable.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it.
- **Networks not found.** Step 2 was skipped — all three networks are required.
- **OIDC error on login.** Realm/client mismatch: verify the redirect URI, the client secret, and that the three `OUTLINE_OIDC_*_URI` values use your Keycloak hostname and the `outline` realm.

## Features

- **Outline** latest stable (1.9 line) — documents, collections, search, real-time collaboration.
- **Keycloak 26.7** as the OIDC provider — users, groups, MFA, federation if you need it.
- **MinIO** S3-compatible storage for uploads, with its own console.
- **Two PostgreSQL 16 instances** (Keycloak and Outline isolated) and **Redis 7.4**.
- **Traefik v3** with automatic HTTPS for all five hostnames.
- **Scheduled backups**: both databases (`pg_dump | gzip`) and MinIO data (`tar.gz`), with retention pruning and three restore scripts.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete.

## Supply chain trust

This repository is a **deployment template**. Seven images across three compose files, each pinned to `tag@sha256:<digest>` as interpolation defaults in that file's `x-images` block — `git pull` alone delivers the version combination this repository has tested; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

- [`traefik`](https://hub.docker.com/_/traefik), [`postgres`](https://hub.docker.com/_/postgres) ×2, [`redis`](https://hub.docker.com/_/redis) — Docker Hub official images
- [`quay.io/keycloak/keycloak`](https://quay.io/repository/keycloak/keycloak) — Keycloak upstream
- [`outlinewiki/outline`](https://hub.docker.com/r/outlinewiki/outline) — Outline upstream
- [`minio/minio`](https://hub.docker.com/r/minio/minio) — MinIO upstream

The weekly `check-pin-freshness` CI job re-resolves all seven pins against their registries and compares the pinned Keycloak, Outline, and Traefik versions against the latest upstream releases. CI runs on every push, pull request, and every Monday at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Strong secrets everywhere** — six generated passwords/secrets in `.env`; regenerate the Traefik dashboard hash per deployment.
- [ ] **Complete the realm step** and disable Keycloak's bootstrap admin after creating named admins.
- [ ] **Restrict MinIO console exposure** if you don't need it publicly.
- [ ] **Host-mount the backup volumes** for disaster recovery.
- [ ] **Verify Let's Encrypt certs** for all five hostnames in the Traefik logs.
- [ ] **Back up before upgrades** — Keycloak and Outline both migrate schemas forward only.
- [ ] **Know the restore procedure.** Three scripts: Keycloak DB, Outline DB, MinIO data.

## Backups

Two backup sidecars run dump → prune → sleep loops: one for the Keycloak database, one for the Outline database + MinIO data directory. All knobs configured via `.env` with compose-level defaults (30-minute warm-up, 24-hour interval, 7-day retention).

**Restore** with the interactive scripts (`chmod +x *.sh` once): `./keycloak-restore-database.sh`, `./outline-restore-database.sh`, `./outline-restore-application-data.sh`.

## Unattended updates

Releases are the update channel: a tag is cut only after CI has built the pinned images, booted the full stack, and passed the smoke tests. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor/patch updates:

```bash
# crontab -e
17 5 * * *  /opt/outline-keycloak-traefik-letsencrypt-docker-compose/update.sh >> /var/log/outline-keycloak-update.log 2>&1
```

The script refuses to cross a MAJOR template version on its own — majors are breaking by definition and their release notes exist to be read. After reading them, `./update.sh --allow-major` performs the jump. It also refuses to touch a checkout with local modifications: your customization belongs in `.env`, which updates never overwrite.

This is deliberately a host-side script and not a container in the stack: an in-stack updater needs the Docker socket (root on the host) and turns "someone pushed to a repo" into "someone deployed to your machine" with no operator in the loop. A cron job under your own user updates only to tagged, CI-verified states and leaves the trust boundary where it was.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults — the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every Monday at 06:00 UTC:

1. **Lint** — shellcheck on all three restore scripts, actionlint on the workflow.
2. **Trivy scans** of six unique pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (weekly/manual) — digest drift across all seven pins plus release-lag checks for Keycloak, Outline, and Traefik.
4. **Deploy-and-test** — boots all three stacks in order with ephemeral credentials and requires: Keycloak healthy, MinIO liveness through Traefik, and the Outline login page through Traefik.

A green run is the authoritative proof that the template deploys end-to-end.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- **Pre-rotation advisory.** Releases before v1.0.0 (2026-08-31) shipped a tracked `.env` with generated-looking passwords for Keycloak, Outline, and MinIO. Rotate all of them if your deployment reused them.
- Databases and Redis listen only on internal networks.
- Upstream image digests are pinned; the weekly freshness job flags drift loudly.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
