#!/usr/bin/env bash
# Copies the community-client production sources and tests from the real package into this
# Linux check package, transforms them into one module, and pins SHA-256 hashes. Refuses to
# run from a directory where the sources cannot be found. Hashes are verified again by
# verify.sh (run from test setUp), so a stale copy fails the suite instead of passing green.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/../.."          # apps/ios root

copy() { # <real source> <dest>
  test -f "$pkg/$1" || { echo "missing real source: $pkg/$1" >&2; exit 1; }
  chmod u+w "$2" 2>/dev/null || true
  cp "$pkg/$1" "$2"
}

# --- Production sources: one flat module, FLFeatureLogic import dropped (all sources in-module).
mkdir -p "$here/Sources/CommunityCheckKit"
PROD=(
  FeatureLogic/Community/CommunityContract.swift
  FeatureLogic/Community/SharePreviewBuilder.swift
  FeatureLogic/Community/OutboxStateMachine.swift
  FeatureLogic/Community/AuthorModerationState.swift
  FeatureLogic/Community/CommunityTokenStore.swift
  FeatureLogic/Community/CommunitySessionModels.swift
  FeatureLogic/Community/CommunityTableModels.swift
  FeatureLogic/Community/CommunityChallengeModels.swift
  FeatureLogic/Community/CommunityChallengeRules.swift
  FeatureLogic/Recipe/RecipeBundleV2.swift
  Feature/Community/SessionViewModel.swift
  Feature/Community/TablesViewModel.swift
  Feature/Community/ChallengesViewModel.swift
  Platform/Persistence/Database/Migrations.swift
  Platform/Persistence/Database/Subsystems/RecipeCatalogMigrations.swift
  Platform/Persistence/Database/Subsystems/TasteMigrations.swift
  Platform/Persistence/Database/Subsystems/CookSessionMigrations.swift
  Platform/Persistence/Database/Subsystems/CommunityMigrations.swift
  Platform/Persistence/Community/CommunityStore.swift
  Platform/Persistence/Community/OutboxService.swift
  Integration/Community/CommunityAPIClient.swift
  Integration/Community/CommunitySessionService.swift
)
for f in "${PROD[@]}"; do
  base="$(basename "$f")"
  copy "$f" "$here/Sources/CommunityCheckKit/$base"
  sed -i '' -e '/^import FLFeatureLogic$/d' "$here/Sources/CommunityCheckKit/$base" 2>/dev/null ||
    sed -i -e '/^import FLFeatureLogic$/d' "$here/Sources/CommunityCheckKit/$base"
done

# --- Tests: same module import swap; fixtures copied under Tests.
mkdir -p "$here/Tests/CommunityCheckTests"
TESTS=(
  CommunityContractFixtures.swift
  CommunityMigrationTests.swift
  CommunityStoreTests.swift
  OutboxStateMachineTests.swift
  OutboxServiceTests.swift
  SharePreviewRedactionTests.swift
  CommunityContractRoundTripTests.swift
  CommunitySessionRoundTripTests.swift
  CommunityClientTests.swift
)
for t in "${TESTS[@]}"; do
  copy "Tests/Community/$t" "$here/Tests/CommunityCheckTests/$t"
  sed -i '' \
    -e '/^import FLFeatureLogic$/d' \
    -e 's/^@testable import FridgeLuck$/@testable import CommunityCheckKit/' \
    "$here/Tests/CommunityCheckTests/$t" 2>/dev/null ||
    sed -i \
      -e '/^import FLFeatureLogic$/d' \
      -e 's/^@testable import FridgeLuck$/@testable import CommunityCheckKit/' \
      "$here/Tests/CommunityCheckTests/$t"
done
mkdir -p "$here/Tests/CommunityCheckTests/Fixtures"
cp "$pkg/Tests/Community/Fixtures/"*.json "$here/Tests/CommunityCheckTests/Fixtures/"

# --- Hash pins for the REAL sources, verified by verify.sh at test time.
cd "$pkg"
sha256sum "${PROD[@]}" "${TESTS[@]/#/Tests/Community/}" > "$here/Sources/CommunityCheckKit/HASHES.txt"
echo "refreshed $(wc -l < "$here/Sources/CommunityCheckKit/HASHES.txt") pinned sources"
