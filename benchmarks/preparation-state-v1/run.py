#!/usr/bin/env python3
"""Run preparation-state-v1 arms over the frozen manifest.

Arms
----
pinned_cpu_baseline
    Deterministic, CPU-only state-blind baseline over the pinned catalog:
    production-family candidate normalization (lowercase, de-pluralize, strip
    leading fresh/raw/cooked/frozen/dried) followed by unique exact / prefix
    matching. No lexicon, no state awareness. The environment (CPU model,
    Python, SQLite) is pinned into the report.
production_replay
    Read-only text replay of the production resolution stack, using the
    differential-verified port at
    experiments/ingredient-recognition/resolution/app_resolution.py, which
    mirrors IngredientLexicon.swift, IngredientCatalogResolver.swift, and
    IngredientIdentityResolution.swift against the same SQLite file the app
    ships. Nothing in production is imported at runtime or modified.
swift_replay
    The same probes through the real Swift sources (SwiftReplay package).
    Executed in this environment when a Swift toolchain is available: the
    production IngredientLexicon.swift is synced verbatim, its XCTests run,
    and every probe is replayed through the compiled swift-replay executable.
    The full GRDB-backed catalog resolver is NOT replayable in Swift here
    (needs GRDB 7.x and the app host) — recorded as an unrun check.
preparation_candidate_selection
    DISTINCT candidate-selection arm using the preparation intent the probe
    text states (leading raw/cooked/dried/frozen/canned surface word):
    resolve identity state-blind, then select among the resolved group's
    members by the stated state. Unknown-state abstention: a stated intent no
    member carries, an ambiguous alternative, or an unresolved identity
    abstains instead of guessing. Evaluated per record with source/group-
    held-out slices (the group is the held-out unit; the test split scores
    fully held-out groups). Unlike heldout_alternative, this arm never
    returns a record for an intent the resolved group does not carry.

Read-only guarantees: the catalog is opened mode=ro by the port; this script
only reads the manifest and writes to benchmarks/preparation-state-v1/results.

Run: python3 run.py --out results
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time
from importlib import util as importlib_util
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parent
REPO_ROOT = BENCH_ROOT.parents[1]
CATALOG_PATH = REPO_ROOT / "apps" / "ios" / "Resources" / "usda_ingredient_catalog.sqlite"
PORT_PATH = (
    REPO_ROOT
    / "experiments"
    / "ingredient-recognition"
    / "resolution"
    / "app_resolution.py"
)

NUTRIENTS = ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def environment() -> dict:
    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "cpu_model": cpu_model(),
        "sqlite_version": sqlite3.sqlite_version,
        "catalog_sha256": sha256_file(CATALOG_PATH),
    }


def load_port():
    """Import the differential-verified resolution port read-only."""
    spec = importlib_util.spec_from_file_location("prep_state_app_resolution", PORT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load port from {PORT_PATH}")
    module = importlib_util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------
# Arm: swift_replay (real IngredientLexicon.swift, executed when a toolchain exists)
# --------------------------------------------------------------------------

SWIFT_REPLAY_DIR = BENCH_ROOT / "SwiftReplay"

# Known toolchain locations tried after `which swift` (the benchmark sandbox
# installs the Swift toolchain here without putting it on PATH).
_SWIFT_FALLBACKS = (
    "/home/user/swift612/usr/bin/swift",
    "/home/user/work/swift-toolchain/usr/bin/swift",
)


class SwiftReplayError(RuntimeError):
    pass


def discover_swift() -> dict | None:
    """Locate a usable Swift toolchain; return {"binary", "version"} or None."""
    candidates = [shutil.which("swift")] + [
        p for p in _SWIFT_FALLBACKS if Path(p).exists()
    ]
    for binary in candidates:
        if not binary:
            continue
        try:
            proc = subprocess.run(
                [binary, "--version"], capture_output=True, text=True, timeout=60
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if proc.returncode == 0:
            return {"binary": binary, "version": proc.stdout.splitlines()[0].strip()}
    return None


def execute_swift_replay(probes: list[dict], swift: dict, out_dir: Path) -> dict:
    """Build, test, and run the SwiftReplay package over the probes.

    Executes the REAL production IngredientLexicon.swift (synced verbatim by
    scripts/sync_production_sources.sh), runs its XCTests, then replays every
    probe through the compiled swift-replay executable. Raises SwiftReplayError
    on any failure; the caller records the arm as unrun with the reason.
    """
    sync = subprocess.run(
        ["sh", str(SWIFT_REPLAY_DIR / "scripts" / "sync_production_sources.sh")],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if sync.returncode != 0:
        raise SwiftReplayError(
            f"source sync failed: {(sync.stderr or sync.stdout)[-400:]}"
        )

    tests = subprocess.run(
        [swift["binary"], "test", "--package-path", str(SWIFT_REPLAY_DIR)],
        capture_output=True,
        text=True,
        timeout=1800,
    )
    if tests.returncode != 0:
        raise SwiftReplayError(
            f"swift test failed (exit {tests.returncode}): "
            f"{(tests.stderr or tests.stdout)[-400:]}"
        )
    test_match = re.search(r"Executed (\d+) tests?, with (\d+) failures?", tests.stdout)
    if test_match is None:
        raise SwiftReplayError("could not parse swift test summary")
    test_summary = {"executed": int(test_match.group(1)), "failures": int(test_match.group(2))}
    if test_summary["failures"] != 0:
        raise SwiftReplayError(f"swift test failures: {test_summary}")

    probes_path = out_dir / "swift_probes.jsonl"
    probes_path.write_text(
        "".join(
            json.dumps({"probe_id": p["probe_id"], "text": p["text"]}, sort_keys=True) + "\n"
            for p in probes
        )
    )
    raw_path = out_dir / "swift_lexicon_replay.jsonl"
    with probes_path.open() as fin, raw_path.open("w") as fout:
        run = subprocess.run(
            [
                swift["binary"],
                "run",
                "--package-path",
                str(SWIFT_REPLAY_DIR),
                "swift-replay",
            ],
            stdin=fin,
            stdout=fout,
            stderr=subprocess.PIPE,
            text=True,
            timeout=1800,
        )
    probes_path.unlink()
    if run.returncode != 0:
        raise SwiftReplayError(
            f"swift-replay failed (exit {run.returncode}): {run.stderr[-400:]}"
        )

    parsed: dict[str, dict] = {}
    for line in raw_path.read_text().splitlines():
        rec = json.loads(line)
        if rec.get("probe_id") is None or rec.get("error"):
            raise SwiftReplayError(f"undecodable replay line: {line[:120]}")
        parsed[rec["probe_id"]] = rec
    if len(parsed) != len(probes):
        raise SwiftReplayError(f"replay covered {len(parsed)} of {len(probes)} probes")
    return {"predictions": parsed, "test_summary": test_summary}


# --------------------------------------------------------------------------
# Arm: preparation_candidate_selection (stated preparation intent, distinct arm)
# --------------------------------------------------------------------------


def stated_preparation_intent(
    text: str, surface_words: dict[str, str]
) -> tuple[str | None, str]:
    """Extract the stated preparation intent from the leading surface word.

    Returns (canonical_intent_or_None, remaining_text). Only a leading,
    whitespace-delimited surface word counts as *stated* — the arm must not
    infer state from anything the text does not say.
    """
    lowered = text.lower().strip()
    parts = lowered.split(None, 1)
    if not parts:
        return None, text
    canonical = surface_words.get(parts[0])
    if canonical is None:
        return None, text
    remaining = parts[1].strip() if len(parts) > 1 else ""
    return canonical, remaining


def run_candidate_selection(
    text: str, ctx: dict
) -> tuple[int | None, str, str, str | None]:
    """Select one candidate record using the text's stated preparation intent.

    Distinct from heldout_alternative: that arm scores the unchanged production
    resolver on its probes; this arm resolves identity state-blind, then
    *selects among the resolved group's members* using the preparation intent
    the probe text states. Unknown-state abstention: a stated intent no member
    carries, an ambiguous alternative, or an unresolved identity abstains
    instead of guessing. Returns (record_id_or_None, provenance, basis, intent).
    """
    intent, base_text = stated_preparation_intent(text, ctx["surface_words"])
    if not base_text:
        return None, "none", "no_base_text", intent
    resolved = ctx["port"].resolve_label(base_text, ctx["lexicon"], ctx["resolver"])
    if resolved is not None:
        rid = resolved.ingredient_id
    else:
        rid = ctx["port"].resolve_text_from_catalog(
            base_text, ctx["lexicon"], ctx["resolver"]
        )
    if rid is None:
        return None, "none", "identity_unresolved", intent
    group_id = ctx["id_to_group"].get(rid)
    if group_id is None:
        # Curated-lexicon hit: no catalog group to select within, and the
        # curated record carries no preparation states. With no stated intent
        # the curated identity stands; with one stated, the arm cannot honor
        # it and must abstain rather than return a stateless record.
        if intent is None:
            return rid, "curated", "curated_lexicon_direct", intent
        return None, "none", "unsupported_intent_abstain", intent
    members = ctx["groups_by_base"][group_id]["members"]
    if intent is None:
        if len(members) == 1:
            return (
                members[0]["catalog_id"],
                "candidate_selection",
                "single_member_identity",
                intent,
            )
        return None, "none", "intent_required_on_alternatives", intent
    matching = [m for m in members if intent in m["states"]]
    if len(matching) == 1:
        return (
            matching[0]["catalog_id"],
            "candidate_selection",
            "stated_state_member",
            intent,
        )
    if len(matching) > 1:
        return None, "none", "ambiguous_state_members", intent
    return None, "none", "unsupported_intent_abstain", intent


def catalog_rows() -> dict[int, dict]:
    conn = sqlite3.connect(f"file:{CATALOG_PATH}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT id, name, calories, protein, carbs, fat, fiber, sugar, sodium FROM ingredients"
        ).fetchall()
    finally:
        conn.close()
    return {
        r[0]: {"name": r[1], "per100g": dict(zip(NUTRIENTS, r[2:]))} for r in rows
    }


# --------------------------------------------------------------------------
# Arm: pinned_cpu_baseline (state-blind unique-match over the pinned catalog)
# --------------------------------------------------------------------------

_STOPWORDS = ("fresh", "raw", "cooked", "frozen", "dried")


def baseline_normalize(raw: str) -> list[str]:
    base = raw.lower().replace("_", " ")
    parts = [p for p in re.split(r"[^0-9a-z]+", base) if p]
    base = " ".join(parts).strip()
    candidates = [base]
    if base.endswith("ies") and len(base) > 4:
        candidates.append(base[:-3] + "y")
    elif base.endswith("es") and len(base) > 3:
        candidates.append(base[:-2])
    elif base.endswith("s") and len(base) > 2:
        candidates.append(base[:-1])
    for word in _STOPWORDS:
        prefix = word + " "
        if base.startswith(prefix):
            candidates.append(base[len(prefix):])
    deduped: list[str] = []
    seen: set[str] = set()
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            deduped.append(c)
    return deduped


class BaselineCatalog:
    """Unique-match catalog baseline; mirrors production's unique-or-abstain rule."""

    def __init__(self, rows: dict[int, dict]) -> None:
        names: dict[str, list[int]] = {}
        for rid, row in rows.items():
            names.setdefault(row["name"].lower(), []).append(rid)
        self._names = names

    @staticmethod
    def _unique(ids: list[int]) -> int | None:
        uniq = sorted(set(ids))
        return uniq[0] if len(uniq) == 1 else None

    def resolve(self, raw: str) -> int | None:
        candidates = baseline_normalize(raw)
        if not candidates:
            return None
        for c in candidates:  # unique exact name
            hit = self._unique(self._names.get(c, []))
            if hit is not None:
                return hit
        # unique prefix name (candidate length >= 5, like production)
        for c in candidates:
            if len(c) < 5:
                continue
            prefix_hits = [
                rid for name, ids in self._names.items() if name.startswith(c) for rid in ids
            ]
            hit = self._unique(prefix_hits)
            if hit is not None:
                return hit
        return None


