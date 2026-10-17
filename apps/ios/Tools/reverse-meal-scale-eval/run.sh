#!/bin/bash
set -euo pipefail
# Build and run the next-decisions-v1 scale runner on Linux.
#   bash run.sh EVIDENCE_JSONL REPLAY_JSON --result RESULT_JSON
# The runner writes RESULT_JSON plus execution-record.json next to it.
if [ "$#" -ne 4 ] || [ "$3" != '--result' ]; then
  echo 'usage: bash run.sh EVIDENCE_JSONL REPLAY_JSON --result RESULT_JSON' >&2
  exit 1
fi
TOOL_DIR="$(dirname "$(realpath "$0")")"
IOS_DIR="$(realpath "$TOOL_DIR/../..")"
SWIFT_BIN=/home/user/swift/usr/bin

BUILD_DIR=$(mktemp -d /tmp/fl-scale-eval/build.XXXXXX)
mkdir -p "$BUILD_DIR/module-cache" "$BUILD_DIR/inputs"
echo "build_dir=$BUILD_DIR" >&2

# Stage the compile closure: the real product sources (pinned copies hashed into
# the build record) plus this tool's main.swift. ConfidenceLearningService is
# staged by the preprocessor (Linux os-module shims); everything else verbatim.
CLOSURE=(
  Domain/Models/Recipe.swift
  Domain/Models/Ingredient.swift
  Domain/Models/HealthProfile.swift
  Domain/Models/IngredientSwap.swift
  Domain/Models/UserProgress.swift
  Platform/Persistence/Database/Migrations.swift
  Platform/Persistence/Database/AppDatabase.swift
  Platform/Persistence/Repository/RecipeRepository.swift
  Platform/Persistence/Repository/RecipeScoring.swift
  Platform/Persistence/Services/NutritionService.swift
  Platform/Persistence/Services/HealthScoringService.swift
  Platform/Persistence/Services/PersonalizationService.swift
  Platform/Persistence/Bundle/BundledDataLoader.swift
  Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift
  Platform/Persistence/Bundle/BundledDataLoaderRecipeHydration.swift
)
declare -a STAGED=()
python3 -B "$TOOL_DIR/preprocess_learner.py" "$IOS_DIR/Platform/Persistence/Services/ConfidenceLearningService.swift" "$BUILD_DIR/inputs/ConfidenceLearningService.swift" >/dev/null
STAGED+=("$BUILD_DIR/inputs/ConfidenceLearningService.swift")
for rel in "${CLOSURE[@]}"; do
  cp "$IOS_DIR/$rel" "$BUILD_DIR/inputs/$(basename "$rel")"
  # Linux Foundation cannot infer the CharacterSet base in
  # `.trimmingCharacters(in: .whitespacesAndNewlines)`; spell it out (same type).
  if [ "$(basename "$rel")" = "RecipeRepository.swift" ]; then
    sed -i 's/trimmingCharacters(in: \.whitespacesAndNewlines)/trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)/g' "$BUILD_DIR/inputs/RecipeRepository.swift"
  fi
  STAGED+=("$BUILD_DIR/inputs/$(basename "$rel")")
done
cp "$TOOL_DIR/main.swift" "$BUILD_DIR/inputs/main.swift"
STAGED+=("$BUILD_DIR/inputs/main.swift")
# The loader reads data.json from Bundle.main: place it next to the binary.
cp "$IOS_DIR/Resources/data.json" "$BUILD_DIR/data.json"

# GRDB artifacts: reuse the staged dylib if present, else build once.
GRDB_DIR=/tmp/fl-scale-eval/grdb
if [ ! -f "$GRDB_DIR/libGRDB-dynamic.so" ]; then
  mkdir -p "$GRDB_DIR"
  echo "building GRDB (one-time)..." >&2
  (cd "$IOS_DIR/Vendor/GRDB.swift" && "$SWIFT_BIN/swift" build -c release -Xswiftc -DSQLITE_DISABLE_SNAPSHOT > "$BUILD_DIR/grdb-build.log" 2>&1)
  GR=".build/x86_64-unknown-linux-gnu/release"
  cp "$IOS_DIR/Vendor/GRDB.swift/$GR/libGRDB-dynamic.so" "$GRDB_DIR/"
  cp "$IOS_DIR/Vendor/GRDB.swift/$GR/Modules/GRDB.swiftmodule" "$GRDB_DIR/" 2>/dev/null || true
fi
cp "$GRDB_DIR/libGRDB-dynamic.so" "$GRDB_DIR/GRDB.swiftmodule" "$BUILD_DIR/" 2>/dev/null || cp "$GRDB_DIR/libGRDB-dynamic.so" "$BUILD_DIR/"
# GRDB's modulemap references the GRDBSQLite C-shim source directory.
cp -R "$IOS_DIR/Vendor/GRDB.swift/Sources/GRDBSQLite" "$BUILD_DIR/inputs/GRDBSQLite"

export PATH="$SWIFT_BIN:$PATH"
"$SWIFT_BIN/swiftc" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -I "$BUILD_DIR" -I "$BUILD_DIR/inputs/GRDBSQLite" -L "$BUILD_DIR" -lGRDB-dynamic \
  -Xlinker -rpath -Xlinker '$ORIGIN' \
  "${STAGED[@]}" -o "$BUILD_DIR/reverse-meal-scale-runner"

# Build record: source hashes, GRDB hash, toolchain version.
python3 -B - "$TOOL_DIR" "$BUILD_DIR" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
tool, build = map(Path, sys.argv[1:])
sources = {}
for p in sorted((build / 'inputs').glob('*.swift')):
    sources[p.name] = hashlib.sha256(p.read_bytes()).hexdigest()
record = {
    'sources': sources,
    'grdb': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
             for p in [build / 'libGRDB-dynamic.so']},
    'swift_version': subprocess.check_output(['swiftc', '--version'], text=True),
    'preprocess': hashlib.sha256((tool / 'preprocess_learner.py').read_bytes()).hexdigest(),
}
(build / 'build-record.json').write_text(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
PY

"$BUILD_DIR/reverse-meal-scale-runner" "$1" "$2" --result "$4"
