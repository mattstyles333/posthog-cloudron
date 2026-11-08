# PostHog on Cloudron — Community Package

**TL;DR:** PostHog (product analytics, web analytics, session replay, feature flags, surveys,
heatmaps, error tracking) packaged as a **single Cloudron app**. One container runs the whole stack —
the web app, the worker, the ingestion pipeline, ClickHouse, Kafka (Redpanda), object storage and a
reverse proxy — with PostgreSQL, Redis and mail from Cloudron's addons. Unofficial and
community-maintained; built and tested on **Cloudron 10.1.6**.

### Links

- Homepage / docs: https://posthog.com and https://posthog.com/docs/self-host
- Upstream: https://github.com/PostHog/posthog (MIT Expat, except its `ee/` directory)
- Cloudron package: https://github.com/mattstyles333/posthog-cloudron

### Install

Community packages are not in the App Store. Add the version catalogue once:

1. **App Store → Add custom app → Community app**, paste
   `https://raw.githubusercontent.com/mattstyles333/posthog-cloudron/main/CloudronVersions.json`,
   install, pick a location.
2. Or from the CLI:

   ```sh
   cloudron install \
     --versions-url https://raw.githubusercontent.com/mattstyles333/posthog-cloudron/main/CloudronVersions.json \
     --location posthog
   ```

Updates then arrive through the same URL like any other app.

### Resources

- **12 GiB memory limit** (set at install; measured ~8 GiB used after ingest, ClickHouse itself ~1 GiB).
- **First boot ~28 minutes** on an empty database: the migrations run before the services start. The
  health check answers 200 from a few seconds in, so Cloudron does not time out the install.
- **Restarts and updates take ~7 minutes** until the app serves again (init re-runs; its migrations
  are no-ops). The health check stays 200 throughout.
- Disk: ClickHouse and replay blobs grow with usage; plan for a few GB and watch it.

### What is included

Analytics, web analytics, session replay, feature flags, surveys, heatmaps, error tracking and
transformations (GeoIP), i.e. PostHog's own "hobby" feature set. The container runs the web app
(granian), the Celery worker, the Node plugin-server services (CDP API, event ingestion, replay blob
ingestion, recording API), the Rust fast paths (`capture`, `replay-capture`, `feature-flags`,
`property-defs-rs`, PersonHog), ClickHouse with its built-in Keeper, Redpanda, SeaweedFS and Caddy.

**Not included** (upstream runs them as separate containers): Temporal and Elasticsearch, so data
warehouse syncs and batch exports are unavailable; `livestream`; `browserless` (heatmap screenshots);
`cymbal` (error-tracking symbolication); the logs/traces/AI capture services; and CDP destination
delivery (Hog function templates load, enabled destinations do not send).

### Backups, and the ClickHouse problem this package works around

Cloudron backs an app up by rsyncing its data folder. A live ClickHouse constantly creates and deletes
temporary merge directories, and if the syncer walks one as it disappears, the **whole server's backup
run aborts** — every app scheduled after it silently keeps the previous night's snapshot
([forum topic 15663](https://forum.cloudron.io/topic/15663/backup-task-crashes-when-a-clickhouse-app-deletes-a-temp-merge-dir-mid-snapshot),
reported for other ClickHouse packages too).

This package therefore keeps ClickHouse's data directory outside the backed-up folder (a manifest
`persistentDirs` entry) and writes a **logical `BACKUP DATABASE` dump** into the backup at backup time
via `backupCommand` — the same approach as the Langfuse community package.

The restore is deliberately not done in Cloudron's restore container: that container has no running
ClickHouse with the app's configuration. `restoreCommand` only notes which dump to load, and the app
loads it on its own boot — drop the database, `RESTORE DATABASE … FROM Disk('backups', …)`, verify,
with every step in the app log and in `/app/data/.last-restore.log`. A restored or cloned app with an
empty data directory takes the same path, so a fresh box recovers the analytics data from the backup.
**A restore therefore rolls the analytics back to the backup's point in time**, exactly like the
Postgres data: ClickHouse's `posthog` database is dropped and loaded from the dump, whether the app was
restored in place, cloned or started on a fresh box. Restores are also visible: if one fails, the
marker stays and the boot stops instead of starting on an empty database.

### Known limitations

- No Cloudron SSO: PostHog's OIDC/SAML is an enterprise feature. The first account to sign up at the
  app URL becomes the owner, and a self-hosted instance cannot create a second organisation.
- With the sendmail addon wired up, **sign-up emails a verification link** before login works. If mail
  is not set up on the box, `POSTINSTALL.md` gives a one-line Web Terminal command that marks the first
  account verified.
- One node: single ClickHouse replica, single Redpanda broker, no scaling story beyond a bigger app.
- Restarts re-run init (~7 minutes); plan updates for a quiet moment.

### Feedback

Issues and packaging questions: https://github.com/mattstyles333/posthog-cloudron/issues — or reply
here. PostHog's own self-hosted documentation applies to everything inside the app.
