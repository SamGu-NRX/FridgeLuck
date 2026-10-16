#!/usr/bin/env bash
# Verifies the pinned phone sources in the e2e walk still match the real
# production sources at their recorded hashes. Run before swift build:
# ./verify.sh && swift build
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/../.." && pwd)" # apps/ios root
cd "$pkg"
sha256sum -c "$here/Sources/lechef-e2e/HASHES.txt"
