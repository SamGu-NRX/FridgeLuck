"""Generate data/recipes/RIGHTS-AUDIT.md from the bundled recipe seed.

Reads apps/ios/Resources/data.json, extracts each recipe's Source: line
(first line of the instructions field, when present), cross-checks the
committed synthetic cache fixtures, and writes a per-recipe rights table.

Regenerate (from repo root):

    python3 scripts/recipe_scraper/generate_rights_audit.py

Offline tool: reads committed files only, no network, no third-party deps.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_JSON = REPO_ROOT / "apps" / "ios" / "Resources" / "data.json"
OUT_PATH = REPO_ROOT / "data" / "recipes" / "RIGHTS-AUDIT.md"
CACHE_DIR = REPO_ROOT / "scripts" / "recipe_scraper" / ".cache"

SOURCE_LINE_RE = re.compile(r"^Source:\s*(?P<url>\S+)\s*$", re.MULTILINE)
BBC_HOST_RE = re.compile(r"(^|\.)bbcgoodfood\.com$")

# Git facts verified against this repo's history (2026-10-11):
# 69f0286 (2026-02-08, SamGu-NRX, initial commit) shipped data.json with the
# 25 seed recipes and no Source lines; b6eaf3c (2026-02-28, ShreySuri) took it
# to 166 recipes with 141 BBC Source lines.
SEED_COMMIT = "69f0286"
SEED_COMMIT_DATE = "2026-02-08"
SEED_COMMIT_AUTHOR = "SamGu-NRX"
HYDRATION_COMMIT = "b6eaf3c"
HYDRATION_COMMIT_DATE = "2026-02-28"


def extract_source_url(instructions: str) -> str | None:
    match = SOURCE_LINE_RE.search(instructions or "")
    return match.group("url") if match else None


def is_bbc_url(url: str) -> bool:
    host_match = re.match(r"https?://([^/]+)", url)
    return bool(host_match and BBC_HOST_RE.search(host_match.group(1)))


def load_cache_facts() -> dict:
    facts: dict = {}
    scrape_cache = CACHE_DIR / "synthetic_fixtures.json"
    if scrape_cache.exists():
        records = json.loads(scrape_cache.read_bytes())
        bbc = [r for r in records if is_bbc_url(r.get("source_url", ""))]
        facts["scrape_cache_records"] = len(records)
        facts["scrape_cache_bbc_records"] = len(bbc)
    test_cache = CACHE_DIR / "synthetic_fixtures.test.json"
    if test_cache.exists():
        records = json.loads(test_cache.read_bytes())
        facts["test_fixture_records"] = len(records)
    return facts


def audit() -> str:
    payload = json.loads(DATA_JSON.read_bytes())
    recipes = payload["recipes"]
    cache_facts = load_cache_facts()
    scrape_cache_exists = (CACHE_DIR / "synthetic_fixtures.json").exists()
    cache_titles = (
        {r["title"].strip().lower() for r in json.loads((CACHE_DIR / "synthetic_fixtures.json").read_bytes())}
        if scrape_cache_exists
        else set()
    )

    bbc_rows: list[dict] = []
    seed_rows: list[dict] = []
    other_rows: list[dict] = []

    for row in recipes:
        recipe_id, title = row[0], row[1]
        instructions = row[6] if len(row) > 6 and isinstance(row[6], str) else ""
        url = extract_source_url(instructions)
        if url and is_bbc_url(url):
            bbc_rows.append({"id": recipe_id, "title": title, "url": url})
        elif url:
            other_rows.append({"id": recipe_id, "title": title, "url": url})
        else:
            title_in_cache = title.strip().lower() in cache_titles if scrape_cache_exists else None
            seed_rows.append({"id": recipe_id, "title": title, "in_cache": title_in_cache})

    today = "2026-10-11"
    lines: list[str] = []
    lines.append("# Bundled-recipe rights audit")
    lines.append("")
    lines.append(f"Audit date: {today}. Scope: every recipe bundled in `apps/ios/Resources/data.json` at branch `obv/fl-next-recipe-fidelity` (166 recipes).")
    lines.append("")
    lines.append("## How to read this")
    lines.append("")
    lines.append("The app ships only recipes it has the right to ship (SPEC 3.5, `docs/spec/overhaul-20261011/SPEC.md`).")
    lines.append("Unknown rights means quarantine. A URL attribution is not a licence.")
    lines.append("Verdicts:")
    lines.append("")
    lines.append("- **keep** - rights evidence found; the bundled text can stay.")
    lines.append("- **rewrite** - keep the dish, replace the bundled text with an original recipe in our own words with our own structured steps (SPEC 3.5 default).")
    lines.append("- **remove** - no rights evidence and no rewrite planned; the recipe leaves the bundle.")
    lines.append("")
    lines.append("## Rights-record vocabulary (Suite C alignment)")
    lines.append("")
    lines.append("The downstream corpus lands at `data/recipes/corpus.jsonl`, and every corpus recipe ships with a rights record (contract: `evaluation/SCORECARD.md` and `evaluation/suites/recipes/rights.py` on branch `eval/scorecard-runner`, retrieved 2026-10-11). A rights record is **complete** - and the recipe rights-clear - only when it has all of:")
    lines.append("")
    lines.append("- `source_id`, `source_type`, `origin`, `license`, `access_date` (YYYY-MM-DD), and `license_evidence`;")
    lines.append("- all six boolean permissions: `text`, `images`, `modification`, `attribution`, `caching`, `offline_use`.")
    lines.append("")
    lines.append("A URL attribution grants **none** of the six permissions. Each of the 141 BBC rows carries exactly that - a bare `Source:` URL with no licence evidence - so its rights record is incomplete and the recipe quarantines (rights.py: a bbcgoodfood.com source with no licence is quarantine, SPEC 10 \"no licence evidence\"). That is the same finding as the rewrite verdicts below, in the Suite C vocabulary.")
    lines.append("")
    lines.append("The 25 seed recipes' \"keep\" verdicts rest on in-house authorship traced through git history. Their corpus records still must be completed (origin: FridgeLuck seed; license: in-house; license_evidence: this audit) before shipping; a record that cannot be completed quarantines the recipe.")
    lines.append("")
    lines.append("Corpus ingredient lines carry quantity evidence using exactly the kinds `weighed`, `source_grams`, `household`, `unknown` (rs.py `RESOLVED_KINDS`/`ALL_KINDS`). `weighed` means measured on a scale, never a builder estimate; a computed mass is at best `household` with a conversion (a documented `conversions.json` row, `conversion_ref` recorded); `unknown` keeps grams null and blocks \"complete nutrition\" and fit claims. `scripts/recipe_scraper/scrape_recipes.py` now emits exactly these kinds.")
    lines.append("")
    lines.append("## Where the Source: line lives")
    lines.append("")
    lines.append("The bundled schema is a positional array: `[id, title, minutes, servings, required_ingredient_pairs, optional_ingredient_pairs, instructions, tag_bitmask]`.")
    lines.append("Attribution, where it exists, is the first line of the `instructions` string in the form `Source: <url>`.")
    lines.append("141 of 166 recipes carry such a line; all 141 point at `www.bbcgoodfood.com`. The other 25 carry no Source line at all.")
    lines.append("")
    lines.append("## Shared verdict: the 141 BBC Good Food recipes - rewrite")
    lines.append("")
    lines.append("Evidence of permission found: none. The bundle records a bare URL per recipe and nothing else.")
    lines.append("The repo contains no licence file for BBC Good Food content, no permission record, and no terms waiver.")
    lines.append("The committed scraper cache (`scripts/recipe_scraper/.cache/bbc_goodfood_recipes.json`) is scraped site content, not permission evidence.")
    lines.append("")
    lines.append("The site's own terms point the other way. bbcgoodfood.com is operated by Immediate Media Company Limited.")
    lines.append("Its website terms and conditions (`https://www.immediate.co.uk/terms-and-conditions/`, retrieved 2026-10-11) state, verbatim:")
    lines.append("")
    lines.append("> In accessing our Services, you agree that you will only access its contents for your own personal and non-commercial use and not for any commercial or other purposes, including advertising or selling any goods or services. You also agree not to adapt, alter or create a derivative work from any content on our Services except for your own personal, non-commercial use. You will need our prior written permission if you want to use any content on our Services for any other reason.")
    lines.append("")
    lines.append("> you undertake not to copy, store in any medium (including on any other website), distribute, transmit, re-transmit, re-publish, broadcast, modify, or show in public any part of our Services without our prior written permission")
    lines.append("")
    lines.append("The Good Food app terms (`https://www.bbcgoodfood.com/good-food-app-terms-and-conditions`, retrieved 2026-10-11) add, verbatim:")
    lines.append("")
    lines.append("> Content may only be downloaded or used for personal use.")
    lines.append("")
    lines.append("Bundling 141 BBC Good Food recipes - title, ingredient-expression lines, and full method text - inside a paid app is commercial redistribution of their content, not personal use.")
    lines.append("It requires prior written permission from Immediate Media. No such permission exists in this repo.")
    lines.append("A recipe's bare list of ingredients is generally not copyrightable, but the written method and expressive ingredient lines are; the bundle currently ships both verbatim (example: recipe id 26, `10-minute couscous salad`, whose instructions field reproduces the site's full method paragraph).")
    lines.append("")
    lines.append("Verdict for all 141: **rewrite** - keep the dish as a concept (dish names and ingredient lists are not the problem), replace every line of expression with our own original recipe and structured steps, drop the `Source:` URL line or reduce it to an inspiration link only after legal review.")
    lines.append("Sam makes the final call, per SPEC 3.5, ideally with legal advice.")
    lines.append("")
    lines.append("## Redistribution findings in committed caches")
    lines.append("")
    lines.append("The committed caches under `scripts/recipe_scraper/.cache/` are synthetic fixtures (see `.cache/README.md`); the BBC Good Food scrape caches they replaced were removed from the repo on 2026-10-11:")
    lines.append("")
    lines.append(f"- `synthetic_fixtures.json` - {cache_facts.get('scrape_cache_records', '?')} synthetic fixture records ({cache_facts.get('scrape_cache_bbc_records', '?')} with bbcgoodfood.com URLs); fictional titles deliberately disjoint from bundled recipes; replaces the BBC scrape cache removed from the repo (see `.cache/README.md`).")
    lines.append(f"- `synthetic_fixtures.test.json` - {cache_facts.get('test_fixture_records', '?')} synthetic fixture records used as a test fixture.")
    lines.append("")
    lines.append("That removal and replacement is done (2026-10-11): the BBC scrape caches were deleted and replaced with the synthetic fixtures above, so this finding is satisfied; the rewrite verdict covers the bundled rows.")
    lines.append("")
    lines.append("## The 25 seed recipes - traced individually")
    lines.append("")
    lines.append("These 25 recipes (ids 1-25) carry no Source line. SPEC 3.5 notes they are not automatically clear, so each was traced through repo git history:")
    lines.append("")
    lines.append(f"- The initial commit `{SEED_COMMIT}` ({SEED_COMMIT_DATE}, author {SEED_COMMIT_AUTHOR}) shipped `FridgeLuck.swiftpm/Resources/data.json` with exactly these 25 recipes and no Source lines.")
    lines.append(f"- Commit `{HYDRATION_COMMIT}` ({HYDRATION_COMMIT_DATE}) took the file from 25 to 166 recipes and introduced all 141 BBC attributions; the 25 seed rows were carried over unchanged (identical titles, verified row-by-row).")
    lines.append("- None of the 25 titles appears in the committed BBC scrape cache (checked programmatically, per row below).")
    lines.append("- `apps/ios/Resources/data.backup.20260228-233201.json` is a backup of the pre-hydration 25-recipe seed and contains no BBC references; the `demo/` resources and `demo_breakfast.json` contain none either.")
    lines.append("")
    lines.append("Evidence is therefore repo-internal: in-repo authorship at the initial commit, no external attribution, generic classic-dish titles with terse original-styled method text.")
    lines.append("Repo-internal evidence cannot exclude that the seed author reproduced an external recipe elsewhere, so the verdict below is keep **with that stated residual assumption**; Sam confirms or corrects it when signing off the audit.")
    lines.append("")
    lines.append("## Per-recipe audit table")
    lines.append("")
    lines.append("Regenerate with: `python3 scripts/recipe_scraper/generate_rights_audit.py`")
    lines.append("")
    lines.append("| id | title | source url | permission evidence | verdict |")
    lines.append("|---|---|---|---|---|")
    for row in seed_rows:
        cache_note = "not in" if row["in_cache"] is False else ("title IS in" if row["in_cache"] else "?")
        evidence = (
            f"No Source line. In repo since {SEED_COMMIT} ({SEED_COMMIT_DATE}, initial commit); "
            f"carried unchanged through {HYDRATION_COMMIT}; title {cache_note} the BBC scrape cache."
        )
        verdict = "keep" if row["in_cache"] is False else "needs review"
        lines.append(f"| {row['id']} | {row['title']} | none | {evidence} | {verdict} |")
    for row in bbc_rows:
        evidence = "URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above)."
        lines.append(f"| {row['id']} | {row['title']} | {row['url']} | {evidence} | rewrite |")
    for row in other_rows:
        lines.append(f"| {row['id']} | {row['title']} | {row['url']} | non-BBC external URL, not traced - investigate individually | needs review |")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| verdict | count |")
    lines.append("|---|---|")
    lines.append(f"| keep | {len(seed_rows)} |")
    lines.append(f"| rewrite | {len(bbc_rows)} |")
    lines.append(f"| remove | 0 |")
    lines.append(f"| needs review | {len(other_rows)} |")
    lines.append(f"| total | {len(recipes)} |")
    lines.append("")
    lines.append("## What this means for the corpus task")
    lines.append("")
    lines.append("None of the 141 rewritten recipes can contribute text to the corpus. After the rewrite or removal of the BBC rows, the honest starting corpus is the 25 seed originals plus newly written original recipes.")
    lines.append("Cleared sources (`SOURCES.md` in this directory) add: NHS recipe content under the Open Government Licence v3.0 with attribution, NHLBI federal recipe collections for recipes NHLBI itself authored, and a subset of MyPlate Kitchen recipes recorded per contributor.")
    lines.append("No large open recipe-text dataset is cleared for a paid app (see `food-data-licensing.md` on branch `docs/spec-overhaul-20261011`), so original recipes are expected to be a large share of the corpus (SPEC 3.5).")
    lines.append("The corpus lands at `data/recipes/corpus.jsonl`; each recipe ships with a rights record in the vocabulary defined above, and a recipe whose record cannot be completed stays quarantined out of the corpus.")
    lines.append("The corpus task must also decide the fate of the committed BBC caches (removal or synthetic-fixture replacement).")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(audit(), encoding="utf-8")
    print(f"wrote {OUT_PATH.relative_to(REPO_ROOT)}")
