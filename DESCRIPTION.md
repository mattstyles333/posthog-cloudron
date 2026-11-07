PostHog, packaged as a single Cloudron app: product analytics, web analytics, session replay,
feature flags, surveys, heatmaps, error tracking and data transformations, on one container.

**What this package runs** (all inside the app container):

- PostHog web (Django, granian) and the Celery worker with its scheduler
- the Node plugin-server services: the CDP API that serves Hog function templates, event
  ingestion, session-replay blob ingestion, and the recording API
- the Rust fast path: `capture`, `replay-capture`, `feature-flags`, `property-defs-rs`,
  `personhog-replica` and `personhog-router`
- ClickHouse (with its built-in Keeper instead of ZooKeeper), Redpanda (Kafka), SeaweedFS
  (object storage) and Caddy as the single internal reverse proxy

PostgreSQL, Redis and mail come from the Cloudron addons. Everything is pinned to PostHog commit
`233686435f9b` and by image digest.

**Not included in 0.1.0** (upstream runs these as extra containers): Temporal and Elasticsearch
(workflows such as data warehouse syncs and batch exports), `livestream` (the live event feed),
`browserless` (heatmap screenshots), `cymbal` (error-tracking symbolication), the logs/traces/AI
capture services, CDP destination delivery (the cyclotron workers), and Apache Superset/embedded
dashboards.

**Signing in:** there is no Cloudron SSO. Self-hosted PostHog's OIDC support is a paid feature, so
the first account you create at the app's URL is the instance owner. A self-hosted instance cannot
create a second organisation, so use that account for everything.
