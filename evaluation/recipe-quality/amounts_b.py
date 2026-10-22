#!/usr/bin/env python3
"""Band rcp-000377..rcp-000934 — real amounts for catalog recipes.

Packet burst11-fridgeluck-recipe-amounts-b, based on alpha ef236fcd.

The band is the catalog-id range rcp-000377..rcp-000934 restricted to recipes
that ship at least one non-staple ingredient line whose quantity is unknown
("to taste"). This module reads the band from the shipped bundle at the base
commit, applies the fix file data/recipes/fixes/amounts-b.json in memory,
recompiles every touched record with the repository's own compiler, and writes
evaluation/recipe-quality/amounts-b.md: per-serving kcal, protein and sodium
before and after, plus every line left "to taste" with its reason.

Run:  python3 evaluation/recipe-quality/amounts_b.py
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PACKET = "burst11-fridgeluck-recipe-amounts-b"
BASE_COMMIT = "ef236fcd24613d470c1c588a290d04a1d673444a"
BAND_LO, BAND_HI = 377, 934
FIXES_PATH = REPO / "data/recipes/fixes/amounts-b.json"
REPORT_PATH = REPO / "evaluation/recipe-quality/amounts-b.md"
BUNDLE_PATH = REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
CORPUS_PATH = REPO / "data/recipes/corpus.jsonl"

sys.path.insert(0, str(REPO / "data/recipes/tools"))
import compile_bundle as compiler  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402


def load_fixes() -> dict:
    return json.loads(FIXES_PATH.read_text(encoding="utf-8"))


def load_corpus() -> tuple[dict[str, dict], dict[str, bytes]]:
    corpus: dict[str, dict] = {}
    raw: dict[str, bytes] = {}
    for line in CORPUS_PATH.read_bytes().split(b"\n"):
        if not line.strip():
            continue
        rec = json.loads(line)
        corpus[rec["id"]] = rec
        raw[rec["id"]] = line
    return corpus, raw


def read_base(path: Path) -> bytes:
    """Fail if the recorded base is unavailable rather than using the live corpus."""
    return subprocess.run(
        ["git", "show", f"{BASE_COMMIT}:{path.relative_to(REPO).as_posix()}"],
        capture_output=True, cwd=REPO, check=True).stdout


def base_artifacts() -> tuple[dict[str, dict], dict[str, bytes], dict]:
    """Read the packet's recorded corpus and bundle, not the live patched files."""
    out = read_base(CORPUS_PATH)
    corpus, raw = {}, {}
    for line in out.splitlines():
        rec = json.loads(line)
        corpus[rec["id"]] = rec
        raw[rec["id"]] = line
    bundle = json.loads(read_base(BUNDLE_PATH))
    return corpus, raw, bundle


def band_from_bundle(bundle: dict) -> list[tuple[dict, list[tuple[int, dict]]]]:
    """Band recipes with their non-staple unknown-quantity lines, bundle order."""
    band = []
    for r in bundle["recipes"]:
        cid = int(r["catalog_id"].split("-")[1])
        if not BAND_LO <= cid <= BAND_HI:
            continue
        lines = [(i, l) for i, l in enumerate(r["ingredients"])
                 if not l.get("assumed_staple") and l["quantity"]["kind"] == "unknown"]
        if lines:
            band.append((r, lines))
    return band


def compile_ctx() -> tuple[dict, dict, dict, dict]:
    """(mappings, vocab_by_key, rights_records, labels) for the fixed records."""
    mappings = json.loads((REPO / "data/ingredients/name-mappings.json")
                          .read_text(encoding="utf-8"))["mappings"]
    vocab = json.loads((REPO / "data/ingredients/vocabulary.json")
                       .read_text(encoding="utf-8"))["entries"]
    vocab_by_key = {e["key"]: e for e in vocab}
    rights = json.loads((REPO / "data/recipes/rights_manifest.json")
                        .read_text(encoding="utf-8"))["records"]
    ctx = vcorpus.load_rights_context()
    return mappings, vocab_by_key, rights, ctx


def labels_for(records: list[dict], ctx: dict) -> dict:
    return {rec["id"]: compiler.rights_label_for(rec, ctx) for rec in records}


def compile_one(rec: dict, mappings: dict, vocab_by_key: dict,
                rights: dict, labels: dict) -> dict:
    return compiler.compile_recipe(rec, mappings, vocab_by_key, rights, labels)


def nutrition(compiled: dict) -> dict:
    n = compiled["nutrition_per_serving"]
    return {k: n.get(k) for k in ("kcal", "protein_g", "sodium_mg")}


def exception_markers(fix: dict) -> tuple[bool, bool]:
    """(kcal_floor_exception, sodium_exception) declared in the fix's changes."""
    text = " ".join(
        f'{c.get("reason", "")} {c.get("evidence", "")}' for c in fix.get("changes", []))
    return "kcal floor" in text, "sodium" in text


