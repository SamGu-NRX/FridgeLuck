#!/usr/bin/env python3
"""Mechanical recipe-quality audit over the FridgeLuck original corpus.

Runs the rubric's mechanical checks (RUBRIC.md, criteria marked [M]) over every
in-scope recipe — every corpus recipe outside the amounts set — selects the
hand-scored sample (seed 20261016, 60 recipes), and, when
data/recipes/fixes/rubric.json exists, applies it in memory to report
before/after per fixed recipe.

Read-only over the corpus: the fix file is applied in memory, never written
back. Outputs audit-results.json beside this script and prints the counts the
report quotes. Re-running on the committed base reproduces the committed
sample ids and counts byte for byte.

Usage:
    python3 evaluation/recipe-quality/rubric/audit.py
    python3 evaluation/recipe-quality/rubric/audit.py --digest /tmp/digests.txt
"""
from __future__ import annotations

import hashlib
import json
import random
import re
import sys
from pathlib import Path

RUBRIC_DIR = Path(__file__).resolve().parent
REPO = RUBRIC_DIR.parents[2]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

import compile_bundle  # noqa: E402  (step_uses: the shipped uses linkage)
from pipeline.normalize import normalize_name  # noqa: E402

CORPUS = REPO / "data/recipes/corpus.jsonl"
MAPPINGS = REPO / "data/ingredients/name-mappings.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
SHIPPED = REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
FIXES = REPO / "data/recipes/fixes/rubric.json"
RESULTS = RUBRIC_DIR / "audit-results.json"
SAMPLE_SCORES = RUBRIC_DIR / "sample-scores.json"

SEED = 20261016
SAMPLE_SIZE = 60

# FDA Daily Value for sodium (2,300 mg) and the rubric's bands.
SODIUM_DV = 2300.0
KCAL_MIN, KCAL_MAX = 150.0, 1300.0
KCAL_HARD = 1526.0  # rubric C2 score-0 line

# Doneness phrases a cook cannot trust on animal protein (C4).
VISUAL_DONE = ["no longer pink", "juices run clear", "until golden",
               "golden brown", "no longer translucent"]

# Flavour axes (C6 hint): keywords by axis, matched on line names + step text.
AXES = {
    "salt": ["salt", "soy sauce", "fish sauce", "misо", "miso", "stock", "bouillon",
             "parmesan", "feta", "olive", "capers", "bacon", "cheese", "salsa",
             "pickle", "soy"],
    "acid": ["lemon", "lime", "vinegar", "tomato", "yogurt", "yoghurt", "citrus",
             "orange juice", "pickle", "tamarind", "wine", "salsa"],
    "fat": ["oil", "butter", "cream", "avocado", "tahini", "peanut", "cheese",
            "yogurt", "yoghurt", "coconut milk", "mayo", "ghee", "nuts", "sesame"],
    "heat": ["chili", "chilli", "chile", "pepper flakes", "cayenne", "jalapeno",
             "jalapeño", "sriracha", "hot sauce", "harissa", "curry", "chipotle",
             "gochujang", "sambal", "black pepper"],
}

# C3 mechanical hints.
BAKE_WORDS = ["bake", "roast", "oven"]
PREP_WORDS = ["chop", "dice", "mince", "slice", "grate", "shred"]
HEAT_WORDS = ["heat the oil", "heat oil", "hot pan", "sizzle", "add the oil",
              "warm the oil", "shimmering"]
REST_WORDS = ["rest"]


def load_corpus() -> tuple[list[dict], dict[str, str]]:
    """Records plus id -> raw JSONL line (no trailing newline) for sha256 pins."""
    recs: list[dict] = []
    raw: dict[str, str] = {}
    for line in CORPUS.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        recs.append(rec)
        raw[rec["id"]] = line
    return recs, raw


def amounts_set() -> set[str]:
    """Catalog ids with any non-staple unknown-amount line, from the shipped bundle."""
    bundle = json.loads(SHIPPED.read_text(encoding="utf-8"))
    flagged: set[str] = set()
    for r in bundle["recipes"]:
        for line in r["ingredients"]:
            if not line["assumed_staple"] and line["quantity"]["kind"] == "unknown":
                flagged.add(r["catalog_id"])
                break
    return flagged


def in_scope(recs: list[dict], amounts: set[str]) -> list[dict]:
    import validate_corpus  # noqa: E402  (catalog id mapping)
    return [r for r in recs if validate_corpus.catalog_id_for(r["id"]) not in amounts]


