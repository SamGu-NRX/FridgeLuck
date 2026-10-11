# FLTaste Design

The taste engine behind FridgeLuck's preference learning. Part 1 owns this
package; a later task moves the proven model into `FLPreferenceCore` (SPEC §7),
and the simulator (Part 2) codes against the API contract at the bottom.

Reading order for reviewers: §1 model choice → §2 exposure confound → §3
decay/expiry → §4 exploration → §5 cold start → §6 profiles → §7 API contract.

## 1. Model choice: Bayesian linear-Gaussian bandit with Thompson sampling

**The decision.** Each eater carries a Bayesian linear-Gaussian posterior over
feature weights: `A = Λ_prior + Σ w_t · (x_t x_tᵀ)`, `b = Σ w_t · r_t · x_t`,
where `x_t` is the recipe's feature vector, `r_t` the observed reward, and
`w_t` the folded evidence weight (exposure × recency × class strength).
Posterior mean is `A⁻¹b`; ranking draws weights Thompson-style. The
household ranking posterior is the element-wise mean of the per-eater
effective posteriors' means and covariances (the household eats one meal,
so the household score is the mean of eater scores); the *effective*
per-eater posterior folds in stated preferences as pseudo-observations (§6).

**Why this problem makes the decision.** One or two eaters, a few cooked
meals per week, d ≈ 120 features. After six months a heavy user has
O(10²–10³) *weighted* observations. Whatever we pick must (a) say "I don't
know yet", (b) update in closed form on a phone, (c) accept per-observation
weights (they are not optional — see §2 and §3), (d) merge two eaters
without retraining, and (e) produce per-recipe numeric explanations.

**Alternatives considered and why they lose here.**

