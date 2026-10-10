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
    Recorded as an unrun arm when no Swift toolchain is available.

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
    ap.add_argument("--out", default=str(BENCH_ROOT / "results"))
    ap.add_argument("--manifest", default=str(BENCH_ROOT / "manifest.json"))
    ap.add_argument("--arms", default="pinned_cpu_baseline,production_replay,swift_replay")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(Path(args.manifest).read_text())
    probes = manifest["probes"]
    groups_by_base = {g["group_id"]: g for g in manifest["groups"]}

    rows = catalog_rows()
    usda_ids = set(rows)
    id_to_group: dict[int, str] = {}
    for g in manifest["groups"]:
        for m in g["members"]:
            id_to_group[m["catalog_id"]] = g["group_id"]

    arms_requested = [a.strip() for a in args.arms.split(",") if a.strip()]
    env = environment()
    manifest_sha = sha256_file(Path(args.manifest))

    ctx: dict = {}
    arm_status: dict[str, str] = {}
    if "pinned_cpu_baseline" in arms_requested:
        ctx["baseline"] = BaselineCatalog(rows)
    if "production_replay" in arms_requested:
        port = load_port()
        ctx["lexicon"] = port.IngredientLexicon()
        ctx["resolver"] = port.IngredientCatalogResolver()
        ctx["port"] = port
    swift_path = shutil.which("swift")
    if "swift_replay" in arms_requested:
        if swift_path:
            arm_status["swift_replay"] = (
                "toolchain present but runner requires macOS host: unrun here"
            )
        else:
            arm_status["swift_replay"] = "unrun: swift toolchain unavailable in this environment"

    predictions_path = out / "predictions.jsonl"
    all_records: list[dict] = []
    wall_start = time.perf_counter()
    for arm in arms_requested:
        if arm == "swift_replay":
            continue  # unrun arm; status recorded in the report
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

    report: dict = {
        "benchmark": manifest["benchmark"],
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": env,
        "manifest_sha256": manifest_sha,
        "predictions_sha256": sha256_file(predictions_path),
        "arm_status": arm_status,
        "wall_seconds": round(wall_s, 3),
        "arms": {},
    }

    for arm in arms_requested:
        if arm == "swift_replay":
            report["arms"][arm] = {"status": arm_status.get(arm, "unrun"), "ran": False}
            continue
        recs = [r for r in all_records if r["arm"] == arm]
        arm_report: dict = {"ran": True, "probe_count": len(recs)}
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
        times = [r["elapsed_ms"] for r in recs]
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
    if swift_path is None:
        print("swift_replay: UNRUN (swift toolchain unavailable) — run SwiftReplay on macOS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
