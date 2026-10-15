#!/usr/bin/env bash
# Copies the real production sources this replay exercises into the package so
# the harness runs the actual app code, not a fork, and pins their hashes in
# RealManifest.json (committed) so any run's provenance is checkable without
# the build tree.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../../.."
REAL="Sources/PantryFeasibilityProduction/Real"
PIN="RealManifest.json"
rm -rf "$REAL"
mkdir -p "$REAL"

# Persistence sources exercised by the replay (paths relative to apps/ios).
COPIED=()
copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
  COPIED+=("$1")
}

copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Repository/RecipeRepository.swift
copy Platform/Persistence/Repository/RecipeScoring.swift
copy Platform/Persistence/Services/NutritionService.swift
copy Platform/Persistence/Services/HealthScoringService.swift
copy Platform/Persistence/Services/PersonalizationService.swift

# Domain/feature models the persistence layer references.
copy Domain/Models/Ingredient.swift
copy Domain/Models/IngredientSwap.swift
copy Domain/Models/Inventory.swift
copy Domain/Models/Recipe.swift
copy Domain/Models/DashboardModels.swift
copy Domain/Models/DishTemplate.swift
copy Domain/Models/HealthProfile.swift
copy Domain/Models/UserProgress.swift
copy Domain/Allergens/AllergenGroupMembership.swift
copy Feature/Home/HomeDashboardModels.swift

python3 - "$IOS_ROOT" "$PIN" "${COPIED[@]}" <<'PY'
import hashlib, json, pathlib, subprocess, sys

ios_root = pathlib.Path(sys.argv[1])
pin = pathlib.Path(sys.argv[2])
rel_paths = sys.argv[3:]

sources = {}
for rel in rel_paths:
    sources[rel] = hashlib.sha256((ios_root / rel).read_bytes()).hexdigest()

try:
    toolchain = subprocess.run(
        ["swift", "--version"], capture_output=True, text=True, timeout=60
    ).stdout.splitlines()[0].strip()
except Exception:
    toolchain = ""

pin.write_text(json.dumps({
    "sources": sources,
    "toolchain": toolchain,
    "build": "swift build -Xswiftc -DSQLITE_DISABLE_SNAPSHOT",
    "note": (
        "sha256 of the real production sources copied into Real/ for the live "
        "replay; Scripts/refresh.sh regenerates this pin on every refresh"
    ),
}, indent=1) + "\n")
print(f"wrote {pin} ({len(sources)} pinned sources)")
PY

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