1. **Regularized logistic regression with shrinkage toward the rule
   baseline** (`RecipeScoring`'s rank order as a prior). Trained by
   iteratively reweighted least squares — an optimization loop per ingest or
   per rank, on a phone, for a model that changes a few times a day. It has
   no native posterior: uncertainty must be bolted on (Laplace ≈ another
   Hessian inversion, or bootstrap resampling), while exploration then needs
   a separate ε-greedy policy on top. The shrinkage-to-baseline idea is
   good and we kept it — as explicit cold-start blending (§5) — but the
   estimator itself buys nothing here that the conjugate Gaussian does not.
2. **Pairwise learning-to-rank** (what a "you picked A over B" formulation
   suggests). At this event rate the pairwise dataset grows slower than the
   click stream such models assume; a week of cooking yields a handful of
   pairs, all entangled with exposure (§2). It produces a ranking but no
   calibrated absolute utility, so blending pantry fit (a *threshold*
   consideration, not a taste one) and explaining "how much" both degrade
   into heuristics. Pairwise structure is genuinely better when you have
   many implicit comparisons; we do not.
3. **Per-feature Beta posteriors** (independent thumbs-up/down per
   ingredient, cuisine, bucket). Simplest to explain, and our profile
   sentences are close to this — but as a *ranker* it cannot share evidence
   across correlated features (loving spicy + quick ⇒ loving Thai without
   ever ranking Thai directly), cannot represent interactions at all, and
   drifts feature-by-feature. The linear model's covariance does exactly the
   sharing that tiny per-feature counts cannot.

**Why the linear-Gaussian bandit wins.** Closed form: each ingest is an
O(d²) rank-1 update; ranking needs one Cholesky factorization (dense,
fixed arithmetic order — see `LinearGaussian.swift` — so factorizations are
reproducible across runs). Weights fold in exactly where they belong: in
`A` and `b` as precision-scaled pseudo-observations. Uncertainty is
native and calibrated: the same posterior drives cold-start shrinkage
(§5), exploration temperature (§4), and "this inference is thin" profile
behavior. Households merge as element-wise mean posteriors — no
retraining, no data movement. And the explanation surface falls out for
free: a contribution is `weight_i · x_i` per active feature, straight from
the weights the ranker actually used.

**Known cost.** Linear value structure cannot learn "likes quick Thai but
slow Italian" without interaction features; the feature space (v1) is
chosen so the axes that matter are separable. Nonlinearity is the first
thing to revisit if the simulator (Part 2) shows systematic residual
structure.

## 2. Availability as a confound (WEIGHTING-1)

The bandit only sees outcomes for recipes the app surfaced. If Wednesday's
suggestion was one of two shown, cooking it says far less about taste than
cooking something picked from thirty feasible options. Every behavioral
event carries an `ExposureContext` (`feasibleCandidates`, optional
`shownCandidates`); its evidence weight is:

```
w_exposure = 1.0                                  if no context or shown unknown
w_exposure = floor                                if feasibleCandidates ≤ 0
w_exposure = clamp(shown / feasible, floor, 1.0)  otherwise
```

with `exposureFloor = 0.15`. Rationale: `shown/feasible` is the
*opportunity share* — how much of the feasible set the user actually saw.
A choice from real variety (share ≈ 1) is full-strength evidence; a choice
from a nearly forced list is weak but not zero (the user still declined
every unshown feasible option they might have seen elsewhere), so the
floor keeps the observation informative without letting a forced list
 masquerade as preference. The ingest API *validates* exposure counts
(`shown ≤ feasible`, both positive) so a simulator bug cannot silently
corrupt weights. There is no negative correction for exposure — we do not
reward recipes for *not* being shown; unshown recipes simply contribute
nothing.

This is deliberately *not* inverse-propensity scoring: we do not know the
historical propensities (the iOS app's surfacing logic is a rule ranker,
not a randomizer), and IPS with wrong propensities is worse than honest
opportunity-share weighting. The simulator (Part 2) can randomize
surfacing, and its EVAL.md should report both raw and exposure-weighted
regret.

## 3. Recency, drift, and expiry

Two decay systems with different jobs:

**Posterior forget (model state).** The behavioral model's total evidence
decays with `posteriorHalfLifeDays = 90`: every refold multiplies the
effective evidence of older events by `0.5^(age/90)` (anchored at the last
event in the log, so replay reproduces exactly). This drives cold-start
blending and exploration temperature: stale models behave more like new
ones.

**Per-class evidence half-lives (reward strength and profile liveness).**
Each evidence class fades at its own rate, proportional to how
deliberate the signal is:

| Evidence class        | Half-life (days) | Why |
|-----------------------|------------------|-----|
| cooked (rating/would-make-again) | 120 | The strongest, most deliberate signal; fades slowest. |
| saved                 | 60  | Intentional but pre-commitment. |
| substituted (ingredient out) | 90 | A deliberate per-ingredient correction. |
| skipped/dismissed     | 45  | Often circumstantial (out of stock, mood). |
| LeChef feedback       | 45  | Explicit but about the *experience* (too spicy, too long), not the recipe as such. |
| opened                | 30  | Weak intent. |
| viewed                | 30  | Weakest; mostly supplies denominators. |

Profile sentences have the same property: a learned sentence stops
rendering when its evidence is past ~3 half-lives of its class (liveness
gate: `0.5^(age/halfLife) < 0.125`), so the profile can claim "you lean
toward…" only while the behavior still says so. Explicit layers never
decay: restrictions, stated preferences, and never-suggest entries are
*user* state, not evidence.

**Soft dismissal expiry.** "Don't ask again" (`neverSuggest`) is soft and
expires after `softDismissalExpiryDays = 120`: the block lifts, the recipe
becomes rankable again, and the sentence disappears (the sentence and the
ranker read the same clock, so they always agree). "This is wrong"
applies a typed correction — a pinned opposite preference, which never
expires on its own and can be reopened from the sentence.

## 4. Exploration policy

One Thompson draw per `rank` call: `θ = μ + T · L⁻ᵀ z` (with
`L Lᵀ = A`, `z` standard normals from the caller's seeded RNG), then every
candidate is scored with the *same* `θ` — one consistent exploration
taste per screen, not per-card noise.

`T = 1 + (inflation − 1) · exp(−E / decayEvidence)` with
`inflation = 2`, `decayEvidence = 8`: with almost no evidence the draw
deviates up to 2× the posterior's natural width (deliberate variety while
we know nothing); at E = 8 effective observations T ≈ 1.37; at E = 24 it
is within 5% of pure posterior sampling. Posterior width itself shrinks
as `A` accumulates, so exploration intensity decays doubly: the draw
inflation fades with evidence and the remaining variance shrinks with
precision. Cold start multiplies the draw's deviation by `λ` (§5) so the
blended mean is never swamped by a draw against a baseline we are still
mostly using.

`RankContext.explore = false` (the default is `true`) gives greedy
rankings for evaluation and the A/B surface.

## 5. Cold start

Until the household's effective evidence reaches
`coldStartEvidence = 12`, ranking blends the model mean with the rule
baseline (weights derived from `RecipeScoring`'s ordering: effort, time,
nutrition, spice, budget) with

```
λ = min(1, E / 12)
mean = λ · modelMean + (1 − λ) · baseline
```

so a brand-new household is ranked by the app's existing rules plus
popularity and pantry fit, and the learned model takes over continuously —
no cliff, no "learning mode". Popularity enters at rank time as
`popularityWeight = 0.5` on an optional per-candidate override; pantry fit
as `pantryFitWeight = 0.5` on the caller-supplied fit score. Both blend
with the learned *score* after the model; neither can bypass hard filters.

## 6. The three layers (SPEC 3.3) and how they interact

1. **Explicit restrictions** (allergies, diet exclusions): hard filters,
   applied *before* the model sees candidates. No weight configuration or
   Thompson draw can resurface a filtered recipe (tested); taste never
   weakens them; a household reset preserves them (they live in the
   explicit layer, and a "reset" in the app drops only the learned layer's
   event log). Allergen groups expand via the catalog (an allergy to
   peanuts blocks the whole peanut group).
2. **Stated preferences** ("I like shrimp", "prefer quick meals"):
   injected at **ranking time** as one pseudo-observation per active
   stated preference with noise variance 0.025 — worth about 40 unit
   behavioral observations (`Ranker.statedObservationVariance`): decisive
   over a single cook, overruled by several. They never write into the
   behavioral log, so reopening the statement restores inferred taste
   exactly. They also surface as profile sentences with a *reopen* edit.
   A stated pin suppresses the corresponding learned sentence (explicit
   beats learned for the *same* feature).
3. **Inferred taste**: the Bayesian model over everything behavioral,
   with exposure weighting (§2) and per-class decay (§3).

Edits map onto these layers 1:1 (`ProfileEditOp`): set/clear restriction,
set/clear stated preference, set/clear never-suggest. Applying a sentence's
offered edit is an ordinary profile event — replayable, idempotent,
correctable, no full reset ever required.

**Profile sentence policy (behavioral, tested).** Learned sentences need
≥ 3 denominator events (a lean/avoid claim off two observations is noise),
a ≥ 0.6 ratio, and live evidence. Like sentences: positive cooks / cooked
recipes containing the ingredient. Avoid sentences: removals / cooked
recipes containing the ingredient ("removed it 4 of the 5 times…").
Avoid wins over like when both fire. Every sentence cites its numerator,
denominator, last-seen recency, and offers exactly the edits the app
should show: this-is-wrong (pin the opposite), don't-ask-again (soft,
expiring), or reopen (clear the pin/block).

