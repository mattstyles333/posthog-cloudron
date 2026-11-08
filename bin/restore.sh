#!/bin/bash
# Cloudron runs backupCommand/restoreCommand as `/bin/sh -c '<script>'`, which ignores the shebang; the
# bashisms below would fail under dash. Re-exec ourselves under bash when that happens.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
# Cloudron restoreCommand.
#
# This does not restore anything itself. Cloudron runs it in a bare container, before the app starts,
# where ClickHouse is not running and its full configuration (Keeper, clusters, the backups disk) is
# not the one the server uses. Restoring a database there is fragile and hard to see.
#
# Instead it records which dump to load, and bin/init.sh performs the restore on the app's own boot,
# with the real server: drop the database if present, RESTORE from the disk, verify, log. The marker
# also covers the disaster case — a restored or cloned app with an empty persistentDir, where the
# app starts fresh and init finds the marker.

set -euo pipefail

DUMP_DIR=/app/data/clickhouse-backup
MARKER="${DUMP_DIR}/RESTORE_PENDING"
STATUS_LOG=/app/data/.last-restore.log

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STATUS_LOG}"; }

LATEST=$(ls -1t "${DUMP_DIR}"/posthog-*.zip 2>/dev/null | head -1 || true)
if [[ -z "${LATEST}" ]]; then
    echo "==> [restore] no ClickHouse dump in ${DUMP_DIR}; nothing queued"
    log "no dump present, nothing queued"
    exit 0
fi

mkdir -p "${DUMP_DIR}"
basename "${LATEST}" > "${MARKER}"
echo "==> [restore] queued $(basename "${LATEST}") for the app's own boot"
log "queued $(basename "${LATEST}")"
exit 0
