# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [2.0.1] - 2026-09-13

### Fixed

- **The MinIO to Garage migration could no longer pull MinIO.** MinIO removed
  `minio/minio` from Docker Hub, so `outline-minio-to-garage.sh` and the CI step
  that proves it both died on `pull access denied for minio/minio, repository
  does not exist`. The migration is the whole upgrade path off the 1.x releases,
  and it had stopped being runnable by anybody.

  The same release is still published on quay.io. Every reference points there
  now, pinned by the digest quay serves, and the migration was run end to end
  against it before this went out: the server starts, the health endpoint
  answers, and `mc` writes into the old bucket exactly as the test drives it.

  This is not a MinIO version change. It is the same release from a registry
  that still has it.

## [2.0.0] - 2026-09-11

### Changed

- **MinIO is replaced by Garage. This is why the major version moved, and an
  upgrade needs one command you have to run yourself.** MinIO's community
  server was archived on 25 April 2026: the repository is read-only, there will
  be no further releases, and the last published container image is
  `RELEASE.2025-09-07`. Keeping a team's documents behind a storage server that
  will never be patched again is not a trade-off, it is a deadline.

  **Existing attachments do not move by themselves.** They are in the
  `minio-data` volume, which nothing in this stack starts against any more.
  `outline-minio-to-garage.sh` copies them: it starts a throwaway MinIO against
  the old volume, copies every object through the S3 API on both sides, and has
  `rclone` compare the two afterwards. It writes nothing to the old volume and
  deletes nothing from it, so it is safe to re-run and safe to abandon half
  way. The README section is called *Upgrading from 1.x*.

  Garage was not assumed to be a drop-in. Every S3 operation Outline performs
  was exercised against it before the swap and is now asserted on every CI run,
  through Traefik on the public hostname rather than against the container:

  | operation | why it is in the list |
  | :--- | :--- |
  | presigned POST | Outline's default upload method — the browser posts a signed policy |
  | presigned PUT | the alternative upload method |
  | presigned GET | how an attachment reaches a reader |
  | multipart upload | large files: create, upload, list, complete, abort |
  | bucket CORS | a browser uploading cross-origin needs it settable |
  | direct put/get/delete with `ACL: private` | what the server itself does |

  Through Traefik on purpose: a SigV4 signature covers the Host header, so a
  proxy that rewrote it would invalidate every presigned URL Outline hands out.
  That is what `passhostheader` is for, and the contract test is what would
  notice if it were removed.

  CI also proves the migration rather than describing it. Every build creates
  the old volume, fills it through a real MinIO, runs the shipped script, and
  reads the objects back out of Garage.

- **`03-outline-minio-redis-docker-compose.yml` is now
  `03-outline-garage-redis-docker-compose.yml`.** A file named after a
  component it no longer runs is a small lie that costs a reader real time.
  Every command in the README, `update.sh`, the restore scripts and CI moved
  with it.

- **There is no storage console any more, and no second hostname for it.**
  Garage has no web interface. `mc` or any S3 client is how you look inside a
  bucket now, and `OUTLINE_MINIO_CONSOLE_HOSTNAME` and
  `OUTLINE_MINIO_CONSOLE_URL` are gone. Four DNS records instead of five.

- **`AWS_S3_FORCE_PATH_STYLE` is now `true`.** Virtual-hosted style puts the
  bucket in a subdomain, which behind one Traefik hostname needs a wildcard
  certificate and a wildcard DNS record. Path style keeps everything on the
  hostname the certificate already covers.

### Added

- **A Garage bootstrap that runs as part of `up -d`**, rather than a script you
  have to remember afterwards. It creates the storage layout, imports the
  access key from `.env` and creates the bucket, then exits; Outline waits for
  it to have exited successfully. It is idempotent — on a configured stack it
  changes nothing and says what it found.

  It talks to Garage's admin API over HTTP rather than running the `garage`
  binary, and that is forced: the Garage image is built `FROM scratch` and
  contains nothing but that binary, so an init container with a script in it
  cannot start at all. The key is *imported* rather than created, because
  `CreateKey` invents a pair that a human would then have to paste back into
  `.env` after every rebuild.

### Fixed

