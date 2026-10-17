#!/usr/bin/env python3
"""Generate the vendored replay source from production files (verbatim regions).

The replay compiles byte-identical regions of the production scoring code,
extracted by exact marker lines. Regions are recorded in RegionManifest.json
with their 1-indexed line ranges and sha256 so tests can detect any drift
between the vendored copy and production at the pinned base.

Parity claim: ONLY the text between REPLAY-VENDORED-REGION markers is claimed
byte-identical to production. Scaffolding (replay-side type shells, access
wrappers, imports) is explicitly NOT part of the claim.

Usage: python3 make_vendored.py [--repo-root PATH]. Regeneration is idempotent;
tests assert the committed outputs match a fresh run.
"""

import argparse
import hashlib
import json
import pathlib
import sys


def find_repo_root(start: pathlib.Path) -> pathlib.Path:
    for candidate in [start] + list(start.parents):
        if (candidate / ".git").exists() or (candidate / ".git").is_file():
            return candidate
    raise SystemExit(f"could not locate repo root from {start}")


REGIONS = [
    {
        "id": "HealthScore_struct",
        "file": "apps/ios/Platform/Persistence/Services/HealthScoringService.swift",
        "start_marker": "struct HealthScore: Sendable {",
        "end": "column0_brace",
    },
    {
        "id": "computeScore_func",
        "file": "apps/ios/Platform/Persistence/Services/HealthScoringService.swift",
        "start_marker": "  private func computeScore(macros: RecipeMacros, profile: HealthProfile) -> HealthScore {",
        "end": "two_space_close",
    },
    {
        "id": "buildReasoning_func",
        "file": "apps/ios/Platform/Persistence/Services/HealthScoringService.swift",
        "start_marker": "  private func buildReasoning(",
        "end": "two_space_close",
    },
    {
        "id": "RecipeMacros_struct",
        "file": "apps/ios/Platform/Persistence/Services/NutritionService.swift",
        "start_marker": "struct RecipeMacros: Sendable {",
        "end": "column0_brace",
    },
    {
        "id": "RecipeTags_struct",
        "file": "apps/ios/Domain/Models/Recipe.swift",
        "start_marker": "struct RecipeTags: OptionSet, Sendable, Codable {",
        "end": "column0_brace",
    },
    {
        "id": "Recipe_struct",
        "file": "apps/ios/Domain/Models/Recipe.swift",
        "start_marker": "struct Recipe: Identifiable, Sendable, Codable {",
        "end": "column0_brace",
    },
    {
        "id": "HealthProfile_struct",
        "file": "apps/ios/Domain/Models/HealthProfile.swift",
        "start_marker": "struct HealthProfile: Sendable, Codable {",
        "end": "column0_brace",
    },
    {
        "id": "sharedRankingScore_and_rankingReasons",
        "file": "apps/ios/Platform/Persistence/Repository/RecipeScoring.swift",
        "start_marker": "  static func sharedRankingScore(",
        "end": "two_space_close_last",
    },
]


