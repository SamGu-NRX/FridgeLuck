#!/bin/sh
# Recreates the Sources/ProfileBasicsCheck symlinks into the app's existing
# sources. Nothing is forked: every file under test is the real production
# source. Run once from the package root before `swift test` (the linked files
# are not committed — they are generated here).
set -eu
cd "$(dirname "$0")"

LINK_DIR="Sources/ProfileBasicsCheck"
mkdir -p "$LINK_DIR"

# Paths are relative to $LINK_DIR (../../.. = this package root, ../../../../ = apps/ios).
for f in \
  "../../../../Domain/Models/HealthProfile.swift" \
  "../../../../Platform/Persistence/Repository/UserDataRepository.swift" \
  "../../../../Platform/Persistence/Database/Migrations.swift" \
  "../../../../Feature/Settings/ProfileBasics/ProfileBasicsCore.swift"
do
  if [ -e "$f" ]; then
    ln -sfn "$f" "$LINK_DIR/$(basename "$f")"
  else
    echo "skip (not present yet): $f" >&2
  fi
done

echo "Linked $(ls -1 "$LINK_DIR" | wc -l) production sources into $LINK_DIR"
