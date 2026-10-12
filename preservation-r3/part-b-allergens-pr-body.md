## Why

Independent review BLOCKED draft PR #88 at base `9e04af4` (blocker 3): the allergen/diet claim scan cleared claims through the fixture alias table in `allergens.json` (`rs.py:573-619`, `allergens.json:172-173`) while FLIngredientFacts was unavailable.

- A tamari-only recipe with a `gluten-free` claim and empty conflicts **cleared**: the alias table unconditionally recorded only soy, so no product-composition evidence existed behind the gluten-free verdict. Known-name composition was unestablished.
- Violates `evaluation/CONTRACTS.md:15-18` and `:62`: verdicts come only from FLIngredientFacts data, and missing canonical facts must **hold** dependent claims — counted unchecked, with a reason naming the absent or incomplete source; never silently cleared, never silently skipped.
- The lead's earlier round fixed unknown-name handling (unknown names are held and appear in `classification_incomplete`); that fix is present at base `9e04af4` and this branch **must not regress it** — unknown names stay on the scan surface.

## What changed

Claim verdicts now come **only** from FLIngredientFacts data (`data/ingredient-facts`, branch `overhaul/ingredient-facts`, PR #127 — consumed read-only):

- **`rs.py` — `FLIngredientFacts`**: thin read-only dataset consumer. Resolves an ingredient line name (identity key/display/synonym/product form) to a facts row; per-axis fact lookup with product-form overrides taking precedence (per-axes merge, as the dataset's conformance runner resolves). Load-time validation mirrors the dataset's own conformance runner: vocabularies (nine FDA allergens, five diets, gluten property, evidence kinds, states, certainties), evidence completeness on non-unknown states, absence never resting on `usda`/`recipe` evidence, component resolution, key/name collisions. Load precedence: the scored tree's `data/ingredient-facts/` when present, else the suite-pinned snapshot (below). Any absence or validation failure → `(None, reason)` → every dependent claim held with that reason.
- **`rs.py` — claim verdicts (`CLAIM_AXES`, `_claim_axis_verdicts`, `AllergenScanner.verify_claim`)**: per-ingredient, per-claim-axis. A claim clears only when every ingredient resolves to a facts row whose claim-relevant axes are `free`/`allowed` with valid evidence **and** the recomputed conflicts match the recorded evidence. Otherwise the claim is **HELD**: counted unchecked, with a reason naming the absent or incomplete source — unknown name (no identity); identity without a facts row; unknown or absent axis state; absent or unloadable facts source. Unknown composition never means allowed. The gluten property is its own axis, never merged with wheat (a gluten-free label never settles wheat).
- **The fixture alias table no longer clears claims** — `allergens.json` classes feed only R3 doneness classification; the `claims` registry remains the known-type list (`forbids` values are documentation). `_comment` documents the narrowed role.
- **`canon/ingredient-facts/`** — verbatim snapshot of `overhaul/ingredient-facts` @ `b0deecce` (`identities.json`, `facts.json`, byte-for-byte via `git show`), plus `PROVENANCE.md` recording source, pin, load precedence, and the re-verification duty.
- **`test_allergen_facts.py`** — planted-failure self-tests, committed red at base in `ecb333f`.

Boundaries: changes confined to `evaluation/suites/recipes/` (`rs.py`, `allergens.json`, `canon/ingredient-facts/`, new test/README files). No changes to `.github/workflows/`, `suite.py`, R3 classification semantics, or `evaluation/out/`.

## Tradeoffs

- **Pinned snapshot vs. live branch dependency:** suite runs must be reproducible from committed inputs and this suite may not edit the canonical branch, so the exact verified bytes are pinned. A `data/ingredient-facts/` tree in the scored tree wins when present. Cost: the snapshot must be re-pinned when the canonical source moves (duty documented in `PROVENANCE.md`; `PINNED_FACTS_HEAD` in `rs.py` records `b0deecce`).
- **Held ≠ cleared raises the bar:** the 0-unchecked metric now depends on facts completeness for every claimed ingredient. That is the intended fail-closed direction of `CONTRACTS.md` — a claim without composition evidence must be visible as unchecked, not laundered through a fixture.
- **Rejected alternative:** keeping the alias table as a fallback source. Rejected because that is exactly the blocker — a fixture with no product-composition evidence was clearing claims.

## Proof

Commands run in `evaluation/suites/recipes/` (Linux sandbox, python3; nothing here requires Xcode/device — no UNVERIFIED-NATIVE paths). Red at base first (scanner at base `9e04af4`, harness from `ecb333f`), then green after the fix (`4f590b9`) and re-verified green after merging `origin/eval/scorecard-runner` `17953ed1` (merge commit `1a56f06`).

**Red at base `9e04af4`** (verbatim, trimmed only at line ends):

```
$ python3 test_allergen_facts.py
  FAIL  B1 tamari gluten-free claim held without facts composition: unchecked=0 detail={}
  FAIL  B2 certified gluten-free tamari clears through facts: unchecked=1 stripped=1 detail={"b2-tamari-gf": [{"claim": "gluten-free", "reason": "ingredient composition unresolved for ['gluten-free tamari'] (classification INCOMPLETE; unknown never means allowed)"}]}
  PASS  B3 cream-cheese dairy-free claim stays held (scan surface): unchecked=1 detail={"b3-cream-cheese": [{"claim": "dairy-free", "reason": "ingredient composition unresolved for ['cream cheese'] (classification INCOMPLETE; unknown never means allowed)"}]}
  SKIP  B4 absent facts source holds claims, reason names the source: skipped at base: facts-injection API not present (this is the fix under test)
  SKIP  B5 compound-unknown facts and facts-row-less identity hold claims: skipped at base: pinned FLIngredientFacts not loadable without the fix
  SKIP  B6 facts-backed claim clears; disagreeing evidence held: skipped at base: pinned FLIngredientFacts not loadable without the fix
  PASS  B7 soy-sauce gluten conflict holds the claim: detail={"b7-soy-sauce": [{"claim": "gluten-free", "reason": "evidence disagrees with recomputed scan (recorded [], recomputed ['gluten'])"}]}
allergen-facts verdict self-tests: 2 passed, 2 failed, 3 skipped (base 9e04af4 must show B1/B2 FAILING; the fix branch must show every case PASS with no skips)
EXIT=1
```

B1 is the cited blocker: the tamari-only gluten-free claim **cleared** (`unchecked=0`, empty detail) with no composition evidence. B2 is red because no facts-backed clear-path existed. B3/B7 pass at base because the earlier unknown-name fix already held those — they are regression guards (the scan surface must keep naming those ingredients); the fix branch keeps them green with stronger, source-naming reasons. B4–B6 exercise the fix itself and skip at base.

**Green on this branch** (after `4f590b9`, identical after the merge):

```
$ python3 test_allergen_facts.py
  PASS  B1 tamari gluten-free claim held without facts composition: unchecked=1 detail={"b1-tamari": [{"claim": "gluten-free", "reason": "ingredient 'tamari' (FLIngredientFacts 'tamari'): diet 'glutenFree' state missing or unknown — held (unknown composition never means allowed) — claim HELD (fail closed; source: suite-pinned snapshot canon/ingredient-facts (overhaul/ingredient-facts @ b0deecce36bf6...))"}]}
  PASS  B2 certified gluten-free tamari clears through facts: unchecked=0 stripped=0
  PASS  B3 cream-cheese dairy-free claim stays held (scan surface): unchecked=1 detail={"b3-cream-cheese": [{"claim": "dairy-free", "reason": "evidence disagrees with FLIngredientFacts-recomputed conflicts (recorded [], recomputed ['allergen:milk']; offending ingredients: ['cream cheese'])"}]}
  PASS  B4 absent facts source holds claims, reason names the source: verdict=FLIngredientFacts unavailable (canonical source: branch overhaul/ingredient-facts, PR #127) — tried: scored tree data/ingredient-facts (not present); pinned snapshot canon/ingredient-facts (not present): claim HELD (fail closed ...)
  PASS  B5 compound-unknown facts and facts-row-less identity hold claims: unchecked=2 detail={"b5-stock-cube": [... allergen 'milk' state missing or unknown — held ...], "b5-granola": [... 'artisan granola bar' (FLIngredientFacts 'artisan-granola-bar'): no facts row — source incomplete, fail closed ...]}
  PASS  B6 facts-backed claim clears; disagreeing evidence held: clear verdict=True wrong-evidence verdict=evidence disagrees with FLIngredientFacts-recomputed conflicts (recorded ['allergen:milk'], recomputed []; offending ingredients: [])
  PASS  B7 soy-sauce gluten conflict holds the claim: detail={"b7-soy-sauce": [{"claim": "gluten-free", "reason": "evidence disagrees with FLIngredientFacts-recomputed conflicts (recorded [], recomputed ['diet:glutenFree', 'gluten']; offending ingredients: ['soy sauce'])"}]}
allergen-facts verdict self-tests: 7 passed, 0 failed, 0 skipped (base 9e04af4 must show B1/B2 FAILING; the fix branch must show every case PASS with no skips)
EXIT=0
```

The passing control (B2/B6): when the facts data DOES contain composition evidence compatible with the claim — the certified gluten-free tamari product form (label evidence) and tofu dairy-free — the claim clears. B5 exercises the real dataset's own fail-closed rows: stock cube (milk unknown) and a known identity with no facts row (artisan granola bar).

**Suite self-test after the merge** (regression battery incl. Part A's):

```
$ python3 suite.py --self-test
  control clean 400-recipe corpus derives all five metrics pass: held (rights_clear_recipes=pass, food_safety_linter_pass=pass, lines_with_quantity_evidence=pass, unchecked_allergen_diet_claims=pass, cuisine_time_band_coverage=pass)
  plant P2 vegan claim over chicken: caught (unchecked_allergen_diet_claims=fail)
  plant D2 dairy-free claim clears over an unresolvable ingredient: caught (unchecked_allergen_diet_claims=fail)
caught 13/13 planted failures; controls 1/1 held; part-A safety-lint battery: 4/4 plants, controls held
EXIT=0
```

P2 and D2 are now caught through the FLIngredientFacts verdict path (previously the alias-table path).

## Handoff

**Done**
- Blocker fixed: allergen/diet verdicts sourced only from FLIngredientFacts; alias table no longer clears claims; unknown name, facts-row-less identity, unknown/absent axis state, and absent/unloadable source all hold claims with source-naming reasons.
- Planted tests: red at base `9e04af4` (B1/B2 failing — verbatim above), green on the branch (7/7). Suite self-test green before and after the base merge (13/13 caught, controls held; Part A battery 4/4).
- Facts snapshot pinned verbatim at `overhaul/ingredient-facts` `b0deecce` with provenance; base merge `17953ed1` absorbed with no conflicts; diff vs the new base confined to `evaluation/suites/recipes/`.

**Not done / limits**
- The canonical facts branch may advance beyond `b0deecce`; the snapshot is pinned and `PINNED_FACTS_HEAD` records it. Re-pinning on canonical moves is the documented duty (PROVENANCE.md), not done preemptively.
- `evaluation/out/` untouched (parent regenerates the scorecard at join). No scorecard-run artifact committed here.
- Linux sandbox: no Xcode/simulator/device checks involved in this change; nothing native to verify.

**Next steps**
1. Parent: merge order A→B→…; regenerate the scorecard at the join (`evaluation/out/` is the parent's).
2. When `overhaul/ingredient-facts` lands new composition: run its conformance runner, re-pin the snapshot, update `PINNED_FACTS_HEAD` + PROVENANCE.md in one commit.
3. Sibling parts: fetch and merge `origin/eval/scorecard-runner` before your final push; resolve only within your own regions (merge commits allowed; no rebase/force-push).

Head: `1a56f06ff0b54dcea4ec2acb0a2f58a14d5264d0`

🔗 [Obvious Project](https://app.obvious.ai/p/fridgeluck-VgF1kF5T) · 🧵 [Obvious Thread](https://app.obvious.ai/p/fridgeluck-VgF1kF5T?thread=th_IUaFmgMu) · 🔀 [Obvious PR Artifact](https://app.obvious.ai/link/pr-artifact/fridgeluck-scorecard-runner-overhaul-task:todo_KPtjnO0o)