# --------------------------------------------------------------------------
# Arms over probes
# --------------------------------------------------------------------------


def run_probe(arm: str, text: str, ctx: dict) -> tuple[int | None, str, float]:
    """Return (predicted_record_id_or_None, provenance, elapsed_ms)."""
    t0 = time.perf_counter_ns()
    if arm == "pinned_cpu_baseline":
        rid = ctx["baseline"].resolve(text)
        prov = "catalog" if rid is not None else "none"
    elif arm == "production_replay":
        resolved = ctx["port"].resolve_label(text, ctx["lexicon"], ctx["resolver"])
        if resolved is not None:
            rid, prov = resolved.ingredient_id, resolved.provenance
        else:
            rid = ctx["port"].resolve_text_from_catalog(text, ctx["lexicon"], ctx["resolver"])
            prov = "catalog" if rid is not None else "none"
    elif arm == "heldout_alternative":
        # Same production resolver as production_replay; the arm differs only in
        # which probes are scored (held-out multi-alternative test groups).
        resolved = ctx["port"].resolve_label(text, ctx["lexicon"], ctx["resolver"])
        if resolved is not None:
            rid, prov = resolved.ingredient_id, resolved.provenance
        else:
            rid = ctx["port"].resolve_text_from_catalog(text, ctx["lexicon"], ctx["resolver"])
            prov = "catalog" if rid is not None else "none"
    else:
        raise ValueError(arm)
    elapsed_ms = (time.perf_counter_ns() - t0) / 1e6
    return rid, prov, elapsed_ms


