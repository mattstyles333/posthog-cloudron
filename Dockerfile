# PostHog for Cloudron: one container, many processes, everything pinned to one upstream commit.
#
# Build context is this repository. The runtime is the upstream app image itself (Debian bookworm,
# Python, and /code with manage.py), with the pieces the hobby stack normally runs as separate
# containers copied in:
#
#   node image    -> /code/nodejs (plugin-server services: cdp-api, ingestion, recording-api)
#   rust images   -> /usr/local/bin/{capture,feature-flags,property-defs-rs,personhog-*}
#   clickhouse    -> /usr/bin/clickhouse + /etc/clickhouse-server (with built-in Keeper)
#     The stock image, not PostHog's fork: the fork's version string carries a "-posthog-<sha>"
#     suffix and infi.clickhouse_orm (which runs the ClickHouse migrations) fails to parse it
#     (ValueError: invalid literal for int(): '2-posthog-aca5bdabb92'). The standalone stack pins
#     this same stock digest.
#   redpanda      -> /opt/redpanda (a static binary)
#   seaweedfs     -> /usr/bin/weed (S3 for replays and exported files)
#   caddy         -> /usr/bin/caddy (the internal reverse proxy, replacing the hobby Caddy)
#
# Every image is pinned by digest (the digests are the ones ~/code/posthog-selfhost runs today),
# never by :master. Image size is not a goal.

ARG POSTHOG_IMAGE=posthog/posthog@sha256:172e64dfaf939a3803eba4fa693395dff828694cd9838999c66643a037f9148a
ARG NODE_IMAGE=ghcr.io/posthog/posthog-node@sha256:15c899114d2e55cb07555eeee5cb2dff36b72f305dd4551b7f5e4de353a1d9ce
ARG CAPTURE_IMAGE=ghcr.io/posthog/posthog/capture@sha256:95515e9c582ebda44b5d198351e67c161fc0e369e44a4fd6eb175ae8843ada8b
ARG FEATURE_FLAGS_IMAGE=ghcr.io/posthog/posthog/feature-flags@sha256:178282c57888da9c7b7348a3121eec1f7c04f5343d6237cc3d41717c50028c17
ARG PROPERTY_DEFS_IMAGE=ghcr.io/posthog/posthog/property-defs-rs@sha256:68938284e9c11a7d34a1a48dee37a1454fa49ea2eed9edb47206db272946cf24
ARG PERSONHOG_REPLICA_IMAGE=ghcr.io/posthog/posthog/personhog-replica@sha256:bed197fc4cf17291ea36ff5657299a30c6b4314ff7e8aa4bd7df042343793311
ARG PERSONHOG_ROUTER_IMAGE=ghcr.io/posthog/posthog/personhog-router@sha256:ca112d27cfae4c0bb010f421ee6c6d70abb79acd7c4d4e6eee45708b681e4c6c
ARG CLICKHOUSE_IMAGE=clickhouse/clickhouse-server@sha256:95f7cbf466dba734947775eb74808a13a3558e4398666ea6b1d992af85b9740d
ARG REDPANDA_IMAGE=redpandadata/redpanda@sha256:8f7e9e4c1422baaa1a5e2a6c6c668cfe05442cb3cb476542c7dff61725e6fe31
ARG SEAWEEDFS_IMAGE=chrislusf/seaweedfs@sha256:d47c7ee99fcb951351d7194915f4e3a5ea604a8e8871183d713907dec4fb9bf5
ARG CADDY_IMAGE=caddy@sha256:13b7fbadd017b042956fddbceedeeea12bb1e560534f9b3df281269dbcc61813

FROM ${NODE_IMAGE} AS node
FROM ${CAPTURE_IMAGE} AS capture
FROM ${FEATURE_FLAGS_IMAGE} AS featureflags
FROM ${PROPERTY_DEFS_IMAGE} AS propertydefs
FROM ${PERSONHOG_REPLICA_IMAGE} AS personhogreplica
FROM ${PERSONHOG_ROUTER_IMAGE} AS personhogrouter
FROM ${CLICKHOUSE_IMAGE} AS clickhouse
FROM ${REDPANDA_IMAGE} AS redpanda
FROM ${SEAWEEDFS_IMAGE} AS seaweedfs
FROM ${CADDY_IMAGE} AS caddy

FROM ${POSTHOG_IMAGE}

USER root

# supervisor runs the stack; openssl generates the secrets on first boot; curl is the readiness
# probe in bin/init.sh. postgresql-client is not installed: the Cloudron PostgreSQL addon is the
# database, and every SQL statement goes through psycopg (already in the image).
RUN apt-get update && \
    apt-get install -y --no-install-recommends supervisor openssl curl ca-certificates && \
    rm -rf /var/cache/apt /var/lib/apt/lists

