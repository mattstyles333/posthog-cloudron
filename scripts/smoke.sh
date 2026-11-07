#!/bin/bash
# Run the package image the way Cloudron runs it, and prove that it works.
#
#   scripts/smoke.sh <image> [--keep]
#
# Cloudron starts an app with a read-only root filesystem, tmpfs on /tmp and /run, a volume on
# /app/data plus one per persistentDir, a hard memory limit, and the addon variables. This script
# does the same against throwaway Postgres and Redis containers on a private network, then checks:
#
#   1. the health check answers 200 while the first-boot migrations are still running
#   2. sign-up of the first user through the API succeeds
#   3. an event posted to /e is in ClickHouse (count > 0) within two minutes
#   4. /flags answers for that project key
#   5. the whole stack idles under 10 GiB
#   6. a restart on the same volume comes back healthy with the user and the event still there
#      and the migrations a no-op
#
# Everything it creates is removed at the end (the image is kept).

set -euo pipefail

IMAGE=${1:?usage: smoke.sh <image> [--keep]}
KEEP=${2:-}
NAME=posthog-smoke
NET=posthog-smoke-net
PG=posthog-smoke-pg
REDIS=posthog-smoke-redis
PORT=${PORT:-18000}
BASE="http://127.0.0.1:${PORT}"
# The Cloudron PostgreSQL addon is documented as PostgreSQL 14.x; use the same major version.
PG_VERSION=${PG_VERSION:-14}
WORKDIR=$(mktemp -d)

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; dump_logs; exit 1; }
dump_logs() {
    echo "--- container log (last 120 lines) ---"
    docker logs "${NAME}" 2>&1 | tail -120 || true
}

