# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`** — unattended updates to the newest tagged release,
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

- **Keycloak bumped 25.0 → 26.7.3** — the 25.0 pin was affected by the
  entire 2026 CVE series, including CVE-2026-18963 (unauthenticated
  account takeover via password-reset bypass, CVSS 9.1). The identity
  provider of this stack. Back up before pulling — schema migrates
  forward only.
- **Outline bumped 0.78.0 → 1.9.2**, **MinIO bumped from an August 2023
  build to the latest Docker Hub release**, **Redis 7.2 → 7.4**,
  **PostgreSQL 14 → 16** for both databases (14 reaches end-of-life in
  November 2026 — existing deployments need a dump/restore migration, see
  the release notes), **Traefik 3.2 → 3.7** (3.2's Docker client cannot
  talk to Docker Engine 29).
- **All seven images pinned by `tag@sha256:digest`** across the three
  compose files.
- **Credentials untracked from git.** The tracked `.env` carried
  generated-looking passwords for Keycloak, Outline, and MinIO — rotate
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

[Unreleased]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
