#!/usr/bin/env bash
# Links the real production sources this harness needs into Sources/ProfileBasicsCheck
# as generated symlinks. Idempotent; exits non-zero when a source is missing so the
# harness can never silently build without the real code.
#
# NOTE: existence checks resolve against the SYMLINK DIRECTORY (Sources/ProfileBasicsCheck),
# not the package root — checking the repo-relative path from the package root would
# silently skip every source.
set -euo pipefail

cd "$(dirname "$0")"
LINK_DIR="Sources/ProfileBasicsCheck"
mkdir -p "$LINK_DIR"

SOURCES=(
  "../../../../Domain/Models/HealthProfile.swift"
  "../../../../Domain/Models/DashboardModels.swift"
  "../../../../Domain/Models/Recipe.swift"
  "../../../../Domain/Models/UserProgress.swift"
  "../../../../Domain/Models/Inventory.swift"
  "../../../../Feature/Dashboard/HomeDashboardModels.swift"
  "../../../../Platform/Persistence/Repository/UserDataRepository.swift"
  "../../../../Platform/Persistence/Database/Migrations.swift"
  "../../../../Feature/Settings/ProfileBasics/ProfileBasicsCore.swift"
)

linked=0
for src in "${SOURCES[@]}"; do
  target="$LINK_DIR/$(basename "$src")"
  if [ -f "$src" ]; then
    ln -sfn "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" "$target"
    linked=$((linked + 1))
  elif [ -f "$target" ]; then
    # Source vanished but a stale link remains: drop it so the build cannot
    # keep using code that is no longer in the tree.
    rm -f "$target"
    echo "skip (removed stale link, not present anymore): $src"
  else
    echo "skip (not present yet): $src"
  fi
done

echo "Linked $linked production sources into $LINK_DIR"
