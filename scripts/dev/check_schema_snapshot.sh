#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build="$root/_build/schema-snapshot"
mkdir -p "$build"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 "$root/native/schema_snapshot/main.c" -o "$build/swarm-schema-snapshot"
SCHEMA_SNAPSHOT_BINARY="$build/swarm-schema-snapshot" python3 "$root/scripts/dev/test_schema_snapshot.py"