## 7. Determinism and serialization

- One `SeededRNG` (SplitMix64 + Box–Muller) per engine, threaded by the
  caller through `rank(_:rng:)`. Same seed + same events ⇒ identical
  state, rankings, and snapshot bytes.
- Snapshots are canonical JSON (fixed field order, sorted keys, fixed
  float formatting), versioned (`formatVersion`, `configVersion`), with
  forward-only migrations and a committed golden fixture
  (`Fixtures/golden-v1.json`). Round-trip byte equality and unknown-version
  fail-closed are tested.
- Feature space version `taste-features-v1`: restore rejects snapshots
  whose feature space does not match the catalog's extraction version
  (features and weights must agree or explanations lie).

## 8. Public API contract (Part 2 simulator codes against this)

```swift
// Construction
TasteEngine(catalog: RecipeCatalog, config: TasteConfig = .standard)
TasteEngine(snapshotJSON: String, catalog: RecipeCatalog) throws   // restore

// Ingest (idempotent by event ID; batch order inside a call is irrelevant —
// the fold canonicalizes by (timestamp, id); corrections reference targets)
mutating func ingest(_ event: TasteEvent)
mutating func ingest(_ newEvents: [TasteEvent])

// Ranking
func rank(_ input: RankInput, rng: inout SeededRNG) -> [RankedRecipe]
//   RankInput: candidates + optional pantryFit / popularityOverride /
//   RankContext (now, explore). Hard-filtered candidates are dropped
//   before the model sees them. RankedRecipe carries recipe, score,
//   explanation contributions (feature, value, weight, evidenceCount),
//   pantryFit, popularity, wasBaselineOnly.
func profile() -> TasteProfile
//   Sentences with evidence (numerator/denominator/lastSeen), provenance,
//   and typed edits (thisIsWrong / dontAskAgain / reopen).

// Persistence
func snapshotJSON() throws -> String          // canonical bytes
public private(set) var events: [TasteEvent]  // the append-only log
```

Simulator rules: always pass the `SeededRNG` explicitly (never default
seeds in experiments); pass `ExposureContext` on every behavioral event —
omitting it asserts "no exposure constraint" and inflates evidence; use
`explore: false` for counterfactual measurements; restore from
`snapshotJSON` bytes, never by re-folding a mutated log.

## 9. What v1 deliberately does not do

- No sequence effects (what you ate *yesterday* suppressing a repeat is
  approximated only by repeat affinity decay).
- No per-eater exposure contexts beyond the event's own (household merges
  assume comparable exposure).
- No contextual bandit over *ranked lists* ( SlateRF / cascade models):
  position effects are not modeled; the app shows few recipes per screen,
  and the simulator should keep position effects out of its scoring for
  now.
- Corrections do not yet reach the *behavioral* model (v1 corrections
  amend the explicit layer; the comment in `TasteModel.observation` marks
  the seam).
