#!/usr/bin/env bash
# Stages the production sources the flow check exercises into Sources/.
#
# The staged copies are throwaway: this script re-copies from the repo on every
# run, so the check always exercises the CURRENT production sources, never a
# stale fork. Nothing under Sources/ is edited by hand or committed.
#
# Usage:
#   ./Scripts/refresh.sh                       # cookbook core (default)
#   STAGE_BUNDLE_STACK=1 ./Scripts/refresh.sh  # also stage the bundle refresh
#                                              # stack and its anti-theft tests
#
# The bundle stack is gated because the base branch's BundledDataRefresher.swift
# does not compile anywhere yet. Verified against the canonical configuration
# (project.yml SWIFT_VERSION: 6.0, GRDB Package.resolved 7.10.0):
#   1. declarations and call sites disagree on the `db` first-argument label in
#      both directions, across single-line and wrapped formatting;
#   2. two expressions place `try` to the right of `||` (`a || try b` is not
#      valid Swift);
#   3. `db.lastInsertRowId` — removed in GRDB 7; only `lastInsertedRowID`
#      exists, returning the identical value;
#   4. Swift 6 concurrency: 14 "mutation of captured var 'outcome'" and 14
#      "capture of 'injections' with non-sendable type" diagnostics across the
#      refresh entry points — a structural refactor, not a call-form fix.
# Staging-only shims handle 1-3 mechanically (below). Defect 4 is why the gate
# exists: fixing it means restructuring the protected file's logic, which is
# the bundle-refresh branch's job. Flip the toggle when its owner lands a
# compiling refresher; the anti-theft tests then run unmodified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"   # apps/ios
cd "$SCRIPT_DIR/.."

STAGE_BUNDLE_STACK="${STAGE_BUNDLE_STACK:-0}"
PARK_DIR=".bundled-refresh-stack"   # gitignored holding area for gated files

require() {
  if [ ! -f "$1" ]; then
    echo "error: expected file is missing: $1" >&2
    echo "       is this checkout complete and on a cookbook branch?" >&2
    exit 1
  fi
}

rm -rf Sources
mkdir -p Sources/FLFeatureLogic Sources/CookbookFlowCheck

# Pure decision logic the cookbook persistence composes with.
require "$IOS_ROOT/FeatureLogic/Cookbook/CookbookModels.swift"
require "$IOS_ROOT/FeatureLogic/Cookbook/CookbookRecipePolicy.swift"
cp "$IOS_ROOT"/FeatureLogic/Cookbook/*.swift Sources/FLFeatureLogic/

# Domain row models.
for f in Recipe.swift Ingredient.swift; do
  require "$IOS_ROOT/Domain/Models/$f"
  cp "$IOS_ROOT/Domain/Models/$f" Sources/CookbookFlowCheck/
done

# Real migrations (read-only use: the check validates the store against the
# production schema, not a parallel fixture schema).
require "$IOS_ROOT/Platform/Persistence/Database/Migrations.swift"
cp "$IOS_ROOT/Platform/Persistence/Database/Migrations.swift" Sources/CookbookFlowCheck/

# The cookbook persistence under test.
require "$IOS_ROOT/Platform/Persistence/Cookbook/CookbookStore.swift"
require "$IOS_ROOT/Platform/Persistence/Cookbook/UserRecipeTransactionService.swift"
cp "$IOS_ROOT"/Platform/Persistence/Cookbook/*.swift Sources/CookbookFlowCheck/

if [ "$STAGE_BUNDLE_STACK" = "1" ]; then
  # Database container (its warm-up path drives the bundle refresh) and the
  # bundled refresh stack — the anti-theft proof runs the real adoption/update
  # pass over a real database and asserts user rows survive it untouched.
  for f in AppDatabase.swift; do
    require "$IOS_ROOT/Platform/Persistence/Database/$f"
    cp "$IOS_ROOT/Platform/Persistence/Database/$f" Sources/CookbookFlowCheck/
  done
  for f in BundleOwnership BundledDataRefresher BundledDataValidator BundledDataLoader \
           BundledDataLoaderRecipeHydration BundledDataLoaderUSDACatalog LegacyBundlePins; do
    require "$IOS_ROOT/Platform/Persistence/Bundle/$f.swift"
    cp "$IOS_ROOT/Platform/Persistence/Bundle/$f.swift" Sources/CookbookFlowCheck/
  done
  # Restore the anti-theft tests if a previous run parked them.
  if [ -f "$PARK_DIR/Tests/BundledRefreshAntiTheftTests.swift" ]; then
    mv "$PARK_DIR/Tests/BundledRefreshAntiTheftTests.swift" Tests/CookbookFlowCheckTests/
  fi
else
  # Park the anti-theft tests: they exercise the gated bundle stack.
  mkdir -p "$PARK_DIR/Tests"
  if [ -f Tests/CookbookFlowCheckTests/BundledRefreshAntiTheftTests.swift ]; then
    mv Tests/CookbookFlowCheckTests/BundledRefreshAntiTheftTests.swift "$PARK_DIR/Tests/"
  fi
fi

# Staging shims — staged copies ONLY, production sources are never edited.
#
# 1. CryptoKit is an Apple-only framework; on Linux the identical API ships as
#    the `Crypto` module from swift-crypto. The canImport guard keeps staged
#    files building on iOS with real CryptoKit while making them compile here.
#
# 2. Bundle-stack call-form corrections (mechanical, behavior-neutral; see the
#    defect list in the header). Applied to staged copies only.
python3 - <<'PY'
from pathlib import Path
import re

crypto_shim = (
    "#if canImport(CryptoKit)\n"
    "import CryptoKit\n"
    "#else\n"
    "import Crypto\n"
    "#endif"
)
bundle_file = re.compile(r"(BundleOwnership|BundledData\w+|LegacyBundlePins|AppDatabase)\.swift")
# `func f(db: Database` and `func f(\n    db: Database` — either formatting.
decl_re = re.compile(r"func (\w+)\(\n?(\s*)db: Database\b")
# `g(db: db` and `g(\n    db: db` — either formatting.
call_re = re.compile(r"\(\n?(\s*)db: db\b")

for f in Path("Sources/CookbookFlowCheck").glob("*.swift"):
    text = f.read_text()
    fixed = text.replace("import CryptoKit", crypto_shim, 1)
    if bundle_file.fullmatch(f.name):
        fixed = decl_re.sub(r"func \1(\2_ db: Database", fixed)
        fixed = call_re.sub(r"(\1db", fixed)
        fixed = fixed.replace("db.lastInsertRowId", "db.lastInsertedRowID")
        fixed = fixed.replace("|| try hasDiagnostic(", "|| hasDiagnostic(")
        fixed = re.sub(r"entryOk =(\s+)liveHash ==", r"entryOk =\1try liveHash ==", fixed)
    if fixed != text:
        f.write_text(fixed)
PY

echo "Staged $(find Sources -name '*.swift' | wc -l | tr -d ' ') source files (bundle stack: $STAGE_BUNDLE_STACK)."