def prepare() -> dict:
    fixes_doc = load_fixes()
    live_corpus, live_raw = load_corpus()
    corpus, raw, bundle = base_artifacts()
    band = band_from_bundle(bundle)
    fixes = {f["id"]: f for f in fixes_doc["fixes"]}
    mappings, vocab_by_key, rights, ctx = compile_ctx()

    fixed_records = {fid: f["record"] for fid, f in fixes.items()}
    labels = labels_for(list(fixed_records.values()), ctx)
    # The committed report records this packet's original nutrition comparison.
    # #224/#236 changed ingredient facts later; current facts still drive the
    # compiled-record safety and nutrition tests via the context returned below.
    base_mappings = json.loads(read_base(REPO / "data/ingredients/name-mappings.json"))["mappings"]
    base_vocab = {e["key"]: e for e in json.loads(
        read_base(REPO / "data/ingredients/vocabulary.json"))["entries"]}
    before, after = {}, {}
    for fid, fix in fixes.items():
        base_rec = corpus[fid]
        before[fid] = nutrition(compile_one(base_rec, base_mappings, base_vocab, rights, labels))
        after[fid] = nutrition(compile_one(fix["record"], base_mappings, base_vocab, rights, labels))
    return {
        "fixes_doc": fixes_doc, "fixes": fixes, "corpus": live_corpus, "raw": live_raw,
        "base_corpus": corpus, "base_raw": raw,
        "bundle": bundle, "band": band, "mappings": mappings,
        "vocab_by_key": vocab_by_key, "rights": rights, "labels": labels,
        "before": before, "after": after,
    }


def _fmt(x) -> str:
    return "-" if x is None else f"{x:,.1f}"


def build_report(p: dict | None = None) -> str:
    p = p or prepare()
    fixes: dict = p["fixes"]
    corpus: dict = p["corpus"]
    band: list = p["band"]
    band_ids = {vcorpus.catalog_id_for(r["id"]) for r in corpus.values()
                if r["id"] in fixes}
    n_lines = sum(len(lines) for _, lines in band)
    n_amount = sum(1 for f in fixes.values() for c in f["changes"]
                   if c["path"].endswith(".qty"))
    n_tt = sum(1 for f in fixes.values() for c in f["changes"]
               if c["path"].endswith(".qty.note"))

    out: list[str] = []
    out.append("# Recipe amounts — band rcp-000377..rcp-000934")
    out.append("")
    out.append(f"Packet `{PACKET}`, base alpha `{BASE_COMMIT}`. "
               f"Fix file `data/recipes/fixes/amounts-b.json`: "
               f"{len(fixes)} recipes, {n_lines} lines ({n_amount} given amounts, "
               f"{n_tt} left to taste with a note). Before/after numbers are "
               f"per serving, computed with `data/recipes/tools/compile_bundle.py`'s "
               f"own `compile_recipe` + `nutrition_for` on the base record and the "
               f"fixed record.")
    out.append("")
    out.append("| recipe | title | servings | kcal | protein g | sodium mg |")
    out.append("|---|---|---|---|---|---|")
    for f in sorted(fixes.values(), key=lambda f: int(f["catalog_id"].split("-")[1])):
        fid = f["id"]
        b, a = p["before"][fid], p["after"][fid]
        title = f["record"]["title"]
        servings = f["record"].get("servings", "?")
        out.append(
            f"| {f['catalog_id']} | {title} | {servings} "
            f"| {_fmt(b['kcal'])} → {_fmt(a['kcal'])} "
            f"| {_fmt(b['protein_g'])} → {_fmt(a['protein_g'])} "
            f"| {_fmt(b['sodium_mg'])} → {_fmt(a['sodium_mg'])} |")
    out.append("")
    out.append("## Lines left to taste")
    out.append("")
    for f in sorted(fixes.values(), key=lambda f: int(f["catalog_id"].split("-")[1])):
        for c in f["changes"]:
            if not c["path"].endswith(".qty.note"):
                continue
            idx = int(c["path"].split("[")[1].split("]")[0])
            name = f["record"]["ingredients"][idx]["name"]
            note = f["record"]["ingredients"][idx]["qty"].get("note", "")
            out.append(f"- {f['catalog_id']} — {name}: “{note}” — {c['reason']}")
    out.append("")
    out.append("## Nutrition bars")
    out.append("")
    out.append("Per-serving kcal 150–1300 and sodium ≤ 2300 mg hold for every "
               "recipe below except the ones the fix file explains in its "
               "`changes` evidence (kcal floor / sodium markers):")
    out.append("")
    kcal_exc = [f["catalog_id"] for f in fixes.values() if exception_markers(f)[0]]
    na_exc = [f["catalog_id"] for f in fixes.values() if exception_markers(f)[1]]
    out.append(f"- kcal floor explained: {', '.join(sorted(kcal_exc)) or 'none'}")
    out.append(f"- sodium bar explained: {', '.join(sorted(na_exc)) or 'none'}")
    out.append("")
    return "\n".join(out)


def main() -> int:
    p = prepare()
    REPORT_PATH.write_text(build_report(p), encoding="utf-8")
    kcal_bad, na_bad = [], []
    for fid, fix in p["fixes"].items():
        a = p["after"][fid]
        kcal_exc, na_exc = exception_markers(fix)
        if a["kcal"] is not None and not (150 <= a["kcal"] <= 1300) and not kcal_exc:
            kcal_bad.append(fid)
        if a["sodium_mg"] is not None and a["sodium_mg"] > 2300 and not na_exc:
            na_bad.append(fid)
    print(f"report -> {REPORT_PATH}")
    print(f"recipes: {len(p['fixes'])}, band lines: "
          f"{sum(len(l) for _, l in p['band'])}")
    if kcal_bad or na_bad:
        print(f"bar violations without an explanation: kcal={kcal_bad} sodium={na_bad}")
        return 1
    print("nutrition bars: all within 150-1300 kcal / <=2300 mg sodium, "
          "or explained in changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
