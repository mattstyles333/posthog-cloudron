-- Schema the hobby migrations miss, applied by bin/init.sh after PostHog's own migrations.
-- Every statement is idempotent.
--
-- The node ingestion service upserts persons with ON CONFLICT (team_id, uuid). In production the
-- Rust persons migrations create posthog_person_new_uuid_idx on the partitioned table; the hobby
-- layout keeps persons in the main table and skips those migrations, so without this index every
-- new person fails the upsert and no event reaches ClickHouse.
--
-- Carried over from ~/code/posthog-selfhost/fixups.sql, where it was found the hard way.
CREATE UNIQUE INDEX IF NOT EXISTS posthog_person_team_id_uuid_uniq ON posthog_person (team_id, uuid);
