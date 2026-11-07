#!/usr/bin/env python3
"""Make PostHog's ClickHouse UDF wrappers runnable under Cloudron.

`user_scripts/run_udf.sh` copies the arch-specific binary into /tmp and executes the copy, because a
deploy may replace the binary under a process that is already running it. Cloudron mounts /tmp
noexec (and an app cannot change that), so the copy fails with EACCES and every UDF call errors with
"Child process was exited with return code 126".

Here the binary is executed in place instead. The scenario the copy protects against cannot happen
in this package: every update restarts the container, so no binary is replaced under a running
process.

Run at build time: patch-run-udf.py <user_scripts dir>
"""

import pathlib
import sys

OLD = '''cp "$DIR_NAME/$EXECUTABLE_NAME" "$TEMP_DIR/$EXECUTABLE_NAME"
chmod +x "$TEMP_DIR/$EXECUTABLE_NAME"
"$TEMP_DIR/$EXECUTABLE_NAME" "$@"'''

NEW = '''exec "$DIR_NAME/$EXECUTABLE_NAME" "$@"'''


def main() -> None:
    path = pathlib.Path(sys.argv[1]) / "run_udf.sh"
    text = path.read_text()
    if OLD not in text:
        sys.exit(f"{path}: the copy-to-/tmp block is gone; re-check the noexec workaround")
    path.write_text(text.replace(OLD, NEW))
    print(f"patched {path}")


if __name__ == "__main__":
    main()