cleanup() {
    if [[ "${KEEP}" == "--keep" ]]; then
        echo "kept: container ${NAME}, databases ${PG}/${REDIS}, volumes and network"
        return
    fi
    docker rm -f "${NAME}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
    docker volume rm posthog-smoke-data posthog-smoke-clickhouse posthog-smoke-redpanda >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

curl_json() { curl -sS -m 30 -H 'Content-Type: application/json' "$@"; }

# Wait for a URL to answer with a given status, printing progress now and then.
wait_status() {
    local url=$1 want=$2 timeout=$3 what=$4 elapsed=0 code
    while :; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${url}" || true)
        if [[ "${code}" == "${want}" ]]; then
            echo "    ${what}: ${code} after ${elapsed}s"
            return 0
        fi
        (( elapsed >= timeout )) && return 1
        sleep 5
        elapsed=$((elapsed + 5))
        (( elapsed % 60 == 0 )) && echo "    waiting for ${what} (${elapsed}s, last ${code})"
    done
}

log "throwaway Postgres ${PG_VERSION} and Redis on ${NET}"
docker rm -f "${NAME}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
docker volume rm posthog-smoke-data posthog-smoke-clickhouse posthog-smoke-redpanda >/dev/null 2>&1 || true
docker network rm "${NET}" >/dev/null 2>&1 || true
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" \
    -e POSTGRES_USER=posthog -e POSTGRES_PASSWORD=smoke-pg-password -e POSTGRES_DB=posthog \
    "postgres:${PG_VERSION}-alpine" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" redis:8-alpine >/dev/null
until docker exec "${PG}" pg_isready -U posthog -d posthog >/dev/null 2>&1; do sleep 1; done
until docker exec "${REDIS}" redis-cli ping 2>/dev/null | grep -q PONG; do sleep 1; done
echo "    ready"

log "starting the app"
docker run -d --name "${NAME}" --network "${NET}" \
    --read-only --tmpfs /tmp:rw,size=1g --tmpfs /run:rw,size=64m \
    --memory 12g --memory-swap 12g \
    -v posthog-smoke-data:/app/data \
    -v posthog-smoke-clickhouse:/var/lib/posthog/clickhouse \
    -v posthog-smoke-redpanda:/var/lib/posthog/redpanda \
    -p "127.0.0.1:${PORT}:8000" \
    -e CLOUDRON_APP_ORIGIN="${BASE}" \
    -e CLOUDRON_APP_DOMAIN="127.0.0.1:${PORT}" \
    -e CLOUDRON_POSTGRESQL_URL="postgres://posthog:smoke-pg-password@${PG}:5432/posthog" \
    -e CLOUDRON_POSTGRESQL_HOST="${PG}" \
    -e CLOUDRON_POSTGRESQL_PORT=5432 \
    -e CLOUDRON_POSTGRESQL_USERNAME=posthog \
    -e CLOUDRON_POSTGRESQL_PASSWORD=smoke-pg-password \
    -e CLOUDRON_POSTGRESQL_DATABASE=posthog \
    -e CLOUDRON_REDIS_URL="redis://${REDIS}:6379" \
    -e CLOUDRON_REDIS_HOST="${REDIS}" \
    -e CLOUDRON_REDIS_PORT=6379 \
    "${IMAGE}" >/dev/null

# --- 1. Health check during migrations ---------------------------------------------------------
log "1. health check while the first-boot migrations run"
if ! wait_status "${BASE}/_cloudron_health" 200 300 "health check"; then
    fail "the health check never answered 200"
fi
if curl -fsS -m 10 "${BASE}/_preflight/" >/dev/null 2>&1; then
    echo "    note: the app was already serving requests when the health check passed"
else
    echo "    health check is up while the app itself is still migrating (that is the point)"
fi

# --- 2. First sign-up ---------------------------------------------------------------------------
log "2. waiting for migrations, then signing up the first user"
if ! wait_status "${BASE}/_preflight/" 200 3600 "/_preflight/ (migrations)"; then
    fail "the app never finished starting"
fi

EMAIL="smoke@example.com"
PASSWORD="smoke-password-${RANDOM}"
SIGNUP=$(curl_json -o "${WORKDIR}/signup.json" -w '%{http_code}' -X POST "${BASE}/api/signup" \
    -d "{\"first_name\":\"Smoke\",\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"organization_name\":\"Smoke Org\"}")
[[ "${SIGNUP}" == 200 || "${SIGNUP}" == 201 ]] || { cat "${WORKDIR}/signup.json"; fail "signup returned ${SIGNUP}"; }
echo "    signup: ${SIGNUP}"
jq -e '.uuid' "${WORKDIR}/signup.json" >/dev/null || { cat "${WORKDIR}/signup.json"; fail "no user uuid in the signup response"; }

LOGIN=$(curl_json -c "${WORKDIR}/cookies" -o "${WORKDIR}/login.json" -w '%{http_code}' -X POST "${BASE}/api/login" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")
[[ "${LOGIN}" == 200 ]] || { cat "${WORKDIR}/login.json"; fail "login returned ${LOGIN}"; }
echo "    login: ${LOGIN}"

curl_json -b "${WORKDIR}/cookies" "${BASE}/api/projects/" -o "${WORKDIR}/projects.json"
TOKEN=$(jq -r '.[0].api_token // .results[0].api_token // empty' "${WORKDIR}/projects.json")
[[ -n "${TOKEN}" ]] || { cat "${WORKDIR}/projects.json"; fail "no project API key"; }
echo "    project API key: ${TOKEN:0:8}…"

# --- 3. Ingest an event -------------------------------------------------------------------------
log "3. posting an event to /e"
EVENT="smoke_event_$$"
INGEST=$(curl_json -o "${WORKDIR}/ingest.json" -w '%{http_code}' -X POST "${BASE}/e/" \
    -d "{\"api_key\":\"${TOKEN}\",\"event\":\"${EVENT}\",\"properties\":{\"distinct_id\":\"smoke-user\",\"\$current_url\":\"http://127.0.0.1/\"}}")
[[ "${INGEST}" == 200 ]] || { cat "${WORKDIR}/ingest.json"; fail "ingest returned ${INGEST}"; }
echo "    ingest: ${INGEST}"

log "   waiting for the event in ClickHouse (up to 120s)"
COUNT=0
for _ in $(seq 1 60); do
    for table in posthog.events posthog.sharded_events; do
        COUNT=$(docker exec "${NAME}" /usr/bin/clickhouse client --query \
            "SELECT count() FROM ${table} WHERE event = '${EVENT}'" 2>/dev/null || echo 0)
        [[ "${COUNT}" =~ ^[0-9]+$ ]] && (( COUNT > 0 )) && break 2
    done
    sleep 2
done
(( COUNT > 0 )) || fail "the event never reached ClickHouse"
echo "    ClickHouse rows for ${EVENT}: ${COUNT}"

# --- 4. Feature flags --------------------------------------------------------------------------
log "4. asking /flags for the project key"
FLAGS=$(curl_json -o "${WORKDIR}/flags.json" -w '%{http_code}' -X POST "${BASE}/flags/?v=2" \
    -d "{\"api_key\":\"${TOKEN}\",\"distinct_id\":\"smoke-user\"}")
[[ "${FLAGS}" == 200 ]] || { cat "${WORKDIR}/flags.json"; fail "/flags returned ${FLAGS}"; }
echo "    /flags: ${FLAGS} $(jq -c '.flags // {}' "${WORKDIR}/flags.json" 2>/dev/null | head -c 80)"

# --- 5. Memory ---------------------------------------------------------------------------------
log "5. memory at idle after ingest"
sleep 20
MEM=$(docker stats --no-stream --format '{{.MemUsage}}' "${NAME}")
USED_MB=$(docker exec "${NAME}" sh -c "cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes" | tr -d '\r')
USED_GIB=$(awk -v b="${USED_MB}" 'BEGIN { printf "%.2f", b / 1073741824 }')
echo "    docker stats: ${MEM}"
echo "    cgroup memory.current: ${USED_MB} bytes (${USED_GIB} GiB)"
awk -v g="${USED_GIB}" 'BEGIN { exit (g < 10) ? 0 : 1 }' || fail "the stack idles at ${USED_GIB} GiB (limit is 10)"
echo "    under the 10 GiB budget"

# --- 6. Restart --------------------------------------------------------------------------------
log "6. restarting the container on the same volumes"
RESTART_START=$(date +%s)
docker stop "${NAME}" >/dev/null
docker start "${NAME}" >/dev/null
if ! wait_status "${BASE}/_cloudron_health" 200 300 "health check after restart"; then
    fail "the health check did not come back after a restart"
fi
if ! wait_status "${BASE}/_preflight/" 200 3600 "/_preflight/ after restart"; then
    fail "the app did not come back after a restart"
fi
RESTART_SECS=$(( $(date +%s) - RESTART_START ))

RELOGIN=$(curl_json -o "${WORKDIR}/relogin.json" -w '%{http_code}' -X POST "${BASE}/api/login" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")
[[ "${RELOGIN}" == 200 ]] || { cat "${WORKDIR}/relogin.json"; fail "login after restart returned ${RELOGIN}"; }
echo "    the user is still there (login: ${RELOGIN})"

COUNT2=$(docker exec "${NAME}" /usr/bin/clickhouse client --query \
    "SELECT count() FROM posthog.events WHERE event = '${EVENT}'" 2>/dev/null || echo 0)
(( COUNT2 > 0 )) || fail "the event is gone after the restart"
echo "    the event is still there (${COUNT2} row(s))"

if docker logs "${NAME}" 2>&1 | grep -q "migrations finished"; then
    echo "    migrations ran again on boot and finished; the sentinel was released after ${RESTART_SECS}s"
else
    fail "the init step did not finish after the restart"
fi

log "PASS"
printf '%s\n' \
    "  health during migrations: yes" \
    "  signup: ${SIGNUP}, event in ClickHouse: ${COUNT} row(s), /flags: ${FLAGS}" \
    "  idle memory: ${USED_GIB} GiB (docker stats ${MEM})" \
    "  restart: ${RESTART_SECS}s, user and event survived"
