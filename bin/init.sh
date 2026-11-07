#!/bin/bash
# One-shot start-up work, run by supervisord before the PostHog services.
#
# Order matters:
#   1. wait for the infrastructure (Cloudron addons, ClickHouse, Redpanda, SeaweedFS)
#   2. create the objects PostHog expects but does not create itself: the cyclotron schema,
#      the Kafka topics, the S3 credentials and the bucket
#   3. run PostHog's own migrations (Postgres, persons, ClickHouse, async migrations)
#   4. the persons fix-up index and the vendored cyclotron migrations
#   5. the Hog function templates the transformations and destinations UI needs
#   6. touch /run/posthog/initialized, which releases the services (bin/svc.sh)
#
# Every step is idempotent, so a restart repeats them as no-ops.

set -eu -o pipefail

APP_DIR=/app/code
RUN_DIR=/run/posthog

# shellcheck disable=SC1091
source "${RUN_DIR}/env.sh"

log() { printf '==> [init] %s\n' "$*"; }

WAIT_SECS=${WAIT_SECS:-600}

wait_tcp() {
    local host=$1 port=$2 what=$3 elapsed=0
    until (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; do
        if (( elapsed >= WAIT_SECS )); then
            log "timed out waiting for ${what} at ${host}:${port}"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log "${what} is up"
}

wait_http() {
    local url=$1 what=$2 elapsed=0
    until curl -fsS -o /dev/null --max-time 3 "${url}" 2>/dev/null; do
        if (( elapsed >= WAIT_SECS )); then
            log "timed out waiting for ${what} at ${url}"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log "${what} is up"
}

wait_clickhouse() {
    local elapsed=0
    until curl -fsS --max-time 3 http://127.0.0.1:8123/ping 2>/dev/null | grep -q Ok; do
        if (( elapsed >= WAIT_SECS )); then
            log "timed out waiting for ClickHouse"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log "ClickHouse is up"
}

# A service about to start must never see the previous boot's "initialized" marker.
rm -f "${RUN_DIR}/initialized"

# --- 1. Infrastructure ---------------------------------------------------------------------------
wait_tcp "${PGHOST}" "${PGPORT}" "PostgreSQL"
wait_clickhouse
wait_tcp 127.0.0.1 9092 "Redpanda"
wait_http http://127.0.0.1:19001/cluster/status "SeaweedFS master"

# --- 2. Objects PostHog does not create itself ----------------------------------------------------
log "cyclotron schema"
python3 "${APP_DIR}/bin/apply-sql.py" --schema cyclotron

log "Kafka topics"
# The broker accepts Kafka connections before its cluster is healthy. Creating topics in that window
# leaves them without a leader ("UNKNOWN_TOPIC_OR_PARTITION" on every produce), so wait for health.
for _ in $(seq 1 120); do
    rpk cluster health 2>/dev/null | grep -q "Healthy:  *true" && break
    sleep 2
done
existing=$(rpk topic list --brokers 127.0.0.1:9092 2>/dev/null | awk 'NR>1 {print $1}')
while IFS= read -r topic; do
    [[ -z "${topic}" ]] && continue
    if grep -qx "${topic}" <<<"${existing}"; then
        continue
    fi
    # An error here must not be swallowed: a topic created without partitions shows up in
    # "rpk topic list" but every produce to it fails with UNKNOWN_TOPIC_OR_PARTITION.
    if ! out=$(rpk topic create "${topic}" --brokers 127.0.0.1:9092 -p 1 -r 1 2>&1); then
        log "creating ${topic} failed: ${out}"
        [[ "${out}" == *ALREADY_EXISTS* ]] || exit 1
    fi
done < "${APP_DIR}/conf/topics.txt"
broken=$(rpk topic list --brokers 127.0.0.1:9092 2>/dev/null | awk 'NR>1 && $2 == 0 {print $1}')
[[ -z "${broken}" ]] || { log "topics with no partitions: ${broken}"; exit 1; }
log "$(wc -l < "${APP_DIR}/conf/topics.txt") topics ready"

log "object storage credentials and bucket"
for _ in $(seq 1 60); do
    {
        echo 's3.configure -access_key=object_storage_root_user -secret_key=object_storage_root_password -user=posthog -actions=Admin -apply'
        echo 's3.bucket.create -name posthog'
    } | /usr/bin/weed shell -master=127.0.0.1:19001 >/dev/null 2>&1 || true
    buckets=$(echo 's3.bucket.list' | /usr/bin/weed shell -master=127.0.0.1:19001 2>/dev/null || true)
    identities=$(echo 's3.configure' | /usr/bin/weed shell -master=127.0.0.1:19001 2>/dev/null || true)
    if grep -q posthog <<<"${buckets}" && grep -q object_storage_root_user <<<"${identities}"; then
        break
    fi
    sleep 2
done
log "object storage ready"

# The ClickHouse database itself: PostHog creates it with DDL ON CLUSTER, which is asynchronous, and
# then immediately connects to it (migrate_clickhouse.py). Creating it up front removes that race —
# without this the first run fails with "Database posthog does not exist".
log "ClickHouse database and system tables"
/usr/bin/clickhouse client --host 127.0.0.1 --query "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DATABASE}"
# system.crash_log is missing from both ClickHouse images we can pin; a migration view reads it.
/usr/bin/clickhouse client --host 127.0.0.1 --multiquery < "${APP_DIR}/conf/clickhouse/system-logs.sql"
# The executables that take RowBinary (funnels, Hog) read their schemas from format_schema_path;
# upstream's ClickHouse entrypoint copies the repo's IDL there for the same reason.
cp -r /code/posthog/idl/. /var/lib/posthog/clickhouse/format_schemas/ 2>/dev/null || true

# --- 3. PostHog migrations -------------------------------------------------------------------------
# ./bin/migrate is upstream's own orchestrator: Postgres (with retries), persons (hobby layout),
# ClickHouse (migrate_clickhouse + sync_replicated_schema) and the async migrations.
log "running PostHog migrations (first boot takes a while)"
cd /code
attempt=1
until ./bin/migrate; do
    if (( attempt >= 3 )); then
        log "migrations failed ${attempt} times"
        exit 1
    fi
    log "migrations failed, retrying (attempt $((attempt + 1))/3)"
    attempt=$((attempt + 1))
    sleep 15
done
log "migrations finished"

# --- 4. What the hobby migrations miss -------------------------------------------------------------
log "persons fix-up index"
python3 "${APP_DIR}/bin/apply-sql.py" --file "${APP_DIR}/conf/fixups.sql"

log "cyclotron migrations"
python3 "${APP_DIR}/bin/apply-sql.py" --migrations "${APP_DIR}/conf/cyclotron" _s4l_sql_migrations \
    --search-path cyclotron

# --- 5. Hog function templates ---------------------------------------------------------------------
# Inside web this would exceed web's memory limit, as upstream notes; a one-off process is cheap.
log "syncing Hog function templates"
python3 manage.py sync_hog_function_templates 2>&1 | tail -1 || log "template sync reported an error (non-fatal)"

touch "${RUN_DIR}/initialized"
log "ready: services may start"
