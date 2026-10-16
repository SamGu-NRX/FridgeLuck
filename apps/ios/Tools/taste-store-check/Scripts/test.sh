#!/bin/sh
# Runs the portable taste-store check on Linux.
#
# Toolchain discovery mirrors the SwiftReplay fallback list: sandbox recycles can
# relocate or remove toolchains, so keep this list current.
#
# The -DSQLITE_DISABLE_SNAPSHOT flag is required: the sandbox's system SQLite lacks
# the sqlite3_snapshot_* APIs, and the GRDB dependency is built from source here.
# The testTarget also needs --allow-shlib-undefined (set in Package.swift): the
# toolchain's libswiftObservation.so references its own internal fatal hook that no
# shipped shared library defines; it is only reached on runtime aborts.
set -e
cd "$(dirname "$0")/.."

SWIFT=""
for candidate in "$(command -v swift 2>/dev/null)" \
  /home/user/swift612/usr/bin/swift \
  /home/user/work/bench/tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swift; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    SWIFT="$candidate"
    break
  fi
done
if [ -z "$SWIFT" ]; then
  echo "no Swift toolchain found; install one or extend the fallback list" >&2
  exit 1
fi
echo "using $(dirname "$(dirname "$SWIFT")")"
"$SWIFT" test -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
