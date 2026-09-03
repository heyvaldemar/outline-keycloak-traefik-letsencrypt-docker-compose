# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.5.0] - 2026-09-03

### Added

- **Per-image version overrides.** Every pin in the `x-images` block is
  now `${<PREFIX>_IMAGE_TAG:-repo:${<PREFIX>_IMAGE_VERSION:-tag@sha256:digest}}`.
  Set `<PREFIX>_IMAGE_VERSION` in `.env` to run a different version of one
  image while every other pin stays as tested (Compose pulls that tag
  without a digest), or `<PREFIX>_IMAGE_TAG` to replace the whole
  reference as before. A deployment that sets neither is unchanged. The
  freshness job, the Trivy matrix and the fleet digest automation resolve
  the nested default before reading a pin. Needs Docker Compose v2.5 or
  newer (2022): v2.0 to v2.4 leave the inner `${...}` unexpanded and
  `docker compose up` fails with an invalid reference instead of
  deploying something unexpected.

## [1.4.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

## [1.3.0] - 2026-09-02

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  Both backup loops (Keycloak and Outline databases) had the flaw: the old loop piped the dump into `gzip` and only checked `gzip`'s exit
  status, so a dump that failed halfway (database down, wrong password,
  disk full) still left a small `.gz` that looked like a backup. The loop
  now runs with `pipefail`, logs `Database backup OK: <file> (<bytes>
  bytes)` or `Database backup FAILED` per cycle, keeps a failed dump as
  `<file>.failed` for diagnosis, and prunes only its own files. Retention
  set to `0` disables pruning instead of deleting everything.

### Added

- CI now waits for the first backup cycle and proves the produced
  archive is readable and contains a real dump header (plus a readable
  `tar.gz` for the data backup where the stack has one).

## [1.2.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`**: unattended updates to the newest tagged release,
  and nothing else: a tag is cut only after CI has booted the pinned
  images and passed the smoke tests, so "update to the latest tag" means
  "update to a combination a machine has already run". It refuses to
  cross a major version on its own (`--allow-major` after reading the
  notes), refuses a checkout with local modifications, and supports
  `--dry-run`. Put it on a cron timer for hands-off minor/patch updates.

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Keycloak bumped 25.0 → 26.7.3**: the 25.0 pin was affected by the
  entire 2026 CVE series, including CVE-2026-18963 (unauthenticated
  account takeover via password-reset bypass, CVSS 9.1). The identity
  provider of this stack. Back up before pulling. Schema migrates
  forward only.
- **Outline bumped 0.78.0 → 1.9.2**, **MinIO bumped from an August 2023
  build to the latest Docker Hub release**, **Redis 7.2 → 7.4**,
  **PostgreSQL 14 → 16** for both databases (14 reaches end-of-life in
  November 2026: existing deployments need a dump/restore migration, see
  the release notes), **Traefik 3.2 → 3.7** (3.2's Docker client cannot
  talk to Docker Engine 29).
- **All seven images pinned by `tag@sha256:digest`** across the three
  compose files.
- **Credentials untracked from git.** The tracked `.env` carried
  generated-looking passwords for Keycloak, Outline, and MinIO. Rotate
  all of them if your deployment reused them.
- Keycloak admin bootstrap moved to the KC 26 `KC_BOOTSTRAP_ADMIN_*`
  variables.

### Changed

- **Image pins live in each compose file's `x-images` block** as
  interpolation defaults; `.env` carries only secrets, hostnames, and
  deliberate overrides. Backup loops `$$`-escaped.
- README rebuilt to the fleet evaluator-first structure.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of six unique pinned images; weekly `check-pin-freshness`
  (digest drift across all seven pins + Keycloak/Outline/Traefik release
  lag); deploy-and-test that boots all three stacks in order and
  requires Keycloak healthy, MinIO live through Traefik, and the Outline
  login page through Traefik.

### Fixed

- Shellcheck findings in all three restore scripts.

[Unreleased]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