def extract(lines, start_marker, end_kind):
    start_idx = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == start_marker:
            start_idx = i
            break
    if start_idx is None:
        raise SystemExit(f"start marker not found: {start_marker!r}")
    # For two_space_close_last: the region runs to the LAST '  }' line in the file
    # (the ranking extension ends with its final function close).
    last_two_space = None
    for j in range(start_idx + 1, len(lines)):
        stripped = lines[j].rstrip("\n")
        if stripped == "  }":
            last_two_space = j
        if end_kind == "column0_brace" and stripped == "}":
            return start_idx, j
        if end_kind == "two_space_close" and stripped == "  }":
            return start_idx, j
    if end_kind == "two_space_close_last" and last_two_space is not None:
        return start_idx, last_two_space
    raise SystemExit(f"end marker not reached for {start_marker!r}")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> int:
    here = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=None)
    args = parser.parse_args()
    repo_root = pathlib.Path(args.repo_root) if args.repo_root else find_repo_root(here)

    manifest = {"schema_version": 1, "regions": []}
    extracted = {}
    for region in REGIONS:
        path = repo_root / region["file"]
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        s, e = extract(lines, region["start_marker"], region["end"])
        text = "".join(lines[s:e + 1])
        if not text.endswith("\n"):
            text += "\n"
        manifest["regions"].append({
            "id": region["id"],
            "file": region["file"],
            "start_line": s + 1,
            "end_line": e + 1,
            "sha256": sha256_text(text),
        })
        extracted[region["id"]] = text

    ids = [r["id"] for r in manifest["regions"]]
    r = {k: extracted[k].rstrip("\n") for k in extracted}

    final = f'''// GENERATED FILE - DO NOT EDIT BY HAND. Regenerate with:
//   python3 make_vendored.py
// Parity: text between REPLAY-VENDORED-REGION markers is byte-identical to the
// production files at the pinned base (see RegionManifest.json). Everything else
// in this file is replay-side scaffolding and is NOT part of the parity claim.

import Foundation

// SCAFFOLD-BEGIN (replay-side; NOT parity)
/// Replay-side replacement: production HealthGoal carries a GRDB conformance in
/// its declaration; the cases and raw values below match production exactly.
enum HealthGoal: String, Codable, Sendable {{
  case general
  case weightLoss = "weight_loss"
  case muscleGain = "muscle_gain"
  case maintenance
}}

/// Replay-side replacement: production RecipeSource carries a GRDB conformance.
enum RecipeSource: String, Codable, Sendable {{
  case bundled
  case user
  case aiGenerated = "ai_generated"
}}
// SCAFFOLD-END

// REPLAY-VENDORED-REGION-START {ids[0]}
{r[ids[0]]}
// REPLAY-VENDORED-REGION-END {ids[0]}

final class HealthScoringServiceReplay {{
// REPLAY-VENDORED-REGION-START {ids[1]}
{r[ids[1]]}
// REPLAY-VENDORED-REGION-END {ids[1]}

// REPLAY-VENDORED-REGION-START {ids[2]}
{r[ids[2]]}
// REPLAY-VENDORED-REGION-END {ids[2]}

  // SCAFFOLD-BEGIN (replay-side access wrappers; NOT parity)
  func replayScore(macros: RecipeMacros, profile: HealthProfile) -> HealthScore {{
    computeScore(macros: macros, profile: profile)
  }}

  func replayReasoning(
    macros: RecipeMacros,
    split: (proteinPct: Double, carbsPct: Double, fatPct: Double)
  ) -> String {{
    buildReasoning(macros: macros, split: split)
  }}
  // SCAFFOLD-END
}}

// REPLAY-VENDORED-REGION-START {ids[3]}
{r[ids[3]]}
// REPLAY-VENDORED-REGION-END {ids[3]}

// REPLAY-VENDORED-REGION-START {ids[4]}
{r[ids[4]]}
// REPLAY-VENDORED-REGION-END {ids[4]}

// REPLAY-VENDORED-REGION-START {ids[5]}
{r[ids[5]]}
// REPLAY-VENDORED-REGION-END {ids[5]}

// REPLAY-VENDORED-REGION-START {ids[6]}
{r[ids[6]]}
// REPLAY-VENDORED-REGION-END {ids[6]}

public enum RecipeRepositoryReplay {{}}

extension RecipeRepositoryReplay {{
// REPLAY-VENDORED-REGION-START {ids[7]}
{r[ids[7]]}
// REPLAY-VENDORED-REGION-END {ids[7]}
}}
'''

    package_src = here / "SwiftReplay" / "Sources" / "ProductionReplay"
    package_src.mkdir(parents=True, exist_ok=True)
    (package_src / "VendoredScoring.swift").write_text(final, encoding="utf-8")
    (here / "RegionManifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"vendored {len(manifest['regions'])} regions -> Sources/ProductionReplay/VendoredScoring.swift")
    for reg in manifest["regions"]:
        print(f"  {reg['id']}: {reg['file']}:{reg['start_line']}-{reg['end_line']} {reg['sha256'][:12]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