class Context:
    """Mappings/vocabulary lookups shared by every per-recipe evaluation."""

    def __init__(self) -> None:
        self.mappings = json.loads(MAPPINGS.read_text(encoding="utf-8"))["mappings"]
        vocab = json.loads(VOCAB.read_text(encoding="utf-8"))["entries"]
        self.per100 = {e["key"]: e.get("per_100g") for e in vocab}
        self.aliases: dict[str, str] = {}
        for e in vocab:
            names = [e["key"], e.get("display_name", ""), *e.get("aliases", [])]
            for a in names:
                a = str(a).strip().lower()
                if len(a) >= 4 and a not in self.aliases:
                    self.aliases[a] = e["key"]
        self.aliases.pop("black pepper", None)  # axis keyword, not a missing-food probe
        self.aliases.pop("black_teas", None)

    def key_for(self, name: str) -> str | None:
        m = self.mappings.get(normalize_name(name))
        return m["key"] if m else None

    def surface_for(self, name: str) -> str:
        m = self.mappings.get(normalize_name(name))
        return m["surface"] if m else name


STOP_TOKENS = {"with", "and", "the", "a", "an", "of", "in", "for", "to", "on"}


def evaluate(rec: dict, ctx: Context) -> dict:
    """All mechanical signals for one record, from the record alone."""
    lines = rec["ingredients"]
    surfaces = [ctx.surface_for(i["name"]) for i in lines]
    keys = [ctx.key_for(i["name"]) for i in lines]
    steps = rec["steps"]
    texts = [s["text"].lower() for s in steps]
    full_text = " ".join(texts)
    title_l = rec["title"].lower()

    def grams_of(qty: dict) -> float | None:
        if qty["kind"] == "source_grams":
            return float(qty["grams"])
        if qty["kind"] in ("household", "count"):
            g = qty.get("grams")
            return float(g) if g is not None else None
        return None  # unknown

    # C2/C5: per-serving kcal and sodium, same arithmetic as compile_bundle.nutrition_for.
    kcal = 0.0
    sodium = 0.0
    covered_any = False
    contributors: list[tuple[str, float]] = []
    for i, ing in enumerate(lines):
        g = grams_of(ing["qty"])
        if g is None:
            continue
        per = ctx.per100.get(keys[i]) if keys[i] else None
        if not per:
            continue
        covered_any = True
        scale = g / 100.0
        kcal += per.get("kcal", 0.0) * scale
        na = per.get("sodium_mg", 0.0) * scale
        sodium += na
        contributors.append((surfaces[i], na))
    servings = rec["servings"]
    per_kcal = kcal / servings if servings else float("inf")
    per_na = sodium / servings if servings else float("inf")
    top_na = sorted(contributors, key=lambda t: -t[1])[:4]

    # C1a: title tokens no line's surface/aliases/name covers.
    covered_names: list[str] = []
    for i, ing in enumerate(lines):
        covered_names.append(surfaces[i].lower())
        if keys[i]:
            m = ctx.mappings.get(normalize_name(ing["name"]))
            if m:
                covered_names.append(m["key"].replace("_", " "))
        covered_names.append(ing["name"].lower())
    uncovered_title: list[str] = []
    for tok in re.split(r"[^a-z0-9]+", title_l):
        if len(tok) < 4 or tok in STOP_TOKENS:
            continue
        if not any(re.search(rf"(?<![a-z]){re.escape(tok)}(?![a-z])", n) for n in covered_names):
            uncovered_title.append(tok)

    # C1b: step text names a known ingredient alias with no line for it.
    line_keys = {k for k in keys if k}
    missing_food: list[str] = []
    for alias, key in ctx.aliases.items():
        if key in line_keys:
            continue
        if any(re.search(rf"(?<![a-z]){re.escape(alias)}(?![a-z])", t) for t in texts):
            # Ignore aliases that are substrings of a line's own name (the
            # cook reads them as the same thing, e.g. "banana" inside
            # "banana pepper" lines).
            if not any(alias in n for n in covered_names):
                missing_food.append(alias)
    missing_food.sort(key=len, reverse=True)

    # C1c: lines no step's uses references (the shipped linkage).
    uses_per_line: set[int] = set()
    for t in texts:
        uses_per_line.update(compile_bundle.step_uses(t, surfaces))
    unused_lines = [surfaces[i] for i in range(len(surfaces)) if i not in uses_per_line]

    # C4: visual doneness on flesh/egg recipes, and FSIS coverage.
    import food_safety  # noqa: E402  (the corpus gate's own coverage rules)
    required = set(food_safety.required_classes(rec))
    uncovered = sorted(food_safety.uncovered_classes(rec))
    flesh_words = {"meat", "fish", "shellfish"}
    has_protein = bool(required & (flesh_words | {"egg"}))
    visual_hits = []
    if has_protein:
        for t, step in zip(texts, steps):
            if step.get("safety") and "thermometer" in t:
                continue
            for p in VISUAL_DONE:
                if p in t:
                    visual_hits.append(p)
                    break
    # C3 hints.
    bake_idx = next((i for i, t in enumerate(texts)
                     if any(w in t for w in BAKE_WORDS) and "preheat" not in t), None)
    preheat_idx = next((i for i, t in enumerate(texts) if "preheat" in t), None)
    preheat_after_bake = (bake_idx is not None and preheat_idx is not None
                          and preheat_idx > bake_idx)
    heat_before_prep = []
    for i, t in enumerate(texts):
        if not any(w in t for w in HEAT_WORDS):
            continue
        for j in range(i + 1, len(texts)):
            tj = texts[j]
            if any(w in tj for w in PREP_WORDS):
                for s in surfaces:
                    name_words = {w for w in re.split(r"[^a-z]+", s.lower()) if len(w) > 3}
                    if name_words and name_words & set(tj.split()) \
                            and not (name_words & set(t.split())):
                        heat_before_prep.append(s)
                        break
                break
    last_thermo = max((i for i, s in enumerate(steps) if s.get("safety")), default=None)
    rest_after = None
    if last_thermo is not None:
        rest_after = any("rest" in t for t in texts[last_thermo + 1:])

    # C7: timers vs the minutes promise.
    timer_sum = sum(s["timer_min"] for s in steps if "timer_min" in s)
    minutes = rec["minutes"]

    # C6 hint: flavour axes present in names or steps.
    axes_present = []
    for axis, kws in AXES.items():
        hay = title_l + " " + full_text + " " + " ".join(covered_names)
        if any(k in hay for k in kws):
            axes_present.append(axis)
    axes_missing = [a for a in AXES if a not in axes_present]

    return {
        "kcal_per_serving": round(per_kcal, 1) if covered_any else None,
        "sodium_mg_per_serving": round(per_na, 1) if covered_any else None,
        "top_sodium": [(n, round(v, 0)) for n, v in top_na],
        "uncovered_title_tokens": uncovered_title,
        "missing_food_in_steps": missing_food[:6],
        "unused_lines": unused_lines,
        "uncovered_fsis": uncovered,
        "visual_done_phrases": visual_hits,
        "preheat_after_bake": preheat_after_bake,
        "heat_before_prep": sorted(set(heat_before_prep)),
        "rest_after_meat": rest_after,
        "timer_sum": timer_sum,
        "minutes": minutes,
        "axes_present": axes_present,
        "axes_missing": axes_missing,
    }


