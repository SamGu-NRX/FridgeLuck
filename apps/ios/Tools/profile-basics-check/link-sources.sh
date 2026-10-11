#!/usr/bin/env bash
# Links the real production sources this harness needs into Sources/ProfileBasicsCheck
# as generated symlinks. Idempotent; exits non-zero when a source is missing so the
# harness can never silently build without the real code.
#
# NOTE: SOURCES paths are relative to the PACKAGE ROOT (where this script runs):
# up one is Tools/, up two is apps/ios/, where Domain/, Feature/, Platform/ live.
# Link targets are stored absolute, so symlink resolution never depends on CWD.
set -euo pipefail

cd "$(dirname "$0")"
LINK_DIR="Sources/ProfileBasicsCheck"
mkdir -p "$LINK_DIR"

SOURCES=(
  "../../Domain/Models/HealthProfile.swift"
  "../../Domain/Models/DashboardModels.swift"
  "../../Domain/Models/Recipe.swift"
  "../../Domain/Models/UserProgress.swift"
  "../../Domain/Models/Inventory.swift"
  "../../Feature/Home/HomeDashboardModels.swift"
  "../../Platform/Persistence/Repository/UserDataRepository.swift"
  "../../Platform/Persistence/Database/Migrations.swift"
  "../../Feature/Settings/ProfileBasics/ProfileBasicsCore.swift"
)

linked=0
missing=0
for src in "${SOURCES[@]}"; do
  target="$LINK_DIR/$(basename "$src")"
  if [ -f "$src" ]; then
    ln -sfn "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" "$target"
    linked=$((linked + 1))
  elif [ -f "$target" ]; then
    # Source vanished but a stale link remains: drop it so the build cannot
    # keep using code that is no longer in the tree.
    rm -f "$target"
    echo "skip (removed stale link, not present anymore): $src" >&2
    missing=$((missing + 1))
  else
    echo "MISSING (required): $src" >&2
    missing=$((missing + 1))
  fi
done

echo "Linked $linked production sources into $LINK_DIR"
if [ "$missing" -gt 0 ]; then
  echo "FATAL: $missing required production source(s) missing; refusing to build." >&2
  exit 1
fi