- **The migration step's health probe could never have answered.** It ran
  `docker run … minio/minio sh -c "curl …"`, and that image has an entrypoint —
  so it asked the minio binary to run a subcommand called `sh`. The probe
  failed every time, and under `timeout` that reads as a slow start rather than
  a check that cannot work. `--entrypoint sh` now, and the whole step was run
  end to end locally rather than read.
- **The workflow names its compose project literally.** Two new steps used
  `$COMPOSE_PROJECT_NAME`, copied from a sibling template; this workflow only
  defines that variable inside one step, so compose got an empty project name,
  `ps -aq garage-init` returned nothing, and the assertion reported a bootstrap
  that had in fact just printed "bootstrap complete". The second use would have
  created a volume called `_minio-data`.
- **The upgrade drill follows renames.** It reconstructs the previous release
  by asking git for each compose file at that tag — and this release renames
  one of them, so `git show v1.6.2:03-outline-garage-…` failed with "exists on
  disk, but not in v1.6.2" and the drill died before starting anything,
  reporting a rename as though the previous release were unbuildable. It now
  reads the rename map out of `git diff --name-status --find-renames` and asks
  for each file under the name it had then, which means the next rename needs
  no change to the workflow.
- **The upgrade drill keeps the 1.x variables it needs.** That drill starts the
  previous release on this run's volumes with this run's `.env`, which is the
  whole reason it catches data-path regressions — and 1.x still wants the MinIO
  variables. The first build of this release dropped them and the drill failed
  on a contract change that is intentional and documented, which is exactly how
  that check stops being worth having. They are written now, and it is the
  faithful thing to do besides: nobody deletes variables from `.env` the moment
  a service goes away.
- **`FILE_STORAGE` is now set explicitly to `s3`.** It was never set, and the
  stack was right anyway — the image's compiled default when the variable is
  absent is `s3`. But upstream's own `.env.sample` shows `FILE_STORAGE=local`,
  so the template looked wrong while being correct, and a future change to that
  default would have moved every attachment into a directory inside the
  container without saying anything.
- **`AWS_S3_UPLOAD_MAX_SIZE` is deprecated upstream** and logged a warning on
  every start. It is `FILE_STORAGE_UPLOAD_MAX_SIZE` now. The `.env` key is
  unchanged, so nobody has to edit a file to stop seeing it.

## [1.6.2] - 2026-09-10

### Changed

- **`outlinewiki/outline:1.10.0` moved to `outlinewiki/outline:1.10.1`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

## [1.6.1] - 2026-09-07

### Changed

- **`update.sh` names any new required variable before it moves.** An update can add a required variable; `docker compose up` used to stop on it after the checkout, with the tree already on the new tag. The script now lists the variables that appeared in `.env.example` since your version and refuses, before anything has moved, when a required one is not in your `.env`. Names only, never values.


  `docker stop ""` and `docker exec ""`. Restoring the Keycloak database from a
  backup never worked. All three restore scripts now resolve containers through
  `docker compose ps -q` and stop with a clear message when a service is not
  running.
- **`update.sh` deployed a second copy of the stack instead of updating it.**
  Its project name defaulted to `outline-keycloak` while the README, CI and the
  restore scripts all use `outline`. On the cron schedule the README suggests,
  the nightly run would have brought up a parallel set of containers, fought the
  first set for ports, and left the original stack on the old images.

### Added

- **`tests/e2e-backup-restore.sh`**, run by CI on every push. It proves what the
  three restore scripts claim, against the live stack: both backup loops produce
  a readable PostgreSQL dump, the application data archive lists without error,
  a database outage is reported as `FAILED` and keeps the partial file, a
 restore of each database replaces state (a row inserted after the
  backup is gone afterwards), and pruning removes an aged file while keeping the
  recent ones.

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

### Changed

- `outlinewiki/outline` 1.9.2 to 1.10.0.

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
  build to the latest Docker Hub release, Redis 7.2 → 7.4**,
  **PostgreSQL 14 → 16** for both databases (14 reaches end-of-life in
  November 2026: existing deployments need a dump/restore migration, see
  the release notes), Traefik 3.2 → 3.7 (3.2's Docker client cannot
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

[Unreleased]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/releases/tag/v2.0.1
[1.6.2]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/outline-keycloak-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
