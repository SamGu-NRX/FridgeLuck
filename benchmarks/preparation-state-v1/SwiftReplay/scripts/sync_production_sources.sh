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
LEXICON="$REPO_ROOT/apps/ios/Capability/Core/Recognition/IngredientLexicon.swift"
CONTRACTS="$REPO_ROOT/apps/ios/Capability/Core/Recognition/ScanContracts.swift"
cp "$LEXICON" "$DST/IngredientLexicon.swift"
# The lexicon references OCRMatchKind, defined in ScanContracts.swift. That file
# imports CoreGraphics and FLFeatureLogic and cannot be compiled on Linux, so copy
# ONLY the enum OCRMatchKind block, verbatim, with its source provenance pinned
# (line numbers and sha256) so the replay still runs the real production bytes.
python3 - "$CONTRACTS" "$DST/OCRMatchKind.swift" <<'PYEOF'
import hashlib
import re
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path).read()
m = re.search(r"^enum OCRMatchKind: String, Sendable, Codable \{.*?^\}", src, re.S | re.M)
assert m, "enum OCRMatchKind block not found in ScanContracts.swift"
sha = hashlib.sha256(open(src_path, "rb").read()).hexdigest()
start_line = src[: m.start()].count("\n") + 1
header = (
    "// Synced verbatim from apps/ios/Capability/Core/Recognition/ScanContracts.swift\n"
    f"// (lines {start_line}-{start_line + m.group(0).count(chr(10))} of that file; sha256 {sha}).\n"
    "// Only this block is copied: the rest of ScanContracts needs CoreGraphics and\n"
    "// FLFeatureLogic and is outside the lexicon replay surface. Do not edit here.\n"
)
open(dst_path, "w").write(header + m.group(0) + "\n")
print(f"extracted enum OCRMatchKind (ScanContracts.swift:{start_line}, sha256 {sha[:12]})")
PYEOF
echo "synced IngredientLexicon.swift ($(wc -l < "$DST/IngredientLexicon.swift") lines)"
