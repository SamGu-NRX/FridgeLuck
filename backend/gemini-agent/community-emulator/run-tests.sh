#!/usr/bin/env bash
# Runs the community test suite and scenarios against the Firestore emulator.
#
# Requirements: bun, a JRE (java 11+) on PATH or JAVA_HOME set, python3 for
# the suite-E wrapper. The emulator is started and torn down around the run;
# each test creates its own project namespace, so runs are hermetic.
#
# Usage: bash community-emulator/run-tests.sh [extra bun test args]
set -euo pipefail
cd "$(dirname "$0")/.."

export FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"
export COMMUNITY_SESSION_SECRET="${COMMUNITY_SESSION_SECRET:-emulator-run-secret}"
export CI="${CI:-1}"

if ! command -v java > /dev/null 2>&1; then
  echo "error: the Firestore emulator needs a JRE (java not on PATH; set JAVA_HOME or install one)" >&2
  exit 2
fi

firebase emulators:exec \
  --only firestore \
  --project community-test \
  --config community-emulator/firebase.json \
  -- "bun test src/__tests__/community"
