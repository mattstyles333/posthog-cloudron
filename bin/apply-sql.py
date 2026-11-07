#!/usr/bin/env python3
"""Run SQL files against the Cloudron PostgreSQL addon database.

Used by bin/init.sh for the statements PostHog's own migrations do not cover: the persons
fix-up, the extra schema the CDP API uses, and the vendored cyclotron migrations (upstream runs
them with sqlx, which the released images do not carry).

    apply-sql.py --file <path> [--search-path <schema>]
    apply-sql.py --schema <name>
    apply-sql.py --migrations <dir> <tracking-table> [--search-path <schema>]

Everything is idempotent: a second run applies nothing.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys
import time

import psycopg


def connect() -> psycopg.Connection:
    url = os.environ.get("CLOUDRON_POSTGRESQL_URL")
    if not url:
        sys.exit("CLOUDRON_POSTGRESQL_URL is not set")
    last: Exception | None = None
    for _ in range(150):
        try:
            return psycopg.connect(url, autocommit=True)
        except psycopg.OperationalError as exc:  # the addon may still be starting
            last = exc
            time.sleep(2)
    sys.exit(f"cannot connect to the addon database: {last}")


def run_file(conn: psycopg.Connection, path: pathlib.Path, search_path: str | None) -> None:
    with conn.transaction():
        with conn.cursor() as cur:
            if search_path:
                cur.execute(f'SET LOCAL search_path TO "{search_path}", public')
            cur.execute(path.read_text())
    print(f"  applied {path.name}", flush=True)


def migrate(
    conn: psycopg.Connection, directory: pathlib.Path, table: str, search_path: str | None
) -> int:
    qualified = f'"{search_path}".{table}' if search_path else table
    with conn.cursor() as cur:
        cur.execute(
            f"CREATE TABLE IF NOT EXISTS {qualified} "
            "(name text PRIMARY KEY, applied_at timestamptz DEFAULT now())"
        )
        cur.execute(f"SELECT name FROM {qualified}")
        done = {row[0] for row in cur.fetchall()}
    applied = 0
    for path in sorted(directory.glob("*.sql")):
        name = re.sub(r"\.sql$", "", path.name)
        if name in done:
            continue
        run_file(conn, path, search_path)
        with conn.cursor() as cur:
            cur.execute(f"INSERT INTO {qualified} (name) VALUES (%s)", (name,))
        applied += 1
    return applied


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file")
    parser.add_argument("--schema")
    parser.add_argument("--search-path")
    parser.add_argument("--migrations", nargs=2, metavar=("DIR", "TABLE"))
    args = parser.parse_args()

    conn = connect()
    try:
        if args.schema:
            with conn.cursor() as cur:
                cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{args.schema}"')
            print(f"  schema {args.schema} ready", flush=True)
        if args.file:
            run_file(conn, pathlib.Path(args.file), args.search_path)
        if args.migrations:
            directory, table = args.migrations
            count = migrate(conn, pathlib.Path(directory), table, args.search_path)
            print(f"  {count} new migration(s) in {directory}", flush=True)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
