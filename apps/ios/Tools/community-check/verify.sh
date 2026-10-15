#!/usr/bin/env bash
# Verifies the Sources copies in this check package still match the real production sources
# and tests at their pinned hashes. Run before `swift test`: ./verify.sh && swift test
# A mismatch means the real sources changed after the last `./refresh.sh` — refresh, review
# the diff, and re-commit the copies.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/../.."          # apps/ios root
cd "$pkg"
sha256sum -c "$here/Sources/CommunityCheckKit/HASHES.txt"
