#!/bin/sh
# Sync the production lexicon source into this package before building.
# The copy is gitignored; the benchmark replays the real source, never a re-typed one.
set -eu
# Anchor on the git worktree root: dirname-based climbing breaks because the
# script sits five levels deep (repo/benchmarks/preparation-state-v1/
# SwiftReplay/scripts/), and any off-by-one silently copies from the wrong tree.
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DST="$REPO_ROOT/benchmarks/preparation-state-v1/SwiftReplay/Sources/SwiftReplayProduction"
mkdir -p "$DST"
cp "$REPO_ROOT/apps/ios/Capability/Core/Recognition/IngredientLexicon.swift" "$DST/IngredientLexicon.swift"
echo "synced IngredientLexicon.swift ($(wc -l < "$DST/IngredientLexicon.swift") lines)"
