#!/bin/bash
# Start a PostHog service with the generated environment plus its own overrides.
#
#   svc.sh <service> <command...>
#
# Sources /run/posthog/env.sh (rebuilt on every boot from the Cloudron addons — never cached),
# then /app/code/conf/services/<service>.env, then waits for bin/init.sh to finish so no service
# reads a schema that does not exist yet, then execs the command.

set -eu

service=${1:?usage: svc.sh <service> <command...>}
shift

set +u
# shellcheck disable=SC1091
source /run/posthog/env.sh
# shellcheck disable=SC1090
[ -f "/app/code/conf/services/${service}.env" ] && source "/app/code/conf/services/${service}.env"
set -u

# Up to an hour: the first migration on an empty database is the long pole.
for _ in $(seq 1 720); do
    [[ -f /run/posthog/initialized ]] && break
    sleep 5
done

if [[ ! -f /run/posthog/initialized ]]; then
    echo "==> ${service}: migrations did not finish in an hour, starting anyway (retries on boot)" >&2
fi

exec "$@"
