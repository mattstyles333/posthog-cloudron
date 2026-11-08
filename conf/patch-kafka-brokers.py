#!/usr/bin/env python3
"""Point the node services' librdkafka clients at the broker this container runs.

`nodejs/dist/common/kafka/{producer.js,consumer/consumer-v1.js,consumer/consumer-v2.js}` each carry
the literal `'metadata.broker.list': 'kafka:9092'` as a default — the compose service name. In the
standalone stack Docker's DNS resolves `kafka`, so nobody ever noticed; here the broker is on
loopback and the default wins over the environment (common/kafka/config.js skips env keys that are
already in the default config), so every producer/consumer would talk to a name that does not exist.

Rewriting the three literals to read `process.env.KAFKA_HOSTS` keeps upstream's override rules intact
and makes KAFKA_HOSTS — which start.sh already exports — the single source. The build fails if a
release no longer has exactly three such literals, so an upgrade that moves them is noticed.

Run at build time: patch-kafka-brokers.py <nodejs dir>
"""

import pathlib
import sys

OLD = "'metadata.broker.list': 'kafka:9092'"
NEW = "'metadata.broker.list': process.env.KAFKA_HOSTS || 'kafka:9092'"

# The zod schema the ingestion outputs validate their producer config against.
OLD_ZOD = "z.string().default('kafka:9092')"
NEW_ZOD = "z.string().default(process.env.KAFKA_HOSTS || 'kafka:9092')"

# The config object's own default, read by the producers at module load (before the env override in
# common/config/config.js runs for some paths).
OLD_HOSTS = "KAFKA_HOSTS: 'kafka:9092'"
NEW_HOSTS = "KAFKA_HOSTS: process.env.KAFKA_HOSTS || 'kafka:9092'"

EXPECTED = {
    "dist/common/config.js",
    "dist/common/outputs/kafka-producer-config.js",
    "dist/common/kafka/producer.js",
    "dist/common/kafka/consumer/consumer-v1.js",
    "dist/common/kafka/consumer/consumer-v2.js",
}


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    patched = set()
    for path in root.rglob("*.js"):
        if not path.is_file() or ".test." in path.name or path.name.endswith(".test.js"):
            continue
        text = path.read_text()
        if OLD in text:
            path.write_text(text.replace(OLD, NEW))
            patched.add(str(path.relative_to(root)))
    config_js = root / "dist/common/config.js"
    text = config_js.read_text()
    if OLD_HOSTS not in text:
        sys.exit("KAFKA_HOSTS default moved; re-check the broker patch")
    config_js.write_text(text.replace(OLD_HOSTS, NEW_HOSTS))
    patched.add("dist/common/config.js")

    zod_js = root / "dist/common/outputs/kafka-producer-config.js"
    text = zod_js.read_text()
    if OLD_ZOD not in text:
        sys.exit("kafka-producer-config default moved; re-check the broker patch")
    zod_js.write_text(text.replace(OLD_ZOD, NEW_ZOD))
    patched.add("dist/common/outputs/kafka-producer-config.js")

    if patched != EXPECTED:
        sys.exit(f"kafka broker defaults moved: patched {sorted(patched)}, expected {sorted(EXPECTED)}")
    print(f"patched {len(patched)} kafka client defaults")


if __name__ == "__main__":
    main()