# The plugin-server (node) code and its node_modules, from the image that runs them upstream.
# nodejs/node_modules is a pnpm tree: its packages are symlinks into /code/node_modules/.pnpm, so the
# store has to come along or every leaf module resolves to nothing ("Cannot find module
# '@opentelemetry/api'").
COPY --from=node /code/nodejs /code/nodejs
COPY --from=node /code/node_modules /code/node_modules
# node-rdkafka loads librdkafka's C and C++ libraries by soname; take exactly the ones the node image
# was built against (Debian's librdkafka1 package ships only the C library).
COPY --from=node /usr/lib/x86_64-linux-gnu/librdkafka.so.1 /usr/lib/x86_64-linux-gnu/librdkafka.so.1
COPY --from=node /usr/lib/x86_64-linux-gnu/librdkafka++.so.1 /usr/lib/x86_64-linux-gnu/librdkafka++.so.1
# Workspace packages the node services symlink to (nodejs/node_modules/@posthog/hogvm ->
# ../../../common/hogvm/typescript, and the two rust node bindings). Copied individually: the app
# image has its own /code/common for Python, which must not be replaced.
COPY --from=node /code/common/hogvm /code/common/hogvm
COPY --from=node /code/common/replay-headless /code/common/replay-headless
COPY --from=node /code/rust/common/hogvm/node /code/rust/common/hogvm/node
COPY --from=node /code/rust/replay-anonymizer-node /code/rust/replay-anonymizer-node

# At this pin every node service hardcodes HTTP_SERVER_PORT=6738 (nodejs/dist/common/config.js),
# which works when each runs in its own container. Here they share one network namespace, so make
# the port readable from the environment. The build fails if the line is not there, so an upgrade
# that changes it is noticed instead of silently colliding.
RUN sed -i 's|^exports\.DEFAULT_HTTP_SERVER_PORT = 6738;$|exports.DEFAULT_HTTP_SERVER_PORT = Number(process.env.HTTP_SERVER_PORT \|\| 6738);|' \
        /code/nodejs/dist/common/config.js && \
    grep -q 'process.env.HTTP_SERVER_PORT' /code/nodejs/dist/common/config.js

# Rust services: each image is a single static-ish binary at /usr/local/bin.
COPY --from=capture /usr/local/bin/capture /usr/local/bin/capture
COPY --from=featureflags /usr/local/bin/feature-flags /usr/local/bin/feature-flags
COPY --from=propertydefs /usr/local/bin/property-defs-rs /usr/local/bin/property-defs-rs
COPY --from=personhogreplica /usr/local/bin/personhog-replica /usr/local/bin/personhog-replica
COPY --from=personhogrouter /usr/local/bin/personhog-router /usr/local/bin/personhog-router
# The GeoIP database the Rust images carry (upstream mounts it at /share).
COPY --from=featureflags /app/share/GeoLite2-City.mmdb /app/share/GeoLite2-City.mmdb

# ClickHouse server with its config; Keeper replaces ZooKeeper (see conf/clickhouse/config.d).
COPY --from=clickhouse /usr/bin/clickhouse /usr/bin/clickhouse
COPY --from=clickhouse /etc/clickhouse-server /etc/clickhouse-server
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml

# Redpanda (Kafka) is a static binary; rpk creates the topics.
COPY --from=redpanda /opt/redpanda /opt/redpanda
RUN ln -sf /opt/redpanda/bin/redpanda /usr/bin/redpanda && ln -sf /opt/redpanda/bin/rpk /usr/bin/rpk

# SeaweedFS: one S3 gateway on 19000 (Django object storage) and one on 8333 (replay blobs), the
# two ports upstream splits across two servers.
COPY --from=seaweedfs /usr/bin/weed /usr/bin/weed

COPY --from=caddy /usr/bin/caddy /usr/bin/caddy


# Package files.
COPY start.sh supervisord.conf env.sh.template /app/code/
COPY caddy/Caddyfile /app/code/conf/Caddyfile
COPY bin/ /app/code/bin/
COPY conf/ /app/code/conf/
# PostHog's ClickHouse executable UDFs, copied out of the app image into /app/code so the server
# can run them from the read-only root filesystem, with the /tmp-noexec workaround applied
# (conf/patch-run-udf.py explains why).
RUN cp -a /code/posthog/user_scripts /app/code/user_scripts && \
    python3 /app/code/conf/patch-run-udf.py /app/code/user_scripts

# The node services' librdkafka default is the compose service name `kafka:9092`; here the broker
# is on loopback (conf/patch-kafka-brokers.py explains why the env cannot override it).
RUN python3 /app/code/conf/patch-kafka-brokers.py /code/nodejs

RUN chmod +x /app/code/start.sh /app/code/bin/*.sh /app/code/bin/*.py && \
    cp /app/code/conf/clickhouse/config.d/*.xml /etc/clickhouse-server/config.d/ && \
    cp /app/code/conf/clickhouse/user_defined_function.xml /etc/clickhouse-server/user_defined_function.xml && \
    cp /app/code/conf/clickhouse/users.d/*.xml /etc/clickhouse-server/users.d/

RUN mkdir -p /app/data/clickhouse-backup \
        /var/lib/posthog/clickhouse /var/lib/posthog/redpanda \
        /run/posthog /run/caddy /run/postgresql

EXPOSE 8000

CMD [ "/app/code/start.sh" ]
