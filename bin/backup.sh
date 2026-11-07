#!/bin/bash
# Cloudron backupCommand.
#
# Cloudron runs this in a temporary container of this image that shares the app's network
# namespace and mounts /app/data and the persistentDirs. The app keeps running, so the dump has to
# be a logical one taken through the running server (a filesystem snapshot of ClickHouse is not
# consistent while it merges).
#
# What is dumped here: the ClickHouse database. Postgres lives in the Cloudron addon, which
# Cloudron backs up itself; the object storage (replay blobs, exports) is under /app/data and is
# copied by Cloudron's own file backup.
#
# The ClickHouse data directory is a persistentDir rather than a part of /app/data on purpose:
# Cloudron's rsync backup aborts on the temporary directories a live ClickHouse deletes mid-walk
# (Cloudron forum topic 15663), which would break the backup of every app after this one.

set -uo pipefail

DUMP_DIR=/app/data/clickhouse-backup
STATUS_LOG=/app/data/.last-backup.log
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CH_CLIENT="/usr/bin/clickhouse client --host 127.0.0.1 --query"

mkdir -p "${DUMP_DIR}"
status() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STATUS_LOG}"; }
log() { echo "==> [backup] $*"; }

# No ClickHouse data yet (fresh install, or a failed first boot): nothing to dump.
if ! /usr/bin/clickhouse client --host 127.0.0.1 --query "SELECT 1" >/dev/null 2>&1; then
    log "ClickHouse is not reachable; nothing dumped"
    status "skipped: ClickHouse not reachable"
    exit 0
fi

NAME="posthog-${STAMP}.zip"
log "BACKUP DATABASE posthog TO ${NAME}"
if ${CH_CLIENT} "BACKUP DATABASE posthog TO Disk('backups', '${NAME}')" 2>&1 | tail -3; then
    status "ok: ${NAME} ($(du -h "${DUMP_DIR}/${NAME}" 2>/dev/null | cut -f1))"
    # Keep the last two dumps: one to restore from, one in case the newest is being written.
    ls -1t "${DUMP_DIR}"/posthog-*.zip 2>/dev/null | tail -n +3 | while read -r old; do
        rm -f "${old}"
    done
    log "done"
    exit 0
fi

log "ClickHouse BACKUP failed"
status "FAILED: ClickHouse BACKUP failed"
exit 1
