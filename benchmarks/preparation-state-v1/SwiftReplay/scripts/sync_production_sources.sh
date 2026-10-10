#!/bin/sh
# Sync the production lexicon source into this package before building.
# The copy is gitignored; the benchmark replays the real source, never a re-typed one.
set -eu
cd "$(dirname "$0")/../../.."
REPO_ROOT="$(pwd -P)"
DST="$REPO_ROOT/benchmarks/preparation-state-v1/SwiftReplay/Sources/SwiftReplayProduction"
mkdir -p "$DST"
cp "$REPO_ROOT/apps/ios/Capability/Core/Recognition/IngredientLexicon.swift" "$DST/IngredientLexicon.swift"
echo "synced IngredientLexicon.swift ($(wc -l < "$DST/IngredientLexicon.swift") lines)"
