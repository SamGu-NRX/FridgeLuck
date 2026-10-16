## 5. Adapt (scaling, time, equipment)

**What adapts.** Servings and explicit quantity evidence ("one breast, not two", "I only have 300 g pasta") — never an invented mass. Quantities carry evidence per the recipe corpus contract (weighed · source grams · household measure with a conversion · unknown); unknown quantities rescale to the same *unit text* ("2 cans → 3 cans") or hold at "check amount" when the unit isn't countable.

**Amounts.** Linear in servings by default. Three reviewed exceptions live in a small shipped rule table (`scaling-rule` entries in `contracts/scaling-rules.schema.json`), keyed by ingredient class:

| Rule | Class | Behaviour | Example |
| --- | --- | --- | --- |
| `to-taste` | salt, pepper, chili, lemon juice, "seasoning" | do not scale; caption "season to taste — didn't scale" | 2 servings → 6 servings keeps "1 tsp" |
| `sub-linear` | strong aromatics for long simmers (dried herbs, garlic past quantity 6 cloves) | scale at √(new/old), rounded to ¼ tsp | ×4 servings → ×2 herbs |
| `count-hold` | countable items where pan geometry binds (eggs for a frittata above pan capacity) | scale, but attach an equipment check (below) | 4 → 8 eggs flags the pan |

**Time.** A time changes **only** when a reviewed rule supports it (PR #86 §3.1). The rule table has three time rules, each with a source and a bound:

- **thickness** (steaks, chicken breasts pounded or not): only when the recipe states thickness and the user changed it;
- **pan size** (equipment rule below): deeper or wider pan → check earlier, cap ±25 %;
- **quantity in the pan** (two trays, two pans): batch time roughly unchanged per batch, total time +N batches; a single doubled pan load → "check, don't trust the timer".

Outside those, the step keeps its time and the caption says what the mock says: "Changed: 1 breast, same check: 74 °C" — the check stays checkable. Never a silent time change; never a percentage of doneness.

**Equipment.** Equipment comes from the recipe spec's step/equipment fields (RECONCILE, §8) or from a shipped per-recipe equipment list. Adapt checks: pan capacity (servings × volume per serving vs. stated pan), oven dish geometry, hob rings ("needs 2 pans — you noted 1"). Failure is a caption + a check, never a block: "6 servings won't fit one pan — use two, the sauce will reduce faster."

**Interaction and contract.** Adapt is a local reducer: `(session, AdaptInput) -> CookSessionMutation`, emitted as an applied change (audit row), rendered as the yolk-ink caption, and reported on the remember receipt. Live explains the change in one line when connected; offline the caption alone is the explanation. A Live *proposal* to change a quantity or time follows the §8 proposal contract and is approved on the surface, never executed by voice.

---

## 6. Substitutions

**The table ships in the app.** PR #114's reviewed table is adopted as a bundled JSON resource compiled into the app target (not fetched): `data/substitutions/pairs.json` (schema 1.1.0 — 279 cited pairs across 11 functional roles, a 381-ingredient registry with USDA SR Legacy identities, 13 restriction definitions; all OPEN-draft numbers from the PR body, re-verified against the diff on 2026-10-15). A pair is `(original, role, substitute)` — *context is structural, not free text*: the pair carries role fit (`supported_also`, each with its own evidence status and ratio), explicit role failures (`fails` with `kind: functional|conditional` and restriction scoping), required `preparation` changes, a one-sentence `difference`, and `source_ids` (≥1 per pair, validator-enforced). Evidence statuses are `sourced / convention / conflict / unsupported / unknown`, and `ContextRules.verdict` maps them to `verified | plausible | unknown | unsupported` — `unknown` is never upgraded to fit. The app-facing reviewed-swap shape LeChef consumes is `contracts/substitution.schema.json` (derived from a pair, referencing it by `pairId`). The old in-code map (`SubstitutionService.swift:80–117`, 27 hardcoded pairs) is replaced by a loader over the same IDs, keeping the legacy `Substitution` view type for compatibility where the cooking guide still renders options. Integration (`SubstitutionService` → `FLSubstitutions`) is explicitly out of PR #114's scope, so the LeChef substitution slice owns it.

**Lookup.** `SubstitutionTable.options(ingredientID:role:) -> [ReviewedSwap]`, role being the ingredient's function in this recipe (one of the 11 roles) plus the eater set. A pair matches when original and role agree; an unmatched role falls back to a `supported_also` role with its own ratio; a pair whose `fails` names this role (functional or conditional-for-a-restriction-present-at-the-table) is excluded; no match → empty, and the UI offers the Live route or nothing.

**Allergen recheck, for every eater, including compound ingredients.** Every eater's explicit restrictions (PR #86 §3.3, hard filters) are checked against the substitute's **allergen closure**: the substitute's declared allergens plus the transitive allergens of its compound parts (soy sauce → wheat+soy; pesto → tree nuts+dairy; garam masala blends carry their components). The closure comes from PR #114's registry and recheck contract: `facts_key` does an exact-name match on the normalized name against the store's identities — never fuzzy — and a null `facts_key` fails closed. The registry maps 123 of 381 records; 258 fail closed to *ask-the-user* (PR #114's own semantics). LeChef's verdict rules on top:

- **Reviewed-table swap, recheck `verified|plausible`**: ships when the closure is disjoint from every eater's restrictions.
- **Reviewed-table swap, recheck `unknown`** (no canonical record): *ask the user* — offered only with an explicit per-eater "check the label" confirmation step, never silently ("composition unknown — check the label before serving to Ada").
- **Live suggestion, any recheck other than `verified|plausible`**: blocked outright — a live suggestion never triggers the ask-the-user flow ("composition unknown — can't verify: blocked for Ada"). Absence of evidence is not allergen-free.

Allergen classes are #114's nine shared classes with wheat riding on `gluten` (soy sauce carries `soy` **and** `gluten`); wheat-specific medical notes (coeliac vs wheat allergy) ride in `allergen_note`, never as a separate class; the 13 restrictions map to the FL app vocabulary (`fl.allergens`/`fl.diets`). This recheck runs for reviewed-table swaps *and* Live suggestions; Live cannot waive it, and its recheck result is computed on the phone before display.

**Copy.** Swaps describe the difference ("a little tangier, less rich") and never promise "no change" (PR #86 §3.1). The blocked state names the eater and the compound path ("Contains wheat via soy sauce — blocked for Ada").

---

## 7. Plan

**The allocation.** Input: candidate recipes (catalog + saved + rescued), their ingredient bills for the chosen revision, current pantry lots with quantities/units/expiry/confidence, eater restrictions, the already-planned set. Output: an ordered plan of 3 dinners plus a shopping list, each line carrying a state.

Algorithm (deterministic, local, <100 ms; `contracts/plan.schema.json`):

1. **Availability pool.** Build a per-ingredient pool from eligible lots (not expired, not reserved by the already-planned set). Scans observe; only receipts/manual adds create stock (PR #86 §3.2) — allocation never assumes a scan means "more than seen".
2. **Candidate scoring.** Rank by: use-soon coverage (ingredients inside use-by horizon count triple), taste fit (explicit profile only in v1), time-in-context, restriction compliance (hard filter — zero violations). Take the best feasible dinner, or the best with swaps from §6.
3. **Reserve.** Allocate that dinner's bill from the pool, FIFO by expiry (use-soon first). Reserved quantities are removed from the pool so the next dinner cannot double count the same stock — across lines, swaps, and dinners.
4. **Repeat** for dinners 2 and 3. A dinner that can't be fully covered still ships if it has ≤2 short lines; otherwise it's replaced by "pick from saved" or pushed to the shopping list.
5. **Line states.** Every line gets one of PR #86 §3.2's states: `sufficient` · `short{amount}` · `quantity_unknown` · `assumed_staple` · `needs_reconfirming` (stale evidence past its horizon). The fit line renders from states only.
6. **Shopping list** = the merge of all `short` lines after swaps, in compatible units, minus `assumed_staple` items (struck through).

**Relation to #141/#142 and #52** (all three OPEN drafts, verified 2026-10-15). None of them double counts stock within a call — #52's `WeeklyPlanConsumption.allocate` walks slots with a locally-deducted stock copy, and #141 aggregates demand once over the whole menu and rejects duplicate lots instead of double counting. What this spec adopts from them and what it adds:

- **Adopted as the allocation mechanism** — #52's canonical allocator: slots in given order, needs sorted by ingredient id (ties by grams); unknown-quantity stock never covers anything; hard exclusions are never waived even when waiving would score higher; substitution policy is primary-if-covered, else first covering substitute, else shortfall reported; `isFeasible` fails on any required shortfall. #52's exact-optimal domain (≤6 recipes × ≤3 slots) covers the default three-dinner plan; beyond it the desirability heuristic is loudly documented as non-optimal, never passed off as exact.
- **Adopted as the line-reporting shape** — #141's `GroceryLine` numbers (required / available / allocated / missing, plus `needsConfirmationGrams` and `expiresBeforeEventGrams`) render as the §line states; #142's confirm-in-the-loop is the interaction rule: confidence never confirms a quantity, explicit review converts `needsConfirmation` → `confirmed`, edits un-confirm.
- **Duplicate policy** — duplicate lots are summed at pool build (#52's tolerant aggregate, with #52's taint rule: any unconfirmed lot makes the ingredient unconfirmed); duplicate recipe IDs are rejected (#141's stricter rule).
- **What this spec adds** — reservation *across save-and-resume*: a saved plan freezes its line states and re-allocates on open, which neither PR does; and one shared core, `PlanAllocating.allocate(_:StockPool) -> Plan`, so the three surfaces (guest dinner, three-dinner plan, weekly plan) cannot drift. #141/#142's guest surface and #52's weekly flow wrap this core; their PRs adapt input assembly and presentation only. Expiry is reported as pantry truth (#141's `expiresBeforeEventGrams`), not silently excluded; fully expired lots leave the pool.

**Plan lifetime.** Saved plans freeze their line states (they are a decision record, not a live pantry view). Cooking dinner 1 consumes its lines for real and marks dinners 2–3's reserved lines as released (re-allocation on next open). A plan older than its `needs_reconfirming` horizon re-computes on open with a "recomputed — your kitchen changed" line, never silently.

---
