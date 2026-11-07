-- ClickHouse's crash log table, created up front.
--
-- PostHog's ClickHouse migrations end by (re)creating a set of custom-metric views, one of which
-- reads system.crash_log. That table is defined in the server config of both the stock
-- clickhouse-server image and PostHog's fork, but neither actually creates it at startup in the
-- versions we pin (26.6 stock, 26.9 fork), so the migration fails with
-- "Code: 60. Unknown table expression identifier 'system.crash_log'" and the first boot never
-- finishes.
--
-- Creating it here (idempotent, same column set ClickHouse uses for CrashLogElement) lets the
-- migration succeed. The server only writes to it when it crashes.
CREATE TABLE IF NOT EXISTS system.crash_log
(
    hostname String,
    event_date Date,
    event_time DateTime,
    event_time_microseconds DateTime64(6),
    timestamp_ns UInt64,
    signal Int32,
    thread_id UInt64,
    query_id String,
    trace String,
    trace_full String,
    version String,
    revision String
)
ENGINE = MergeTree
PARTITION BY event_date
ORDER BY event_time;
