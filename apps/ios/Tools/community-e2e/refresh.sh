#!/usr/bin/env bash
# Copies the community-client production sources from the real package into this Linux e2e
# walk package, transforms them into one module, and pins SHA-256 hashes that the walk
# binary verifies at startup. Refuses to run where the sources cannot be found. Unlike the
# check package there are no tests to verify a stale copy — the walk re-runs refresh
# freshly, so the pin is the walk's own proof it exercised today's sources.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/../.."          # apps/ios root

copy() { # <real source> <dest>
  test -f "$pkg/$1" || { echo "missing real source: $pkg/$1" >&2; exit 1; }
  chmod u+w "$2" 2>/dev/null || true
  cp "$pkg/$1" "$2"
}

# --- Production sources: one flat module, FLFeatureLogic import dropped (all in-module).
mkdir -p "$here/Sources/CommunityE2EWalk"
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
  FeatureLogic/Community/CommunityModerationModels.swift
  FeatureLogic/Community/CommunityExploreModels.swift
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
  copy "$f" "$here/Sources/CommunityE2EWalk/$base"
  sed -i '' -e '/^import FLFeatureLogic$/d' "$here/Sources/CommunityE2EWalk/$base" 2>/dev/null ||
    sed -i -e '/^import FLFeatureLogic$/d' "$here/Sources/CommunityE2EWalk/$base"
done
# The walk's own sources are everything not copied (main.swift, PinnedDigest.swift).
cd "$pkg"
# Per-file pins for review, plus one combined digest embedded into the walk binary at compile
# time (refresh runs right before the build, so the digest is the binary's proof of which
# sources it exercised).
sha256sum "${PROD[@]}" > "$here/Sources/CommunityE2EWalk/HASHES.txt"
combined="$(sha256sum "${PROD[@]}" | sha256sum | cut -d' ' -f1)"
cat > "$here/Sources/CommunityE2EWalk/PinnedDigest.swift" <<EOF
/// sha256 of the per-file sha256 list of the production sources this walk was built from
/// (refresh.sh writes it; see HASHES.txt for the per-file detail).
let pinnedSourceDigest = "$combined"
EOF
echo "refreshed $(wc -l < "$here/Sources/CommunityE2EWalk/HASHES.txt") pinned sources (digest $combined)"
