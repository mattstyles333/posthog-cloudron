# posthog-cloudron

PostHog as a **single Cloudron app**: one container running the web app, the worker, the ingestion
pipeline, ClickHouse, Kafka, object storage and a reverse proxy, with PostgreSQL, Redis and mail
from Cloudron's addons.

Built for Cloudron 10.x. Unofficial, community-maintained, MIT (see `LICENSE`; PostHog itself is
MIT Expat except for its `ee/` directory).

- Upstream: [PostHog/posthog](https://github.com/PostHog/posthog), pinned to commit
  `233686435f9b9fd6b32c78303bd9480644d48aff` (2026-10-18) — the commit the author's standalone
  self-hosted stack runs.
- Every image is pinned **by digest**, never by `:master`; the digests are in the `Dockerfile`
  arguments and come from that stack's `compose.pins.yml`.

## Install on Cloudron

This is a community package, so it is not in the App Store. Add its version catalogue to the
dashboard once and Cloudron installs and updates it like any other app:

1. **App Store → Add custom app → Community app**, paste
   `https://raw.githubusercontent.com/mattstyles333/posthog-cloudron/main/CloudronVersions.json`,
   install, and assign the location (e.g. `posthog-cloudron.example.com`).
2. Or from the CLI:

   ```sh
   cloudron login my.example.com
   cloudron install \
     --versions-url https://raw.githubusercontent.com/mattstyles333/posthog-cloudron/main/CloudronVersions.json \
     --location posthog-cloudron
   ```

The manifest asks for 12 GiB of memory; if your box has more headroom, raise it in the app's
settings after install (`cloudron install --memory-limit 16G` also works). First boot takes about
half an hour (see [Known limitations](#known-limitations)); the health check answers immediately.

After it starts, open the app and sign up: the first account becomes the owner of the instance.

## Why one container

Cloudron runs one container per app, so PostHog's 30-plus-container hobby compose becomes one
image with supervisord in front. That has three consequences worth knowing:

1. **Ports.** Upstream gives every service its own container, so several bind the same port
   (`capture` and `replay-capture` both use 3000; every Node service hardcodes 6738). Here each one
   gets a port of its own behind the proxy, and `nodejs/dist/common/config.js` is patched at build
   time so the Node services' HTTP port can be set per process (the build fails if that line ever
   changes upstream).
2. **Memory.** Everything shares one 12 GiB limit, so each component is capped individually:
   ClickHouse at 8 GiB of tracked memory (it idles near 1.1 GiB) with its thread pools and caches
   sized for a small app, Redpanda at 1 GiB on one core, the Node services at 384 MB of heap, granian
   at two workers and Celery at two. Measured idle after ingest: see *Checks* below.
3. **Backups.** See [Backups](#backups-and-restores).

## What runs

| Process | Port (inside) | Notes |
|---|---|---|
| `caddy` | **8000** (the Cloudron httpPort) | the only published port; reproduces PostHog's hobby routing |
| `web` | 8010 | Django + granian, `GRANIAN_WORKERS=2` |
| `worker` | — | Celery with the scheduler, `WEB_CONCURRENCY=2` |
| `plugins` | 6738 | plugin-server in `cdp-api` mode (Hog function templates) |
| `ingestion-general` | 6741 | plugin-server `ingestion-v2-combined` |
| `ingestion-sessionreplay` | 6742 | plugin-server `recordings-blob-ingestion-v2` |
| `recording-api` | 6740 | plugin-server `recording-api` |
| `capture` | 3100 | Rust event capture (`/e`, `/i/v0/*`, `/batch`) |
| `replay-capture` | 3101 | Rust replay capture (`/s`) |
| `feature-flags` | 3001 | Rust flags, `/flags`, local evaluation |
| `property-defs-rs` | — | Kafka → Postgres |
| `personhog-replica` / `personhog-router` | 50051 / 50052 | required by the Node services at this pin |
| `clickhouse` | 9000/8123/9181 | with built-in Keeper (no ZooKeeper) |
| `redpanda` | 9092 | single node, 1 GiB |
| `seaweedfs` | 19000 | object storage (S3), data in `/app/data/objectstorage` |
| `init` | — | one-shot: topics, buckets, migrations, fixups |

**Not included** (upstream runs them as separate containers): Temporal and Elasticsearch (data
warehouse syncs, batch exports, some background workflows), `livestream`, `browserless`
(heatmap screenshots), `cymbal` (error-tracking symbolication), the logs/traces/AI capture
services, CDP destination delivery (cyclotron workers), and the hobby stack's second SeaweedFS.

## Cloudron addons

| Addon | Why | Notes |
|---|---|---|
| `postgresql` | the app database | PostHog declares `postgresql >= 14.0.0` (`posthog/settings/service_requirements.py`); the addon's PostgreSQL 14.x satisfies it. Migrations 0308 and 0463 create the `intarray` and `ltree` extensions, both trusted since PostgreSQL 13, so the database owner can create them without superuser rights. **Threading note:** the addon gives one database, so the CDP API's cyclotron tables live in a `cyclotron` schema of it (schema created by `bin/init.sh`, connection carries `?options=-csearch_path=cyclotron`). |
| `redis` | caches, flags, replay | `noPassword: true` because several Node services take a host/port pair, not a URL; `maxmemoryPolicy: allkeys-lru`. Cloudron ships Redis 8; PostHog's declared range is `>=7,<8`, which is a *declaration* — the only runtime check at this pin is for ClickHouse, so Redis 8 is used. |
| `sendmail` | invitations, alerts | mapped to Django's `EMAIL_*` settings on every boot |

## First boot and the health check

`start.sh` generates `/app/data/env.sh` once (PostHog secret, encryption salts, ClickHouse
passwords), rebuilds `/run/posthog/env.sh` from the Cloudron environment on **every** start, and
hands over to supervisord. `bin/init.sh` then:

1. waits for the addons, ClickHouse, Redpanda and SeaweedFS,
2. creates the `cyclotron` schema, the Kafka topics (`conf/topics.txt`, upstream's list) and the S3
   credentials and bucket,
3. runs upstream's own `./bin/migrate` (Postgres with retries, persons in the hobby layout,
   `migrate_clickhouse`, `sync_replicated_schema`, async migrations),
4. applies the persons fix-up index and the vendored cyclotron migrations,
5. syncs the Hog function templates, and only then touches `/run/posthog/initialized`, which is
   what the other services wait for (`bin/svc.sh`).

The manifest's `healthCheckPath` is `/_cloudron_health`, answered by Caddy itself. It returns 200
seconds after the container starts, long before migrations finish, so Cloudron does not mark the
install failed during the first (long) migration run — and it keeps answering during a restart.

Both the fix-up index and the cyclotron schema are carried over from the standalone stack
(`~/code/posthog-selfhost`), where the missing unique index meant *no event ever reached
ClickHouse* because every person upsert failed.

## Backups and restores

ClickHouse's data directory is a Cloudron **`persistentDirs`** entry, not part of `/app/data`.
Cloudron's rsync backup walks the app's data tree; a live ClickHouse deletes its temporary merge
directories while that walk is in progress, the syncer then throws on a vanished directory and
**the whole server's backup run aborts**, silently leaving every later app on the previous night's
snapshot (Cloudron forum topics
[15652](https://forum.cloudron.io/topic/15652/langfuse-on-cloudron-community-package) and
[15663](https://forum.cloudron.io/topic/15663/backup-task-crashes-when-a-clickhouse-app-deletes-a-temp-merge-dir-mid-snapshot)).
This is the workaround the Langfuse community package uses, adopted here: the churny store lives
outside the rsync path, and a logical dump is written into the backup instead.

- `backupCommand` (`bin/backup.sh`) runs in a temporary container that shares the app's network
  namespace, and runs `BACKUP DATABASE posthog TO Disk('backups', 'posthog-<stamp>.zip')` through
  the live server. Dumps land in `/app/data/clickhouse-backup/` and the newest two are kept.
- PostgreSQL is the Cloudron addon's database: Cloudron backs it up itself.
- Replay blobs and exports live in `/app/data/objectstorage` and are backed up by Cloudron's normal
  file backup.
- Kafka's data (`/var/lib/posthog/redpanda`) is a `persistentDirs` entry and is **not** backed up:
  it only ever holds un-consumed events.
- `restoreCommand` (`bin/restore.sh`) restores the newest dump **only into an empty ClickHouse
  store**, through a temporary `clickhouse-server` (never `clickhouse local`, which produces a
  store the server then refuses: Code 48).

All three manifest fields this relies on are real on 10.x, and Cloudron documents exactly the
semantics used here (https://docs.cloudron.io/packaging/manifest/):

- **`persistentDirs`** — "directories that store persistent data which should not be included in
  backups directly. Unlike `runtimeDirs`, these directories survive container updates. Unlike
  `/app/data`, they are not backed up as part of the filesystem backup. Instead, use
  `backupCommand` to create a portable logical dump of their contents into `/app/data`, and
  `restoreCommand` to import that dump during restore." (Requires `minBoxVersion` ≥ 9.1.0; paths
  must not overlap `/app/data`, `/tmp` or `/run`.)
- **`backupCommand`** — "executed via `docker run` using the app's image in a temporary container
  while the app is running. The temporary container **shares the app container's network
  namespace** … It has access to `/app/data` and any `persistentDirs` bind mounts. The command
  should produce a logical dump from the persistent data into `/app/data` so that it gets included
  in the backup."
- **`restoreCommand`** — "executed via `docker run` … **before the main app container starts**. The
  app is not running at this point, so the command cannot connect to services on localhost inside
  the app. … Typically this means starting the database temporarily in the restore container,
  importing the dump, and shutting it down before the main app container is created."

Consequence, same as Langfuse's: an **in-place restore** brings back the files and the addon
database but keeps the live analytics data. Clone the app instead if you want a point-in-time copy
of everything.

## Upgrading

Upgrades are a digest bump plus a fresh image:

1. pick the new upstream commit and the image digests its `docker-compose.hobby.yml` resolves to
   (the standalone stack generates them with `pin_images.py`),
2. update the `ARG` digests at the top of the `Dockerfile` and `upstreamVersion` /
   `version` in `CloudronManifest.json`,
3. add a `CHANGELOG` entry,
4. run `scripts/smoke.sh` against the new image (below),
5. re-check the two upstream assumptions that make this package work:
   `grep -c 'process.env.HTTP_SERVER_PORT'` in the build output (the Node port patch) and that
   `conf/topics.txt` still matches `docker/kafka/topics.txt` at the new commit.

ClickHouse data survives the upgrade as long as the ClickHouse image's data format stays
compatible; take a backup first (Cloudron does that automatically on update).

## Building and testing

```sh
docker build -t posthog-cloudron:dev .
scripts/smoke.sh posthog-cloudron:dev
```

`scripts/smoke.sh` runs the image the way Cloudron does — `--read-only`, tmpfs on `/tmp` and
`/run`, volumes for `/app/data` and the persistentDirs, `--memory 12g`, and `CLOUDRON_*` variables
pointing at throwaway PostgreSQL (14, the addon's major version) and Redis containers on a private
network — and asserts:

1. `/_cloudron_health` answers 200 while the first-boot migrations are still running,
2. the first sign-up through `/api/signup` succeeds,
3. an event posted to `/e/` shows up in ClickHouse within two minutes,
4. `/flags` answers for the project key,
5. the stack idles under 10 GiB,
6. a restart on the same volumes comes back healthy, with the user and the event still there and
   the migrations a no-op.

Everything it creates is removed afterwards; the image is kept.

## Checks (0.1.0)

`scripts/smoke.sh posthog-cloudron:smoke` on a fresh set of volumes, on the machine the package was
developed on (96 cores, 62 GiB RAM, ClickHouse and Redpanda in 1-core/1 GiB configurations):

| | |
|---|---|
| health check during the first migration | **200 after 5 s** (the app itself answered 502 until 1695 s) |
| first boot: migrations finished, app serving | **1695 s** (28 min) — Postgres, persons, ClickHouse and async migrations on an empty database |
| sign-up of the first user (`POST /api/signup`) | **201** |
| event posted to `/e/`, one row in ClickHouse | **1 row** (within the 2-minute poll) |
| `POST /flags/?v=2` for the project key | **200** |
| idle memory after ingest (cgroup `memory.current`) | **7.96 GiB** of the 12 GiB limit (ClickHouse itself ≈1.1 GiB) |
| restart on the same volumes: health, then app serving | **5 s**, then **415 s** (the one-shot init re-runs; its migrations are no-ops) |
| user and event after the restart | still there (login **200**, **1 row**) |
| image | 12.1 GB |

Nothing in the run needed a retry. The image size is not a goal: it carries PostHog's 8.15 GB app
image, the Node plugin server with its pnpm store, ClickHouse, Redpanda, SeaweedFS and Caddy.

## Known limitations

**Restarts and updates re-run init.** Every boot runs the one-shot init again: it waits for the
services, re-creates topics and the S3 bucket, then re-runs PostHog's migrations, which are no-ops on
an existing install (measured: the app answers its health check 5 s after a restart and serves again
after **~7 minutes**). Cloudron keeps the app "healthy" throughout because the health check is a
static endpoint on the proxy, but nothing is useful until init finishes. The same step runs after an
update, so plan updates for a quiet moment.

**The first boot takes ~28 minutes.** On an empty database, Postgres, persons, ClickHouse and async
migrations took 1695 s in the smoke run; the app's health check answers 200 from the first seconds.

**Backups.** ClickHouse's data directory is a `persistentDirs` entry, outside `/app/data`, because its
merge churn aborts Cloudron's rsync backup for every app after it. `backupCommand` writes a
`BACKUP DATABASE` dump into `/app/data/clickhouse-backup/` at backup time and `restoreCommand` restores
it only into an empty store — so an in-place restore keeps the live analytics data; clone the app for a
point-in-time copy. Replay blobs live in `/app/data/objectstorage` and are backed up as files.

**One node, one process tree.** ClickHouse runs a single replica, Redpanda a single node; an update
restarts all of it at once. There is no way to scale beyond a bigger app.

**Not included** (see above): Temporal/Elasticsearch (data warehouse syncs, batch exports),
`livestream`, `browserless` (heatmap screenshots), `cymbal` (error-tracking symbolication), the
logs/traces/AI capture services, CDP destination delivery.

## Limits worth knowing

- **No Cloudron SSO.** PostHog's OIDC/SAML is an enterprise feature; the first sign-up at the app
  URL is the owner, and a self-hosted instance cannot create a second organisation.
- **No Temporal/Elasticsearch**: data-warehouse syncs, batch exports and a few background
  workflows are unavailable; the UI hides what it can.
- **No CDP delivery**: Hog function templates load and the Data pipelines UI works, but enabled
  destinations do not send (no cyclotron workers).
- **Surveys** fall through to the Django app rather than hypercache-server; basic survey display
  works, remote config (`/array/*`) is served by Django.
- **One node.** ClickHouse runs a single replica; there is no scaling story beyond a bigger app.
- **Upgrades are pinned.** Nothing tracks upstream automatically.

## Layout

```
CloudronManifest.json   package manifest (addons, health check, memory, persistentDirs, backup/restore)
Dockerfile              multi-stage: the pinned app image + node, rust, clickhouse, redpanda, weed, caddy
start.sh                Cloudron entrypoint: secrets once, environment every boot, then supervisord
supervisord.conf        every process, in dependency order
caddy/Caddyfile         the single published port and PostHog's routing
conf/                   ClickHouse config.d, Redpanda config, Kafka topics, fixup SQL, cyclotron SQL,
                        the per-service environment
bin/                    init.sh (migrations), svc.sh (wait for init, then exec), apply-sql.py,
                        backup.sh / restore.sh (Cloudron backupCommand / restoreCommand)
scripts/smoke.sh        the end-to-end check described above
```
