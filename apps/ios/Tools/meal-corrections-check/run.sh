#!/usr/bin/env bash
# Runs the offline meal-correction checks. Works on Linux and macOS; on Linux the GRDB
# build needs -DSQLITE_DISABLE_SNAPSHOT because system SQLite lacks the WAL snapshot API.
set -euo pipefail

cd "$(dirname "$0")"
./bootstrap.sh

swift test -Xswiftc -DSQLITE_DISABLE_SNAPSHOT "$@"
