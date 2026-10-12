#!/usr/bin/env python3
"""Suite A (pantry-truth) — pantry fit-line truth bar on the CURRENT app code.

Measures, on the baseline production implementation:

  1. stock_counted_twice          bar == 0
     Plans (several dinners sharing a lot) replayed through the production
     fit; a finding is production calling every dinner makeable while the
     ledger shows the shared stock cannot cover them.
  2. sufficient_claimed_without_quantity_evidence   bar == 0
     Across the 200 audited (pantry, recipe) pairs: lines production counts
     as matched while the ledger has no quantity evidence behind them
     (short stock, scan-only presence, recognition-estimated amounts,
     stale evidence, bare assumptions).
  3. fit_line_text_correct_200    bar == 200 (of 200)
     Production's fit surface for each pair must state exactly the ledger's
     sufficiency count, never overclaim a complete match, and never render a
     percentage.

Inputs (grounding): the production bundled corpus apps/ios/Resources/
data.json and the USDA curated catalog under scripts/data/. Pantry
scenarios are synthetic, seeded (SEED in manifest_builder), and coherent
with real corpus quantities. No personal data, no network, no credentials.

The production fit subset is compiled with SwiftPM (13 verbatim production
files — see fitprobe/production_files.json) and the audit jobs are replayed
through the real RecipeRepository/RecommendationPolicy calls. If Swift or
the build is unavailable on this host, the affected metrics report not-run
with the precise reason — never skipped silently, never faked.

Per the programme plan (PLAN.md, scorecard section) suite A is property
tests plus a hand-labelled-style deterministic audit; there is NO LLM arm
in the design, so none is implemented or left unexecuted here.

Self-test: `suite.py --self-test` plants corrupted fixtures, flipped
labels, a lying emitter, tampered ledgers, probe-output tampering and
missing inputs, and asserts the derived status flips (or fails closed);
prints `caught k/k planted failures` and exits 0 only when all are caught.

Invocation (mirrors evaluation/run.py): suite.py --out <dir> --repo-root <dir>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SUITE_DIR = Path(__file__).resolve().parent
EVAL_DIR = SUITE_DIR.parent.parent
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))  # evaluation/ for suite_contract
if str(SUITE_DIR) not in sys.path:
    sys.path.insert(0, str(SUITE_DIR))

import manifest_builder  # noqa: E402
import fit_oracle  # noqa: E402
import suite_contract  # noqa: E402

RESULTS_SUITE_ID = "pantry-truth"

METRIC_DEFS = [
    ("stock_counted_twice", "Stock counted twice (plan battery)"),
    ("sufficient_claimed_without_quantity_evidence",
     "Sufficient claimed without quantity evidence (line audit over 200 pairs)"),
    ("fit_line_text_correct_200", "Fit-line text correct (200-pair audit)"),
]

PROBE_BUILD_TIMEOUT_S = 900
PROBE_RUN_TIMEOUT_S = 300


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _all_not_run(reason: str) -> dict:
    return {
        "suite": RESULTS_SUITE_ID,
        "run_at": _iso_now(),
        "metrics": [
            suite_contract.metric_not_run(mid, label, reason)
            for mid, label in METRIC_DEFS
        ],
    }


# ---------------------------------------------------------------------------
# Probe staging + build + run
# ---------------------------------------------------------------------------

def _swift_version() -> str | None:
    try:
        proc = subprocess.run(
            ["swift", "--version"], capture_output=True, text=True, timeout=60
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else None


def _stage_and_build(repo_root: Path) -> tuple[Path, dict, str | None]:
    """Stage the probe package and build it. Returns (binary path, provenance,
    failure reason). Exactly one of binary/reason is meaningful."""
    swift_ver = _swift_version()
    if swift_ver is None:
        return Path(), {}, "swift toolchain not available on this host; the production fit arms cannot run on Linux here"

    stage_root = Path(
        os.environ.get("FL_FITPROBE_CACHE_DIR", str(Path(tempfile.gettempdir()) / "fl-fitprobe-cache"))
    )

    spec = json.loads((SUITE_DIR / "fitprobe" / "production_files.json").read_text())
    inputs: list[tuple[str, bytes]] = []

    def _record(rel: str, data: bytes) -> None:
        inputs.append((rel, data))

    # Suite-owned probe sources.
    for rel in (
        "Package.swift",
        "Sources/FLFitProbe/main.swift",
        "Sources/SnapshotStubs/shim.c",
        "Sources/SnapshotStubs/include/shim.h",
    ):
        _record(f"probe/{rel}", (SUITE_DIR / "fitprobe" / rel).read_bytes())
    # Production sources: VERBATIM from the repo.
    prod_hashes: dict[str, str] = {}
    for entry in spec["files"]:
        src = repo_root / entry["path"]
        if not src.is_file():
            return Path(), {}, f"production source missing: {entry['path']}"
        data = src.read_bytes()
        _record(f"prod/{entry['path']}", data)
        prod_hashes[entry["path"]] = _sha256(data)
    vendored_src = repo_root / spec["vendored"][0]["path"]
    if not vendored_src.is_dir():
        return Path(), {}, f"vendored GRDB missing: {spec['vendored'][0]['path']}"
    for p in sorted(vendored_src.rglob("*")):
        if p.is_file():
            rel = p.relative_to(vendored_src)
            _record(f"grdb/{rel}", p.read_bytes())

    # Content-hash cache key over every staged byte.
    digest = hashlib.sha256()
    for rel, data in sorted(inputs):
        digest.update(rel.encode())
        digest.update(b"\0")
        digest.update(_sha256(data).encode())
        digest.update(b"\0")
    cache_key = digest.hexdigest()[:24]
    stage = stage_root / cache_key

    if not (stage / ".build" / "debug" / "FLFitProbe").is_file():
        if stage.exists():
            shutil.rmtree(stage)
        (stage / "Vendor").mkdir(parents=True, exist_ok=True)
        # Unpack recorded inputs.
        seen: set[str] = set()
        for rel, data in inputs:
            if rel.startswith("probe/"):
                dst = stage / rel[len("probe/"):]
            elif rel.startswith("prod/"):
                # Flatten production sources into the FLFitProduction target dir
                # (Swift targets don't care about intra-target subpaths).
                dst = stage / "Sources" / "FLFitProduction" / Path(rel).name
            elif rel.startswith("grdb/"):
                dst = stage / "Vendor" / "GRDB" / rel[len("grdb/"):]
            else:  # pragma: no cover
                raise RuntimeError(f"unlabelled staged input {rel}")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            seen.add(rel)
        # Package.swift references Vendor/GRDB; the vendored copy carries its
        # own nested Package.swift — confirm it was staged.
        if not (stage / "Vendor" / "GRDB" / "Package.swift").is_file():
            return Path(), {}, "vendored GRDB staged without its Package.swift"
        # Debug configuration: the probe imports the production module with
        # @testable, which SwiftPM enables only for debug builds
        # (-enable-testing). Production sources are staged verbatim either way.
        build = subprocess.run(
            ["swift", "build"], cwd=str(stage),
            capture_output=True, text=True, timeout=PROBE_BUILD_TIMEOUT_S,
        )
        if build.returncode != 0:
            combined = (build.stdout or "") + (build.stderr or "")
            errs = "\n".join(
                ln for ln in combined.splitlines() if "error" in ln.lower()
            ) or combined
            reason = f"swift build of the production fit subset failed:\n{errs[-1500:]}"
            return Path(), {}, reason

    binary = stage / ".build" / "debug" / "FLFitProbe"
    if not binary.is_file():
        return Path(), {}, "probe binary absent after swift build"
    provenance = {
        "stage": str(stage),
        "cache_key": cache_key,
        "swift": swift_ver,
        "production_files": prod_hashes,
        "verbatim": True,
        "manifest": "fitprobe/production_files.json",
    }
    return binary, provenance, None


def _pairs_job(manifest: dict) -> list[dict]:
    """Probe jobs for the 200 pairs. available_ids mirrors production's
    AppDependencies.swift:137-139 boundary: ingredient IDs behind physical
    inventory lots only (assumptions never join the fit)."""
    jobs = []
    for pair in manifest["pairs"]:
        ids = sorted({
            lot["ingredient_id"] for lot in pair["pantry"]["lots"]
            if (lot.get("remaining_grams") or 0) > 0
        })
        jobs.append({
            "pairId": pair["pair_id"],
            "recipeId": pair["recipe_id"],
            "availableIds": ids,
        })
    return jobs


def _plans_job(manifest: dict) -> tuple[list[dict], dict]:
    pantries = manifest_builder.plan_pantries(manifest)
    jobs = []
    for plan in manifest["plans"]:
        pan = pantries[plan["plan_id"]]
        jobs.append({
            "planId": plan["plan_id"],
            "recipeIds": plan["recipes"],
            "availableIds": pan["available_ids"],
        })
    return jobs, pantries


def _run_probe(binary: Path, job: dict, workdir: Path) -> tuple[dict | None, str | None]:
    job_path = workdir / "job.json"
    out_path = workdir / "probe_out.json"
    job_path.write_text(json.dumps(job))
    try:
        proc = subprocess.run(
            [str(binary), str(job_path), str(out_path)],
            capture_output=True, text=True, timeout=PROBE_RUN_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"probe execution failed: {exc}"
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "")[-1200:]
        return None, f"probe exited {proc.returncode}:\n{tail}"
    if not out_path.is_file():
        return None, "probe produced no output file"
    try:
        return json.loads(out_path.read_text()), None
    except json.JSONDecodeError as exc:
        return None, f"probe output is not valid JSON: {exc}"


# ---------------------------------------------------------------------------
# Audits
# ---------------------------------------------------------------------------

def audit_pairs(manifest: dict, probe_out: dict) -> tuple[dict, list[dict]]:
    """Metric 2 (line sufficiency claims) and metric 3 (pair text verdicts)."""
    rows_by_pair = {row["pairId"]: row for row in probe_out["pairs"]}
    verdicts = []
    bad_lines = 0
    bad_pairs_by_class: dict[str, list[str]] = {}
    bad_line_counts_by_class: dict[str, int] = {}
    for pair in manifest["pairs"]:
        ledger = fit_oracle.build_ledger(manifest, pair)
        fit_oracle.verify_ledger_against_corpus(manifest, ledger)  # corpus tripwire
        row = rows_by_pair.get(pair["pair_id"])
        if row is None:
            raise RuntimeError(f"probe output missing row for pair {pair['pair_id']}")
        fit_oracle.probe_row_invariants(_snake(row))
        verdict = fit_oracle.pair_verdict(manifest, ledger, _snake(row))
        verdicts.append({
            "pair_id": pair["pair_id"],
            "class": pair["class"],
            "recipe_id": pair["recipe_id"],
            "correct": verdict["correct"],
            "reasons": verdict["reasons"],
            "production": verdict["production"],
            "expected": verdict["expected"],
            "ledger_states": [l["state"] for l in ledger["lines"]],
            "sufficient_count": ledger["sufficient_count"],
            "total_required": ledger["total_required"],
        })

        # Metric 2: lines production counts as matched (rendered rows count
        # matched = total - missing via ID membership) without ledger evidence.
        if row.get("found"):
            missing_ids = set(row.get("missingIngredientIds", []))
            for line in ledger["lines"]:
                claimed = line["ingredient_id"] not in missing_ids
                if claimed and line["state"] not in fit_oracle.COUNTING_STATES:
                    bad_lines += 1
                    bad_line_counts_by_class[pair["class"]] = (
                        bad_line_counts_by_class.get(pair["class"], 0) + 1
                    )
                    bad_pairs_by_class.setdefault(pair["class"], []).append(
                        f"{pair['pair_id']}:{line['ingredient_id']}:{line['state']}"
                    )
    correct = sum(1 for v in verdicts if v["correct"])
    by_class: dict[str, dict] = {}
    for v in verdicts:
        slot = by_class.setdefault(v["class"], {"n": 0, "correct": 0})
        slot["n"] += 1
        slot["correct"] += 1 if v["correct"] else 0
    metrics = {
        "correct": correct,
        "total": len(verdicts),
        "by_class": by_class,
        "bad_lines": bad_lines,
        "bad_line_counts_by_class": bad_line_counts_by_class,
        "bad_pairs_by_class": {k: v[:12] for k, v in bad_pairs_by_class.items()},
        "bad_lines_total_examples": sum(len(v) for v in bad_pairs_by_class.values()),
    }
    return metrics, verdicts


def _snake(row: dict) -> dict:
    """Probe rows use camelCase (Swift Codable); the oracle speaks snake_case."""
    return {
        "pair_id": row.get("pairId"),
        "found": row.get("found", False),
        "tier": row.get("tier"),
        "matched_required": row.get("matchedRequired"),
        "total_required": row.get("totalRequired"),
        "matched_optional": row.get("matchedOptional"),
        "missing_required_count": row.get("missingRequiredCount"),
        "missing_ingredient_ids": row.get("missingIngredientIds", []),
        "ranking_reasons": row.get("rankingReasons", []),
    }


def audit_plans(manifest: dict, probe_out: dict) -> dict:
    """Metric 1: double-count findings across the plan battery."""
    rows_by_plan_recipe = {
        (r["planId"], r["recipeId"]): _snake(r) for r in probe_out["plans"]
    }
    missing_probe_rows = [
        {"plan_id": plan["plan_id"], "recipe_id": rid}
        for plan in manifest["plans"]
        for rid in plan["recipes"]
        if (plan["plan_id"], rid) not in rows_by_plan_recipe
    ]
    findings = []
    anomalies = []
    for plan in manifest["plans"]:
        rows = {
            rid: rows_by_plan_recipe.get((plan["plan_id"], rid), {"found": False})
            for rid in plan["recipes"]
        }
        res = fit_oracle.plan_double_count(manifest, plan, rows)
        entry = {k: res[k] for k in (
            "plan_id", "kind", "recipes", "shared_ingredient_id",
            "shared_remaining_grams", "combined_demand_grams", "coverable",
            "production_both_makeable", "double_count_finding")}
        if res["double_count_finding"]:
            findings.append(entry)
        if res["anomaly"]:
            anomalies.append({"plan_id": plan["plan_id"], "detail": res["anomaly"]})
    expected_plans = manifest_builder.PLAN_CURATED + manifest_builder.PLAN_RANDOM
    return {
        "findings": findings,
        "n_findings": len(findings),
        "n_plans": len(manifest["plans"]),
        "expected_plans": expected_plans,
        "battery_complete": len(manifest["plans"]) == expected_plans,
        "n_missing_probe_rows": len(missing_probe_rows),
        "missing_probe_rows": missing_probe_rows[:20],
        "anomalies": anomalies,
    }


# ---------------------------------------------------------------------------
# Suite entry point
# ---------------------------------------------------------------------------

def run_suite(repo_root: Path, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)

    # ---- Grounding (missing inputs fail closed to not-run) ----
    try:
        manifest = manifest_builder.build_manifest(repo_root)
    except manifest_builder.MissingInput as exc:
        payload = _all_not_run(f"grounding inputs unavailable: {exc}")
        suite_contract.write_results(out_dir, payload)
        return payload

    grounding = manifest["grounding"]
    usda = grounding["usda"]

    # ---- Production probe ----
    binary, provenance, fail_reason = _stage_and_build(repo_root)
    if fail_reason is not None:
        payload = _all_not_run(fail_reason)
        payload["toolchain"] = {"swift": provenance.get("swift") if provenance else None}
        suite_contract.write_results(out_dir, payload)
        return payload

    pair_jobs = _pairs_job(manifest)
    plan_jobs, _ = _plans_job(manifest)
    job = {
        "ingredients": [
            [float(i["id"]), float(i["calories"]), float(i["protein"]),
             float(i["carbs"]), float(i["fat"])]
            for i in manifest["ingredients"].values()
        ],
        "ingredientNames": [
            [float(i["id"]), i["name"], i["typical_unit"] or "", i["storage_tip"] or ""]
            for i in manifest["ingredients"].values()
        ],
        "recipes": [
            [float(r["id"]), r["title"], float(r["time_minutes"]), float(r["servings"]),
             [[float(l["ingredient_id"]), float(l["grams"])] for l in r["required"]],
             [[float(l["ingredient_id"]), float(l["grams"])] for l in r["optional"]],
             "Cook the ingredients as listed.", float(r.get("tags") or 0)]
            for r in manifest["recipes"].values()
        ],
        "pairs": pair_jobs,
        "plans": plan_jobs,
    }

    with tempfile.TemporaryDirectory(prefix="fl-pantry-truth-") as tmp:
        probe_out, probe_fail = _run_probe(binary, job, Path(tmp))
        if probe_fail is not None:
            payload = _all_not_run(probe_fail)
            payload["toolchain"] = {"swift": provenance["swift"]}
            suite_contract.write_results(out_dir, payload)
            return payload

    plans_audit = audit_plans(manifest, probe_out)
    pairs_audit, verdicts = audit_pairs(manifest, probe_out)

    low, high = fit_oracle.wilson_interval(pairs_audit["correct"], pairs_audit["total"])
    git_sha = None
    try:
        git_sha = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(repo_root),
            capture_output=True, text=True, timeout=30,
        ).stdout.strip() or None
    except Exception:  # pragma: no cover - provenance only
        git_sha = None

    battery_unsound = (
        not plans_audit["battery_complete"]
        or plans_audit["n_missing_probe_rows"] > 0
    )
    if battery_unsound:
        # A battery with missing rows reads absence as innocence: fail closed
        # to not-run with the precise reason, never pass silently.
        unsound = []
        if not plans_audit["battery_complete"]:
            unsound.append(
                f"plan battery incomplete: manifest built {plans_audit['n_plans']} "
                f"plan scenarios, the battery spec pins {plans_audit['expected_plans']}"
            )
        if plans_audit["n_missing_probe_rows"]:
            unsound.append(
                f"{plans_audit['n_missing_probe_rows']} plan-recipe probe rows missing "
                "from the probe output; a missing row reads as unmeasured, never as "
                "absence of a double count"
            )
        m1 = suite_contract.metric_not_run(
            METRIC_DEFS[0][0], METRIC_DEFS[0][1],
            "plan battery unsound, fail-closed: " + "; ".join(unsound),
        )
    else:
        m1 = suite_contract.metric(
            METRIC_DEFS[0][0], METRIC_DEFS[0][1],
            value=plans_audit["n_findings"], bar=suite_contract.eq(0),
            detail=(
                f"{plans_audit['n_plans']} plan scenarios (2 curated + "
                f"{plans_audit['n_plans'] - 2} seeded) replayed through the production fit; "
                f"each dinner asked independently, as production composes it "
                f"(RecommendationEngine.findRecipes; AppDependencies maps inventory lots "
                f"to IDs, quantities dropped). A finding = production calls both dinners "
                f"makeable while the shared lot cannot cover both. "
                f"{len(plans_audit['anomalies'])} anomalies."
            ),
            evidence={
                "n_findings_total": plans_audit["n_findings"],
                "findings_first_20": plans_audit["findings"][:20],
                "n_missing_probe_rows": plans_audit["n_missing_probe_rows"],
                "anomalies": plans_audit["anomalies"],
            },
        )
    m2 = suite_contract.metric(
        METRIC_DEFS[1][0], METRIC_DEFS[1][1],
        value=pairs_audit["bad_lines"], bar=suite_contract.eq(0),
        detail=(
            "Lines production counts as matched while the ledger has no quantity "
            "evidence behind them (short stock, scan-only presence, "
            "recognition-estimated amounts, stale evidence, bare assumptions). "
            f"True counts by class: {json.dumps(pairs_audit['bad_line_counts_by_class'])}. "
            f"Examples (capped at 12 per class): {json.dumps(pairs_audit['bad_pairs_by_class'])}"
        ),
        evidence={"by_class_counts": pairs_audit["bad_line_counts_by_class"]},
    )
    m3 = suite_contract.metric(
        METRIC_DEFS[2][0], METRIC_DEFS[2][1],
        value=pairs_audit["correct"], bar=suite_contract.eq(200),
        detail=(
            f"{pairs_audit['correct']} of {pairs_audit['total']} pairs correct. "
            f"By class: {json.dumps(pairs_audit['by_class'])}. Wilson 95% interval on "
            f"the proportion: [{low:.4f}, {high:.4f}] — carried here in detail and in "
            f"evidence.md because the contract (correctly) rejects intervals on "
            f"equality bars; the bar itself applies to the point value."
        ),
        evidence={"pairs_file": "pairs_200.json"},
    )

    payload = {
        "suite": RESULTS_SUITE_ID,
        "run_at": _iso_now(),
        "toolchain": {
            "swift": provenance["swift"],
            "python": sys.version.split()[0],
            "seed": manifest["seed"],
            "probe_stage": provenance["stage"],
            "probe_cache_key": provenance["cache_key"],
        },
        "revision": {"git_sha": git_sha},
        "grounding": {
            "corpus": grounding["corpus_path"],
            "corpus_sha256": grounding["corpus_sha256"],
            "corpus_note": grounding["note"],
            "usda": usda,
            "usda_path": grounding["usda_path"],
            "production_files_sha256": provenance["production_files"],
            "production_files_verbatim": True,
        },
        "metrics": [m1, m2, m3],
    }
    suite_contract.write_results(out_dir, payload)

    # ---- Evidence files (committed under evaluation/out/pantry-truth/) ----
    _write_evidence(out_dir, manifest, plans_audit, pairs_audit, verdicts, payload)
    return payload


def _write_evidence(
    out_dir: Path, manifest: dict, plans_audit: dict, pairs_audit: dict,
    verdicts: list[dict], payload: dict,
) -> None:
    (out_dir / "pairs_200.json").write_text(json.dumps({
        "suite": RESULTS_SUITE_ID,
        "seed": manifest["seed"],
        "verdicts": verdicts,
    }, indent=1))
    (out_dir / "manifest_summary.json").write_text(json.dumps({
        "grounding": payload["grounding"],
        "seed": manifest["seed"],
        "pair_class_mix": dict(manifest_builder.PAIR_CLASSES),
        "n_pairs": len(manifest["pairs"]),
        "n_plans": len(manifest["plans"]),
        "ingredients": len(manifest["ingredients"]),
        "recipes": len(manifest["recipes"]),
    }, indent=2))

    lines = []
    g = payload["grounding"]
    lines.append("# Suite A (pantry-truth) — audit evidence")
    lines.append("")
    lines.append(f"Run: {payload['run_at']} · seed {manifest['seed']} · "
                 f"corpus {g['corpus']} (sha256 {g['corpus_sha256'][:12]}…)")
    lines.append("")
    lines.append("## Grounding")
    lines.append("")
    lines.append(f"- Recipe corpus of record: `{g['corpus']}` — the production bundled corpus "
                 "the app loads (BundledDataLoader). The task brief named `assets/recipes.json`; "
                 "no such file exists on any branch of this repository.")
    usda = g["usda"]
    if usda.get("present"):
        lines.append(f"- USDA grounding (`{g['usda_path']}`): {usda['matched']} of "
                     f"{usda['total']} catalog ingredients matched against "
                     f"{usda['records']} USDA records (name-based, recorded only).")
    else:
        lines.append(f"- USDA grounding (`{g['usda_path']}`): catalog absent on this branch; "
                     "recorded, audit proceeds on the production corpus alone.")
    lines.append(f"- Production fit subset compiled verbatim (13 files, SHA256s in "
                 "results.json); replayed through the real RecipeRepository/RecommendationPolicy "
                 "calls on GRDB. Replicated boundary (cannot compile on Linux): "
                 "`AppDependencies.swift:137-139` — availableIds come from inventory lots only.")
    lines.append("- No LLM arm: the programme plan's suite A is property tests + the 200-pair "
                 "deterministic audit; none designed, none left unexecuted.")
    lines.append("")
    lines.append("## Metric 1 — stock counted twice (bar == 0)")
    lines.append("")
    lines.append(f"Findings: **{plans_audit['n_findings']}** of {plans_audit['n_plans']} plans. "
                 "A finding is production calling both dinners makeable from one shared lot "
                 "that cannot cover both (quantities are dropped at the AppDependencies "
                 "boundary; the fit matches by ingredient-ID membership). "
                 f"First {min(10, plans_audit['n_findings'])} of {plans_audit['n_findings']} shown:")
    for f in plans_audit["findings"][:10]:
        lines.append(f"- `{f['plan_id']}` ({f['kind']}): shared lot {f['shared_remaining_grams']} g "
                     f"vs combined demand {f['combined_demand_grams']} g — production: both makeable.")
    if plans_audit["anomalies"]:
        lines.append("")
        lines.append("Anomalies (production missed something the ledger covers):")
        for a in plans_audit["anomalies"][:10]:
            lines.append(f"- `{a['plan_id']}`: {a['detail']}")
    lines.append("")
    lines.append("## Metric 2 — sufficient claimed without quantity evidence (bar == 0)")
    lines.append("")
    lines.append(f"Offending line-instances across the 200 pairs: **{pairs_audit['bad_lines']}** "
                 "(production counts matched; ledger state short/quantity_unknown/"
                 "needs_reconfirming/assumed_staple/missing). True counts by class: "
                 f"{json.dumps(pairs_audit['bad_line_counts_by_class'])}. Examples "
                 f"(capped at 12 per class, {pairs_audit['bad_lines_total_examples']} shown): "
                 f"{json.dumps(pairs_audit['bad_pairs_by_class'])}")
    lines.append("")
    lines.append("## Metric 3 — fit-line text correct (bar == 200 of 200)")
    lines.append("")
    lines.append(f"Correct pairs: **{pairs_audit['correct']}** of {pairs_audit['total']}. "
                 "Correct = the rendered fit surface states exactly the ledger's sufficiency "
                 "count, never overclaims a complete match, and never shows a percentage. "
                 "Pairs production renders nothing for are incorrect (the fit truth is owed "
                 "on every card).")
    lines.append("")
    lines.append("| pair | class | ledger states | sufficient | production renders | expected (SPEC shape) | correct |")
    lines.append("|---|---|---|---|---|---|---|")
    for v in verdicts:
        states = ",".join(s[:12] for s in v["ledger_states"])
        prod = v["production"].replace("|", "\\|")
        exp = v["expected"].replace("|", "\\|")
        mark = "yes" if v["correct"] else "NO"
        lines.append(
            f"| {v['pair_id']} | {v['class']} | {states} | {v['sufficient_count']}/{v['total_required']} "
            f"| {prod} | {exp} | {mark} |")
    lines.append("")
    lines.append("Pair verdict rules: (1) claimed count == ledger sufficient count "
                 "(swap-covered lines count — SPEC: \"across lines, swaps, or several "
                 "dinners\"); (2) no complete-match claim while any line lacks quantity "
                 "evidence; (3) no percentage. All three must hold.")
    lines.append("")
    lines.append("Full per-pair records: `pairs_200.json`; machine results: `results.json`.")
    (out_dir / "evidence.md").write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Self-test: planted corruptions the scoring must catch.
# ---------------------------------------------------------------------------

def _mini_manifest(tmp: Path) -> dict:
    """A tiny deterministic corpus-root for audit-level plants (no Swift)."""
    (tmp / "apps" / "ios" / "Resources").mkdir(parents=True, exist_ok=True)
    ingredients = {
        "1": ["egg", 155, 13, 1.1, 11, 0, 0, 0, "1 large (50g)", "fridge"],
        "2": ["butter", 717, 0.9, 0.1, 81, 0, 0, 0, "100 g", "fridge"],
        "3": ["flour", 364, 10, 76, 1, 0, 0, 0, "1 kg", "dry"],
        "4": ["milk", 61, 3.2, 4.8, 3.3, 0, 0, 0, "1 L", "fridge"],
        "5": ["sugar", 387, 0, 100, 0, 0, 0, 0, "500 g", "dry"],
        "6": ["salt", 0, 0, 0, 0, 0, 0, 0, "500 g", "dry"],
    }
    recipes = [
        [1, "Pancakes", 15, 2, [[1, 100], [2, 30]], [[3, 50]], "Mix and fry.", 9],
        [2, "Cake", 40, 4, [[1, 100], [3, 200]], [[5, 100]], "Bake.", 9],
    ]
    (tmp / "apps" / "ios" / "Resources" / "data.json").write_text(
        json.dumps({"ingredients": ingredients, "recipes": recipes}))
    return manifest_builder.build_manifest(tmp)


def self_test() -> int:
    """Plant 6 corruptions; the suite's scoring must catch every one.

    Prints `caught k/k planted failures`; exits 0 only when all are caught.
    """
    caught = 0
    total = 6

    # Plant 1 — lying emitter: a metric that declares pass on a violated bar.
    # The contract must derive fail from value + bar (status is never trusted).
    liar = {"id": "m", "metric": "lying", "value": 7, "bar": {"op": "==", "value": 0},
            "status": "pass"}
    ok = suite_contract.derive_status(liar) == "fail"
    print(f"plant 1 lying-emitter: {'caught' if ok else 'UNCAUGHT'}")
    caught += ok

    with tempfile.TemporaryDirectory(prefix="fl-pantry-selftest-") as tmp_s:
        tmp = Path(tmp_s)
        manifest = _mini_manifest(tmp)

        # Plant 2 — flipped label / lying probe row: a pair whose ledger says a
        # line is short, with a tampered probe row claiming a complete match.
        pair = {"pair_id": "T1", "class": "short_by_quantity", "recipe_id": 1,
                "pantry": {"lots": [
                    {"ingredient_id": 1, "evidence_class": "purchased_lot",
                     "quantity_grams": 200, "remaining_grams": 200,
                     "quantity_is_estimate": 0, "source": "receipt", "age_days": 1},
                    {"ingredient_id": 2, "evidence_class": "purchased_lot_short",
                     "quantity_grams": 30, "remaining_grams": 9,
                     "quantity_is_estimate": 0, "source": "receipt", "age_days": 1},
                ], "assumptions": []}, "swap": None}
        ledger = fit_oracle.build_ledger(manifest, pair)
        lying_row = {"pair_id": "T1", "found": True, "tier": "exact",
                     "matched_required": 2, "total_required": 2,
                     "matched_optional": 0, "missing_required_count": 0,
                     "missing_ingredient_ids": [], "ranking_reasons": ["Complete match"]}
        verdict = fit_oracle.pair_verdict(manifest, ledger, lying_row)
        ok = (not verdict["correct"]) and any("overclaim" in r for r in verdict["reasons"])
        print(f"plant 2 lying-probe-row (complete match over a short line): "
              f"{'caught' if ok else 'UNCAUGHT'}")
        caught += ok

        # Plant 3 — tampered ledger: demand inflated vs the corpus it claims
        # to derive from. The corpus tripwire must raise.
        tampered = fit_oracle.build_ledger(manifest, pair)
        tampered["lines"][0]["demand_grams"] = 999.0
        ok = False
        try:
            fit_oracle.verify_ledger_against_corpus(manifest, tampered)
        except fit_oracle.LedgerError:
            ok = True
        print(f"plant 3 tampered-ledger (demand vs corpus): {'caught' if ok else 'UNCAUGHT'}")
        caught += ok

        # Plant 4 — probe-output tampering that breaks the structural
        # invariant (matched + missing == total).
        ok = False
        try:
            fit_oracle.probe_row_invariants({
                "pair_id": "T2", "found": True, "tier": "nearMatch",
                "matched_required": 3, "total_required": 6, "missing_required_count": 2,
                "missing_ingredient_ids": [7, 8], "ranking_reasons": []})
        except fit_oracle.LedgerError:
            ok = True
        print(f"plant 4 inconsistent-probe-output: {'caught' if ok else 'UNCAUGHT'}")
        caught += ok

    with tempfile.TemporaryDirectory(prefix="fl-pantry-selftest-") as tmp_s:
        tmp = Path(tmp_s)

        # Plant 5 — missing corpus: the suite must fail closed to not-run.
        out5 = tmp / "out5"
        payload = run_suite(tmp / "no-such-root", out5)
        ok = (
            len(payload["metrics"]) == 3
            and all(m["status"] == "not-run" and m.get("reason") for m in payload["metrics"])
        )
        print(f"plant 5 missing-corpus (not-run with reason): {'caught' if ok else 'UNCAUGHT'}")
        caught += ok

        # Plant 6 — empty recipes corpus: not-run, never pass.
        root = tmp / "empty-root"
        (root / "apps" / "ios" / "Resources").mkdir(parents=True, exist_ok=True)
        (root / "apps" / "ios" / "Resources" / "data.json").write_text(
            json.dumps({"ingredients": {"1": ["egg", 155, 13, 1.1, 11, 0, 0, 0, "u", "s"]},
                        "recipes": []}))
        payload = run_suite(root, tmp / "out6")
        ok = all(m["status"] == "not-run" and m.get("reason") for m in payload["metrics"])
        print(f"plant 6 empty-corpus (not-run with reason): {'caught' if ok else 'UNCAUGHT'}")
        caught += ok

    print(f"caught {caught}/{total} planted failures")
    return 0 if caught == total else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Suite A: pantry-truth")
    ap.add_argument("--out", default=None, help="output directory for results.json + evidence")
    ap.add_argument("--repo-root", default=None, help="repository root (read-only)")
    ap.add_argument("--self-test", action="store_true",
                    help="plant corruptions and verify the scoring catches them")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.out or not args.repo_root:
        ap.error("--out and --repo-root are required (unless --self-test)")
    payload = run_suite(Path(args.repo_root).resolve(), Path(args.out).resolve())
    summary = ", ".join(
        "%s=%s" % (m["id"], m["status"]) for m in payload["metrics"]
    )
    print("pantry-truth: %s" % summary)
    return 0  # exit 0 whenever honest results were written (statuses may be fail)


if __name__ == "__main__":
    sys.exit(main())