def sha_of(raw_line: str) -> str:
    return hashlib.sha256(raw_line.encode("utf-8")).hexdigest()


def main() -> int:
    recs, raw = load_corpus()
    ctx = Context()
    amounts = amounts_set()
    scoped = in_scope(recs, amounts)
    scoped_by_id = {r["id"]: r for r in scoped}

    # Apply the fix file in memory when it exists (never written back).
    fixes_applied: dict[str, dict] = {}
    if FIXES.exists():
        packet = json.loads(FIXES.read_text(encoding="utf-8"))
        for fx in packet.get("fixes", []):
            rid = fx["id"]
            if rid not in raw:
                raise SystemExit(f"fix {rid}: id not in corpus")
            if sha_of(raw[rid]) != fx["before_sha256"]:
                raise SystemExit(f"fix {rid}: before_sha256 does not match base corpus")
            fixes_applied[rid] = fx["record"]

    def eval_record(rid: str) -> dict:
        return evaluate(fixes_applied.get(rid) or scoped_by_id[rid], ctx)

    # ---- mechanical sweep over every in-scope recipe -----------------------
    per_recipe: dict[str, dict] = {rid: eval_record(rid) for rid in sorted(scoped_by_id)}

    def count(pred) -> int:
        return sum(1 for v in per_recipe.values() if pred(v))

    counts = {
        "in_scope": len(scoped_by_id),
        "amounts_set": len(amounts),
        "kcal_over_1300": count(lambda v: v["kcal_per_serving"] is not None
                                and v["kcal_per_serving"] > KCAL_MAX),
        "kcal_over_1526": count(lambda v: v["kcal_per_serving"] is not None
                                and v["kcal_per_serving"] > KCAL_HARD),
        "kcal_under_150": count(lambda v: v["kcal_per_serving"] is not None
                                and v["kcal_per_serving"] < KCAL_MIN),
        "sodium_over_2300": count(lambda v: v["sodium_mg_per_serving"] is not None
                                  and v["sodium_mg_per_serving"] > SODIUM_DV),
        "sodium_over_1150": count(lambda v: v["sodium_mg_per_serving"] is not None
                                  and v["sodium_mg_per_serving"] > SODIUM_DV / 2),
        "title_token_uncovered": count(lambda v: bool(v["uncovered_title_tokens"])),
        "step_names_missing_food": count(lambda v: bool(v["missing_food_in_steps"])),
        "recipes_with_unused_lines": count(lambda v: bool(v["unused_lines"])),
        "unused_lines_total": sum(len(v["unused_lines"]) for v in per_recipe.values()),
        "preheat_after_bake": count(lambda v: v["preheat_after_bake"]),
        "heat_before_prep": count(lambda v: bool(v["heat_before_prep"])),
        "no_rest_after_meat": count(lambda v: v["rest_after_meat"] is False),
        "visual_done_phrases": count(lambda v: bool(v["visual_done_phrases"])),
        "fsis_uncovered": count(lambda v: bool(v["uncovered_fsis"])),
        "timer_over_minutes": count(lambda v: v["timer_sum"] > v["minutes"]),
        "timer_over_minutes_25pct": count(
            lambda v: v["timer_sum"] > v["minutes"] * 1.25),
    }

    # ---- seeded hand-score sample ------------------------------------------
    sample_ids = sorted(random.Random(SEED).sample(sorted(scoped_by_id), SAMPLE_SIZE))

    if SAMPLE_SCORES.exists():
        doc = json.loads(SAMPLE_SCORES.read_text(encoding="utf-8"))
        if doc.get("sample_ids") != sample_ids:
            raise SystemExit("sample-scores.json ids do not reproduce from seed "
                             f"{SEED}; regenerate before trusting the scores")
        scored = doc.get("recipes", [])
        totals = [sum(s["scores"][k][0] for k in s["scores"]) for s in scored]
        dist = {str(t): totals.count(t) for t in sorted(set(totals))}
        print(f"sample: {len(scored)} hand-scored, total distribution {dist}")
        worst = sorted(scored, key=lambda s: sum(s["scores"][k][0] for k in s["scores"]))
        print("worst sample recipes: "
              + ", ".join(f"{s['catalog_id']} {s['title']} "
                          f"({sum(s['scores'][k][0] for k in s['scores'])}/14)"
                          for s in worst[:10]))
    else:
        print("sample: ids below; score by hand into sample-scores.json")
        print(json.dumps(sample_ids, indent=1))

    # ---- before/after for fixed recipes ------------------------------------
    fixed_table = []
    for rid in sorted(fixes_applied):
        before = evaluate(scoped_by_id[rid], ctx)
        after = evaluate(fixes_applied[rid], ctx)
        fixed_table.append({
            "id": rid,
            "catalog_id": _catalog_id(rid),
            "title": fixes_applied[rid]["title"],
            "before": {k: before[k] for k in
                       ("kcal_per_serving", "sodium_mg_per_serving",
                        "uncovered_title_tokens", "missing_food_in_steps",
                        "unused_lines", "timer_sum", "minutes")},
            "after": {k: after[k] for k in
                      ("kcal_per_serving", "sodium_mg_per_serving",
                       "uncovered_title_tokens", "missing_food_in_steps",
                       "unused_lines", "timer_sum", "minutes")},
        })
    if fixed_table:
        print(f"fixes applied in memory: {len(fixed_table)}")
        for row in fixed_table:
            b, a = row["before"], row["after"]
            print(f"  {row['catalog_id']} {row['title']}: "
                  f"kcal {b['kcal_per_serving']}->{a['kcal_per_serving']}, "
                  f"sodium {b['sodium_mg_per_serving']}->{a['sodium_mg_per_serving']}")

    results = {
        "base_commit": raw.get("_base", None) or _git_head(),
        "counts": counts,
        "sample_ids": sample_ids,
        "fixed": fixed_table,
    }
    RESULTS.write_text(json.dumps(results, indent=1, sort_keys=True) + "\n",
                       encoding="utf-8")
    print(json.dumps(counts, indent=1, sort_keys=True))
    print(f"results: {RESULTS}")
    return 0