def classify(
    prediction: int | None,
    probe: dict,
    group_of_probe: str,
    id_to_group: dict[int, str],
    usda_ids: set[int],
) -> str:
    """Outcome classes. Uses only probe metadata and prediction provenance —
    never the target's state or name as an inference input."""
    target = probe["target"]
    fam = probe["family"]
    if fam == "unknown_state":
        if prediction is None:
            return "correct_abstain"
        if id_to_group.get(prediction) == group_of_probe:
            return "wrong_state"
        return "wrong_identity"
    if prediction is None:
        return "abstain"
    if prediction not in usda_ids:
        return "curated_cross"  # curated 50-ingredient catalog answer, no USDA record id
    if prediction == target["record_id"]:
        return "correct"
    if id_to_group.get(prediction) == group_of_probe:
        return "wrong_state"
    return "wrong_identity"


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(q * len(ordered)))
    return ordered[idx]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(BENCH_ROOT / "results" / "text_arms"))
    ap.add_argument("--manifest", default=str(BENCH_ROOT / "manifest.json"))
    ap.add_argument(
        "--arms",
        default="pinned_cpu_baseline,production_replay,swift_replay,"
        "heldout_alternative,preparation_candidate_selection",
    )
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(Path(args.manifest).read_text())
    probes = manifest["probes"]
    groups_by_base = {g["group_id"]: g for g in manifest["groups"]}
    surface_words = manifest["provenance"]["surface_words"]

    rows = catalog_rows()
    usda_ids = set(rows)
    id_to_group: dict[int, str] = {}
    for g in manifest["groups"]:
        for m in g["members"]:
            id_to_group[m["catalog_id"]] = g["group_id"]

    arms_requested = [a.strip() for a in args.arms.split(",") if a.strip()]
    env = environment()
    manifest_sha = sha256_file(Path(args.manifest))

    ctx: dict = {
        "surface_words": surface_words,
        "groups_by_base": groups_by_base,
        "id_to_group": id_to_group,
    }
    arm_status: dict[str, str] = {}
    if "pinned_cpu_baseline" in arms_requested:
        ctx["baseline"] = BaselineCatalog(rows)
    if (
        "production_replay" in arms_requested
        or "heldout_alternative" in arms_requested
        or "preparation_candidate_selection" in arms_requested
    ):
        port = load_port()
        ctx["lexicon"] = port.IngredientLexicon()
        ctx["resolver"] = port.IngredientCatalogResolver()
        ctx["port"] = port

    # Swift replay: executed for real when a toolchain is available. The raw
    # per-probe output and the XCTest summary are recorded; what the package
    # cannot replay stays an explicitly unrun check in the report.
    swift_artifacts_dir = out.parent / "swift_replay"
    swift_meta: dict | None = None
    if "swift_replay" in arms_requested:
        swift = discover_swift()
        if swift is None:
            arm_status["swift_replay"] = (
                "unrun: swift toolchain unavailable in this environment"
            )
        else:
            try:
                swift_artifacts_dir.mkdir(parents=True, exist_ok=True)
                executed = execute_swift_replay(probes, swift, swift_artifacts_dir)
                ctx["swift_predictions"] = executed["predictions"]
                swift_meta = {
                    "binary": swift["binary"],
                    "swift_version": swift["version"],
                    "xctests": executed["test_summary"],
                    "raw_output": str(
                        swift_artifacts_dir / "swift_lexicon_replay.jsonl"
                    ),
                }
                arm_status["swift_replay"] = (
                    "ran: real IngredientLexicon.swift replay on "
                    f"{swift['version']} (xctests "
                    f"{executed['test_summary']['executed']} executed, "
                    f"{executed['test_summary']['failures']} failures)"
                )
            except SwiftReplayError as error:
                arm_status["swift_replay"] = f"unrun: {error}"

    predictions_path = out / "predictions.jsonl"
    all_records: list[dict] = []
    wall_start = time.perf_counter()
    for arm in arms_requested:
        if arm == "swift_replay":
            if "swift_predictions" not in ctx:
                continue  # unrun arm; status recorded in the report
            for probe in probes:
                replay = ctx["swift_predictions"].get(probe["probe_id"])
                if replay is None:
                    raise RuntimeError(f"swift replay missing probe {probe['probe_id']}")
                rid = int(replay["resolved_id"]) if replay.get("resolved_id") else None
                group_of_probe = probe["probe_id"].split("::", 1)[0]
                all_records.append(
                    {
                        "arm": arm,
                        "probe_id": probe["probe_id"],
                        "family": probe["family"],
                        "split": probe["split"],
                        "text": probe["text"],
                        "target_record_id": probe["target"]["record_id"],
                        "target_state": probe["target"]["state"],
                        "predicted_record_id": rid,
                        "provenance": (
                            "curated_lexicon_swift" if rid is not None else "none"
                        ),
                        "elapsed_ms": None,  # no per-probe timing across the process boundary
                        "outcome": classify(rid, probe, group_of_probe, id_to_group, usda_ids),
                    }
                )
            continue
        if arm == "preparation_candidate_selection":
            # Stated-intent candidate selection: per-record outputs carry the
            # stated intent and the selection basis, so every decision (and
            # every abstention) is auditable row by row.
            for probe in probes:
                rid, prov, basis, intent = run_candidate_selection(probe["text"], ctx)
                group_of_probe = probe["probe_id"].split("::", 1)[0]
                all_records.append(
                    {
                        "arm": arm,
                        "probe_id": probe["probe_id"],
                        "family": probe["family"],
                        "split": probe["split"],
                        "text": probe["text"],
                        "target_record_id": probe["target"]["record_id"],
                        "target_state": probe["target"]["state"],
                        "predicted_record_id": rid,
                        "provenance": prov,
                        "elapsed_ms": None,
                        "stated_intent": intent,
                        "selection_basis": basis,
                        "outcome": classify(rid, probe, group_of_probe, id_to_group, usda_ids),
                    }
                )
            continue
        if arm == "heldout_alternative":
            # Held-out preparation alternatives: only probes on TEST-split groups
            # that have >= 2 distinct records (state alternatives). The arm asks
            # whether the resolver can pick the correct alternative record when
            # the group identity is held out of anything tunable — same resolver
            # behavior as production_replay, different scoring slice.
            for probe in probes:
                grp = groups_by_base[probe["probe_id"].split("::", 1)[0]]
                if probe["split"] != "test" or len(grp["members"]) < 2:
                    continue
                rid, prov, elapsed = run_probe(arm, probe["text"], ctx)
                group_of_probe = probe["probe_id"].split("::", 1)[0]
                rec = {
                    "arm": arm,
                    "probe_id": probe["probe_id"],
                    "family": probe["family"],
                    "split": probe["split"],
                    "text": probe["text"],
                    "target_record_id": probe["target"]["record_id"],
                    "target_state": probe["target"]["state"],
                    "predicted_record_id": rid,
                    "provenance": prov,
                    "elapsed_ms": round(elapsed, 4),
                    "outcome": classify(rid, probe, group_of_probe, id_to_group, usda_ids),
                }
                all_records.append(rec)
            continue
        for probe in probes:
            rid, prov, elapsed = run_probe(arm, probe["text"], ctx)
            group_of_probe = probe["probe_id"].split("::", 1)[0]
            rec = {
                "arm": arm,
                "probe_id": probe["probe_id"],
                "family": probe["family"],
                "split": probe["split"],
                "text": probe["text"],
                "target_record_id": probe["target"]["record_id"],
                "target_state": probe["target"]["state"],
                "predicted_record_id": rid,
                "provenance": prov,
                "elapsed_ms": round(elapsed, 4),
                "outcome": classify(rid, probe, group_of_probe, id_to_group, usda_ids),
            }
            all_records.append(rec)
    wall_s = time.perf_counter() - wall_start

    with predictions_path.open("w") as f:
        for rec in all_records:
            f.write(json.dumps(rec, sort_keys=True) + "\n")

    unrun_checks: list[dict] = [
        {
            "check": "swift_full_resolver_replay",
            "reason": (
                "IngredientCatalogResolver requires GRDB 7.x and the app host; "
                "replaying it in Swift needs a macOS harness (see "
                "SwiftReplay/README.md). Its behavior is covered by the "
                "read-only Python production_replay arm."
            ),
        },
        {
            "check": "foodseg103_preparation_accuracy",
            "reason": (
                "FoodSeg103 has no preparation-state labels; preparation "
                "accuracy is not scoreable and is not scored in the image arm."
            ),
        },
    ]
    actual_checks: list[dict] = []
    if swift_meta is not None:
        actual_checks.append(
            {
                "check": "swift_lexicon_replay",
                "detail": (
                    "real IngredientLexicon.swift replayed over "
                    f"{len(probes)} probes; XCTests "
                    f"{swift_meta['xctests']['executed']} executed, "
                    f"{swift_meta['xctests']['failures']} failures"
                ),
                "toolchain": {
                    "binary": swift_meta["binary"],
                    "version": swift_meta["swift_version"],
                },
            }
        )
    else:
        unrun_checks.append(
            {
                "check": "swift_lexicon_replay",
                "reason": arm_status.get("swift_replay", "unrun"),
            }
        )

    report: dict = {
        "benchmark": manifest["benchmark"],
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": env,
        "manifest_sha256": manifest_sha,
        "predictions_sha256": sha256_file(predictions_path),
        "arm_status": arm_status,
        "wall_seconds": round(wall_s, 3),
        "execution": {
            "actual_checks": actual_checks,
            "unrun_checks": unrun_checks,
        },
        "arms": {},
    }

    for arm in arms_requested:
        if arm == "swift_replay" and swift_meta is None:
            report["arms"][arm] = {"status": arm_status.get(arm, "unrun"), "ran": False}
            continue
        recs = [r for r in all_records if r["arm"] == arm]
        arm_report: dict = {"ran": True, "probe_count": len(recs)}
        if arm == "swift_replay":
            arm_report["swift_replay_meta"] = swift_meta
        outcomes: dict[str, int] = {}
        for r in recs:
            outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
        arm_report["outcomes"] = dict(sorted(outcomes.items()))
        per_family = {}
        for fam in ("identity", "state", "unknown_state"):
            fr = [r for r in recs if r["family"] == fam]
            if not fr:
                continue
            per_family[fam] = {
                "n": len(fr),
                "correct_incl_abstain": sum(
                    1 for r in fr if r["outcome"] in ("correct", "correct_abstain")
                ),
                "abstain": sum(1 for r in fr if r["outcome"] == "abstain"),
                "wrong_state": sum(1 for r in fr if r["outcome"] == "wrong_state"),
                "wrong_identity": sum(1 for r in fr if r["outcome"] == "wrong_identity"),
                "curated_cross": sum(1 for r in fr if r["outcome"] == "curated_cross"),
            }
        arm_report["per_family"] = per_family
        if arm == "heldout_alternative":
            multi = [r for r in recs if r["family"] in ("state", "unknown_state")]
            arm_report["alternative_selection"] = {
                "probes_on_multi_member_test_groups": len(multi),
                "group_correct": sum(
                    1 for r in multi if r["outcome"] not in ("abstain", "wrong_identity", "curated_cross")
                ),
                "exact_record": sum(1 for r in multi if r["outcome"] == "correct"),
                "state_family_exact": sum(
                    1 for r in multi if r["family"] == "state" and r["outcome"] == "correct"
                ),
                "state_family_wrong_state": sum(
                    1 for r in multi if r["family"] == "state" and r["outcome"] == "wrong_state"
                ),
                "unknown_state_correct_abstain": sum(
                    1
                    for r in multi
                    if r["family"] == "unknown_state" and r["outcome"] == "correct_abstain"
                ),
                "unknown_state_wrong_state": sum(
                    1 for r in multi if r["family"] == "unknown_state" and r["outcome"] == "wrong_state"
                ),
            }

        if arm == "preparation_candidate_selection":
            # Group-held-out evaluation: every probe of a group shares the
            # group's split, so the test slice evaluates groups fully held out
            # of train/dev. The manifest carries no source labels; the group is
            # the held-out unit.
            arm_report["held_out_unit"] = (
                "group — each group's probes all share its split; the test "
                "slice evaluates groups held out from train/dev"
            )
            per_split: dict[str, dict] = {}
            for split in ("train", "dev", "test"):
                sr = [r for r in recs if r["split"] == split]
                if not sr:
                    continue
                oc: dict[str, int] = {}
                for r in sr:
                    oc[r["outcome"]] = oc.get(r["outcome"], 0) + 1
                per_split[split] = {
                    "n": len(sr),
                    "outcomes": dict(sorted(oc.items())),
                    "exact_rate": round(
                        sum(1 for r in sr if r["outcome"] == "correct") / len(sr), 4
                    ),
                }
            arm_report["per_split"] = per_split
            basis_counts: dict[str, int] = {}
            for r in recs:
                basis_counts[r["selection_basis"]] = (
                    basis_counts.get(r["selection_basis"], 0) + 1
                )
            arm_report["selection_basis"] = dict(sorted(basis_counts.items()))
            intent_counts: dict[str, int] = {}
            for r in recs:
                key = (
                    r["stated_intent"]
                    if r["stated_intent"] is not None
                    else "none_stated"
                )
                intent_counts[key] = intent_counts.get(key, 0) + 1
            arm_report["intent_counts"] = dict(sorted(intent_counts.items()))

        times = [r["elapsed_ms"] for r in recs if r["elapsed_ms"] is not None]
        arm_report["timing_ms"] = {
            "p50": round(percentile(times, 0.50), 4),
            "p95": round(percentile(times, 0.95), 4),
            "mean": round(statistics.fmean(times), 4) if times else 0.0,
        }
        state_confusion: dict[str, int] = {}
        for r in recs:
            if r["outcome"] != "wrong_state":
                continue
            pred_states = ["stateless"]
            pred_group = id_to_group.get(r["predicted_record_id"])
            if pred_group:
                for m in groups_by_base[pred_group]["members"]:
                    if m["catalog_id"] == r["predicted_record_id"] and m["states"]:
                        pred_states = m["states"]
            key = f"{r['target_state']}->{','.join(pred_states)}"
            state_confusion[key] = state_confusion.get(key, 0) + 1
        if state_confusion:
            arm_report["state_confusion"] = dict(
                sorted(state_confusion.items(), key=lambda kv: -kv[1])
            )
        report["arms"][arm] = arm_report

    report_path = out / "report.json"
    report_path.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")

    print(json.dumps({k: v for k, v in report.items() if k != "environment"}, indent=1)[:4000])
    print(f"wrote {predictions_path} and {report_path}")
    if "swift_replay" in arms_requested and swift_meta is None:
        print(f"swift_replay: {arm_status.get('swift_replay', 'unrun')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
