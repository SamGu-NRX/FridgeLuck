#!/usr/bin/env bash
# Pins the production phone sources the LeChef e2e walk compiles and records
# their hashes. Run after changing any pinned source: ./refresh.sh, review the
# copy diffs, re-commit. Rewrites applied to the copies are documented in
# rewrite.py.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/../.." && pwd)" # apps/ios root
out="$here/Sources/lechef-e2e"

pins=(
  "FeatureLogic/CookMode/CookProposalWire.swift"
  "FeatureLogic/CookMode/LiveProposalFrames.swift"
  "FeatureLogic/CookMode/CookProposalExecutor.swift"
  "FeatureLogic/CookMode/CookSession.swift"
  "FeatureLogic/CookMode/CookStep.swift"
  "FeatureLogic/CookMode/VoiceCommandParser.swift"
  "Integration/GeminiLive/GeminiLiveSessionClient.swift"
  "Integration/GeminiLive/LiveProposalCoordinator.swift"
)

mkdir -p "$out"
for rel in "${pins[@]}"; do
  cp "$pkg/$rel" "$out/$(basename "$rel")"
done

python3 "$here/rewrite.py" "$out"

cd "$pkg"
: > "$out/HASHES.txt"
for rel in "${pins[@]}"; do
  printf '%s  %s\n' "$(sha256sum "$rel" | cut -d' ' -f1)" "$rel" >> "$out/HASHES.txt"
done

echo "refreshed ${#pins[@]} pinned sources into Sources/lechef-e2e (hashes in HASHES.txt)"