def _catalog_id(corpus_id: str) -> str:
    import validate_corpus  # noqa: E402
    return validate_corpus.catalog_id_for(corpus_id)


def _git_head() -> str:
    import subprocess
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, check=True,
                          capture_output=True, text=True).stdout.strip()[:12]


def _digest(rid: str, r: dict, sig: dict) -> str:
    """Compact readable block: everything the rubric scores, in order."""
    lines = [f"=== {rid} / {_catalog_id(rid)}: {r['title']}",
             f"cuisine={r['cuisine']} slots={','.join(r['meal_slots'])} "
             f"minutes={r['minutes']} servings={r['servings']} "
             f"kcal={sig['kcal_per_serving']} sodium={sig['sodium_mg_per_serving']} "
             f"axes={'+'.join(sig['axes_present'])} missing_axes={','.join(sig['axes_missing'])}"]
    for i, ing in enumerate(r["ingredients"]):
        q = ing["qty"]
        if q["kind"] == "unknown":
            amt = "unknown"
        elif q["kind"] == "source_grams":
            amt = f"{q['grams']}g"
        else:
            amt = f"{q.get('value')} {q.get('unit')} ({q.get('grams')}g)"
        lines.append(f"  - {ing['name']}: {amt}")
    for i, s in enumerate(r["steps"]):
        t = s["text"]
        extra = []
        if "timer_min" in s:
            extra.append(f"timer={s['timer_min']}m")
        if s.get("safety"):
            extra.append(f"safety={s['safety']['class']}@{s['safety']['temp_f']}F")
        lines.append(f"  {i + 1}. {t} [{' '.join(extra)}]")
    flags = []
    if sig["uncovered_title_tokens"]:
        flags.append(f"title-uncovered={sig['uncovered_title_tokens']}")
    if sig["missing_food_in_steps"]:
        flags.append(f"missing-food={sig['missing_food_in_steps']}")
    if sig["unused_lines"]:
        flags.append(f"unused-lines={sig['unused_lines']}")
    if sig["visual_done_phrases"]:
        flags.append(f"visual-done={sig['visual_done_phrases']}")
    if sig["uncovered_fsis"]:
        flags.append(f"fsis-uncovered={sig['uncovered_fsis']}")
    if sig["preheat_after_bake"]:
        flags.append("preheat-after-bake")
    if sig["heat_before_prep"]:
        flags.append(f"heat-before-prep={sig['heat_before_prep']}")
    if sig["rest_after_meat"] is False:
        flags.append("no-rest-after-meat")
    if sig["timer_sum"] > sig["minutes"]:
        flags.append(f"timers={sig['timer_sum']}m>{sig['minutes']}m")
    if sig["kcal_per_serving"] is not None and sig["kcal_per_serving"] > KCAL_MAX:
        flags.append("kcal>1300")
    if sig["sodium_mg_per_serving"] is not None and sig["sodium_mg_per_serving"] > SODIUM_DV:
        flags.append("sodium>2300")
    lines.append("  FLAGS: " + ("; ".join(flags) if flags else "none"))
    return "\n".join(lines)


if __name__ == "__main__":
    if "--digest" in sys.argv:
        # Hand-scoring aid: one compact block per sample recipe.
        recs, raw = load_corpus()
        ctx = Context()
        amounts = amounts_set()
        scoped = {r["id"]: r for r in in_scope(recs, amounts)}
        sample_ids = sorted(random.Random(SEED).sample(sorted(scoped), SAMPLE_SIZE))
        out = []
        for rid in sample_ids:
            r = scoped[rid]
            sig = evaluate(r, ctx)
            out.append(_digest(rid, r, sig))
        Path(sys.argv[sys.argv.index("--digest") + 1]).write_text(
            "\n\n".join(out), encoding="utf-8")
        print(f"digests: {len(out)}")
    else:
        raise SystemExit(main())
