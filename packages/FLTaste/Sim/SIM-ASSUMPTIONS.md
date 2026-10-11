# SIM-ASSUMPTIONS — what `FLTasteSim` assumes, and why

Every knob of the household simulator, its default, and where that number
comes from. Three status labels:

- **[F8]** — calibrated to overhaul finding 8: *"At three cooks a week, week 1
  has at most three cooks and month 3 about 39, with perhaps 13 ratings."*
- **[F5]** — calibrated to finding 5's 10-slot surface.
- **[A]** — documented assumption. Reasonable, reproducible, and safe to sweep
  in evaluation sweeps; nothing downstream should treat it as measured.
- **[S]** — structural choice (a mechanism, not a number); change it only with
  a matching change to the scorer's story.

Nothing here is measured user data. The point of the simulator is a *honest
synthetic household*: strong enough structure to make ranker evaluation
meaningful, explicit enough assumptions that a bad number can be blamed and
changed.

---

## 1. Ground rules

- **Deterministic.** Same seed + config + ranker ⇒ byte-identical event JSONL
  and ground-truth JSON. All randomness flows from `SimConfig.seed` through
  named `SeedDeriver` child streams (see §9). No wall clock, no system RNG.
- **No learning model.** The simulator never ranks by itself; rankers are
  injected through the `Ranker` protocol (Part 3's arms). The two shipped
  reference rankers are deliberately trivial baselines.
- **Foundation-only, Linux-first.** Verified on Linux x86_64, Swift 6.4,
  XCTest. Anything needing macOS/Xcode is labelled UNVERIFIED-NATIVE, and
  none of the simulator's own tests need it.
- **Recipes are input.** The simulator accepts Part 1's `RecipeCatalog`; the
  app corpus (`apps/ios/Resources/data.json`, 166 recipes, 50 ingredients) is
  loaded read-only and never vendored or edited.

## 2. Household and world

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `householdSize` | 2 | [A] | FridgeLuck serves one- and two-eater households; 2 exercises the union path. Sweep 1/2. |
| `restrictionProbability` | 0.6 | [A] | Per-eater chance of one hard restriction at setup (allergy or diet). High enough that hard filters bind in most runs; sweep 0…1. |
| `cooksPerWeek` | 3.0 (Poisson mean) | **[F8]** | "Three cooks a week" is the finding's anchor number. Poisson draws are capped at 7 days/week. |
| `shopMealsPerWeek` | 4 | [A] | One more than the mean cook rate: the pantry *usually* covers the week but not always, so availability genuinely binds. 3 would starve; 6 would never bind. |
| `weeklyBudget` | 18.0 | [A] | Prices are synthetic (see §3); this buys four planned meals with slack. Sweep to stress feasibility. |
| `pantryShelfLifeWeeks` | 2 | [A] | Long enough that bought meals usually get cooked, short enough that stock rotates and spoilage exists. |
| `slateSize` | 10 | **[F5]** | Finding 5's 10-slot suggestion surface. |

## 3. Money is a proxy

**[A][S]** The recipe corpus carries no prices, so `PriceModel` prices
ingredients from nutrition roles: protein-rich (≥ 10 g protein/100 g) at
0.011, fat-rich (≥ 30 g fat/100 g, when not protein-rich) at 0.009, staple at
0.0035 (synthetic currency units per gram). A protein-heavy 400 g recipe
component costs ≈ 4.4; the default budget buys about four such meals. The
price *structure* (protein > fat > staple, per gram, budget-capped at
shopping time, optional garnishes unpriced) is what the evaluation needs; the
absolute numbers are arbitrary and documented here so no one mistakes them
for market data.

## 4. The decision surface (per cook session)

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `attentionProbability` | 0.85 | [A] | Share of sessions where the chooser actually reads the slate. The rest habit-cook (no slate, no exposure evidence) — the mechanism that makes "cooked what was shown" weak evidence. |
| `choiceTemperature` | 0.35 | [A] | Softmax temperature over true utility, in utility units (typical utilities span ±1). Decisive but far from deterministic: the exact top-utility share at defaults is pinned by `testChoiceIsTasteDrivenAtDefaultTemperature`. The single most consequential [A]: sweep 0.2…0.6. |
| `positionBias` | 0.05 | [A] | Utility bonus per slot from the top. Small: position matters, taste matters more. |
| `exposureWeight` | 0.10 | [A] | Mere-exposure contamination: `w·log(1 + priorExposures)`. Repeatedly shown items get picked a little more, independent of taste — the confound exposure-aware learning must remove. |
| `availabilityWeight` | 0.15 | [A] | Use-it-or-lose-it contamination: `w·log(stockFactor)` — ingredients about to spoil nudge the pick. |
| `skipSessionProbability` | 0.5 | [A] | Share of attended sessions that end in a typed skip, no cook. High enough to make cook counts meaningfully below exposure counts. |
| `extraOpenProbability` | 0.3 | [A] | Share of chosen sessions that also detail-view one other slate item (comparison browsing): the "opened but not cooked" evidence class. |

Skip reasons are typed and drawn 40 % `outOfTime`, 40 % `changedMind`,
20 % `missingIngredients` **[A]** — mostly life, sometimes stock.

## 5. Ratings and cook-complete answers

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `ratingProbability` | 1/3 | **[F8]** | "Perhaps 13 ratings" in ≈ 39 month-3 cooks. |
| `ratingNoiseSigma` | 0.75 | [A] | Gaussian noise on the latent scale before quantising. Same order as the utility spread itself: ratings are *inconsistent* but not random. Sweep 0.4…1.0. |
| `ratingSlope` | 0.8 | [A] | Utility→stars slope: stars = clamp(round(2.5 + 0.8·u + raterBias + noise), 1…5). |
| `wouldMakeAgainProbability` | 0.5 | [A] | Share of cooks that also answer the cook-complete question. |
| `wouldMakeAgainMidpoint` / `wouldMakeAgainSlope` | 0.0 / 0.7 | [A] | Logistic on latent utility: u = 0 ⇒ 50/50, u = +1 ⇒ ≈ 2/3 yes. |
| `raterBias` | ±0.25·N(0,1) per eater | [A] | Fixed per-eater offset drawn at setup (recorded in ground truth): one eater rates stingier than the other. Rater bias is a rating-model term, not taste. |

Every rating's anatomy — latent mean, rater bias, exact noise draw — is
recorded in ground truth, and a test reproduces every star from it. Sparse +
noisy + biased is the *point*: the learning arms must handle all three.

## 6. Other behavioural events

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `substitutionProbability` | 0.15 | [A] | Share of cooks that swap one required ingredient. The swap targets the recipe's least-liked (lowest household-mean latent weight) required ingredient; the substitute is a random stocked pantry ingredient (nil when none — the app allows a free-text "didn't have it"). |
| `preferredSubstitutionProbability` | 0.5 | [A] | Preferred-vs-necessary mix; the two carry different evidence and the app asks which. |
| `leChefFeedbackProbability` | 0.12 | [A] | Rare structured feedback. The type is heuristic, not modelled: too-bland when the cook's utility was negative, else took-too-long when the recipe exceeds 45 min, else portion-wrong/other. Feedback *existence* is the signal; its type semantics are [A]. |
| `saveProbability` | 0.12 | [A] | Share of eligible cooks (utility ≥ `saveUtilityThreshold` = 0.8 [A]) that save the recipe. Saves are strong positive evidence, hence rare and utility-gated. |
| `doubleServingsProbability` | 0.08 | [A] | Leftover batches; doubles pantry consumption. |
| `neverSuggestProbability` | 0.3 | [A] | Share of bad cooks (utility ≤ `neverSuggestUtility` = −1.0 [A]) that harden into a "don't ask again" write on the least-liked required ingredient. Rare, strong, explicit. |

## 7. Dynamics

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `driftPerWeek` | 0.02 rad/week | [A] | Slow taste drift: each eater's latent vector rotates by this angle per week in an eater-specific pseudo-random plane. Norm-preserving (taste strength never grows), 0.02 rad/week ≈ 0.26 rad over 13 weeks — a slow turn, not a jump. Rotation is [S]; the rate is [A], sweep 0.005…0.05. |
| `shifts` | `[]` | [S] | Mid-history changes, applied at the start of their week, in config order. Three kinds: `.diet` (hard restriction added; the app sees a `profileEdit(.setRestriction)` event), `.budgetChange` (weekly budget × factor, persistent until changed again), `.lostCapability` (recipes whose instructions contain the needle become infeasible — "the oven broke"). |

The canonical example, from the overhaul's "went vegetarian" scenario:
`[.diet(eaterIndex: 0, diet: .vegetarian, week: 3)]` on a 13-week run.

## 8. Run shape

| Parameter | Default | Status | Rationale |
|---|---|---|---|
| `weeks` | 13 | **[F8]** | Month 3 of finding 8: ≈ 39 cooks, ≈ 13 ratings per household at defaults. |
| `seed` | 1 | — | Master seed for all streams. |
| `startMillis` | 2026-01-01T00:00:00Z | — | Fixed epoch, never the wall clock. |

## 9. Draw order (the determinism contract)

Per week, in order:

1. **Shifts** (config order) — apply to world/household; diet shifts emit the
   `profileEdit` event.
2. **Drift** — each eater's latent rotates once. The rotation plane is
   re-derived deterministically per (seed, eater), not drawn from a stream, so
   any future change to weekly logic cannot perturb it.
3. **Shopping** — `shopping` stream: plan `shopMealsPerWeek` meals by
   utility-weighted sampling without replacement (temperature
   `choiceTemperature`), then buy what the budget allows.
4. **Cook sessions** — `session` stream: Poisson cook count (Knuth inversion),
   cook days (Fisher–Yates shuffle of 0…6, sorted), then per session, in
   order: attention → skip? → skip reason? → slate choice → extra open? →
   substitution? (`to` draw) → preferred-vs-necessary → rating? →
   would-make-again? → save? → double servings? → LeChef? → never-suggest?
5. **Ratings** — `rating` stream: the noise draw and the would-make-again
   draw, separate from the session stream so rating sparsity can be swept
   without perturbing behaviour.

Ground truth records everything above a scorer needs: latent snapshots each
week, per-session feasible sets / slates / choice probabilities / true
rankings, rating anatomy, shift records, missed-cook counts.

## 10. What is deliberately NOT modelled

- **Weekday/seasonal patterns** — cook days are uniform; no "Sunday roast"
  effect beyond recipe-level time cost.
- **Meal-frequency repetition structure** — beyond the habit-cook mechanism,
  nothing forces weekly rotation the way real households cycle cuisines.
- **Two-eater negotiation** — the union of restrictions and the mean of
  latents shape choices; no per-session "who wanted what" conflict dynamics.
- **Shopping substitution** — the shopper buys planned meals only; no
  "they were out of X, bought Y" at the store (in-store swaps surface as
  cook-time substitutions).
- **Nutrition, health goals, and portion sizes** — out of scope for ranking
  evaluation; `editedServings` doubles only.
- **Cold-start app behaviour** — the simulator emits the events; how the app
  bootstraps a brand-new user is Part 1/Part 3 territory.

## 11. Sweep guidance for Part 3

- Keep **[F8]/[F5]** numbers fixed (cooks/week 3, rating rate 1/3, slate 10,
  13-week horizon) so campaign numbers stay comparable to finding 8's
  arithmetic.
- The first sweep axes, in order of expected sensitivity:
  `choiceTemperature` (0.2…0.6), `ratingNoiseSigma` (0.4…1.0),
  `exposureWeight` (0…0.3), `attentionProbability` (0.6…1.0).
- Shift scenarios are part of the campaign design, not the simulator's
  defaults: run arms with and without `.diet`/`.budgetChange`/
  `.lostCapability` to separate adaptation from steady-state ranking.
