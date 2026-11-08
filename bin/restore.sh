#!/bin/bash
# Cloudron runs backupCommand/restoreCommand as `/bin/sh -c '<script>'`, which ignores the shebang; the
# bashisms below would fail under dash. Re-exec ourselves under bash when that happens.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
# Cloudron restoreCommand.
#
# Runs in a temporary container before the app starts, on a restore or a clone. Restores the
# ClickHouse database from the newest dump bin/backup.sh left in /app/data.
#
# Idempotent and conservative: it only acts when the ClickHouse data directory has no database
# yet. An in-place restore therefore keeps the live analytics data (Cloudron's own note: restore
# brings back the files and the addon database; clone to get a point-in-time copy of everything).
#
# The restore goes through a real clickhouse-server, never `clickhouse local`: a local RESTORE
# omits the implicit default-database metadata and the Atomic-UUID layout, and the server then
# crash-loops with Code 48 (Cloudron forum topic 15652 records that footgun).

set -uo pipefail

DUMP_DIR=/app/data/clickhouse-backup
STATUS_LOG=/app/data/.last-backup.log
STORE=/var/lib/posthog/clickhouse/data

status() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STATUS_LOG}"; }
log() { echo "==> [restore] $*"; }

LATEST=$(ls -1t "${DUMP_DIR}"/posthog-*.zip 2>/dev/null | head -1 || true)
if [[ -z "${LATEST}" ]]; then
    log "no ClickHouse dump in ${DUMP_DIR}; nothing to restore"
    exit 0
fi

if [[ -d "${STORE}/store" || -d "${STORE}/metadata" ]]; then
    log "ClickHouse already has data; leaving it alone (restore only fills an empty store)"
    exit 0
fi

log "starting a temporary ClickHouse server to restore $(basename "${LATEST}")"
/usr/bin/clickhouse server --config-file=/etc/clickhouse-server/config.xml >/tmp/restore-clickhouse.log 2>&1 &
SERVER_PID=$!
trap 'kill ${SERVER_PID} 2>/dev/null' EXIT

for _ in $(seq 1 60); do
    /usr/bin/clickhouse client --host 127.0.0.1 --query "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
done
if ! /usr/bin/clickhouse client --host 127.0.0.1 --query "SELECT 1" >/dev/null 2>&1; then
    log "the temporary server did not come up; see /tmp/restore-clickhouse.log"
    status "FAILED: restore server did not start"
    exit 1
fi

if /usr/bin/clickhouse client --host 127.0.0.1 --query \
    "RESTORE DATABASE posthog FROM Disk('backups', '$(basename "${LATEST}")')" 2>&1 | tail -3; then
    log "restored $(basename "${LATEST}")"
    status "ok: restored $(basename "${LATEST}")"
else
    log "RESTORE failed; see /tmp/restore-clickhouse.log"
    status "FAILED: RESTORE failed"
    exit 1
fi

kill "${SERVER_PID}" 2>/dev/null || true
exit 0
