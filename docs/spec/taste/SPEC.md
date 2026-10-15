# Taste Profile & Learning — SPEC

Status: draft · Engine: `taste-residual-v1` · Contracts: [`contracts/`](contracts/) · Branch: `obv/burst5-fridgeluck-spec-taste` (base `alpha`)

---

## 0. Load-bearing assumption

**The claim this spec bets on:** a *rule-anchored residual ranker* — today's rule score plus small, bounded, evidence-weighted feature adjustments — will improve personalization without repeating the learned-ranker regression we already measured. Evidence that supports it: the learned FLTaste arm trailed the production rule ranker by ~11% NDCG@10 in the reduced campaign (preregistered activation gate unmet), so full learned re-ranking is exactly the thing that failed at our data scale. Evidence that would confirm the assumption post-hoc: the residual layer's bounded contributions stay small in replay while producing measurable pairwise-order improvements on the same reduced campaign. Evidence that would break it: if replay shows even the bounded residuals changing top-10 composition by more than a few percent, the data is still too thin to learn from at all, and this design should not ship — no amount of capping fixes a starving learner. Adjacent explanations the brief skipped, named once here: the FLTaste regression may have been a ranking-arm implementation artifact rather than a data-starvation effect (the residual design limits the blast radius either way), and rule-score quality itself may be the dominant factor (out of scope here; covered by the health-ranking sensitivity study).

## 1. Problem

FridgeLuck recommends recipes from a rule ranker (stock, expiry urgency, servings, time, allergens, diet fit). The rule ranker treats every household identically. Household taste signal exists in the event stream — cooks, ratings, saves, skips, substitutions — but nothing consumes it: a household that has rated three coriander-heavy meals 1–2 stars keeps seeing coriander recipes ranked the same as everyone else's.

Two prior attempts frame the constraint. A full learned ranker (FLTaste) went live behind a gate and trailed the rule ranker by ~11% NDCG@10 on the reduced campaign; the trust-vector arm placed second. Both were starved: typical households generate on the order of tens of informative events per quarter, not thousands. The lesson we act on: **personalization must start at today's behavior and earn deviations slowly.**

## 2. Design: rule-anchored residual ranking (`taste-residual-v1`)

### 2.1 Structure

Total score = rule score + learned contribution:

```
totalScore(recipe) = ruleScore(recipe) + Σ_features contribution(feature)
```

- `ruleScore` is the existing rule ranker's output, unchanged. Cold-start behavior (no events) is byte-identical to today.
- Each catalog recipe carries zero or more `featureKey`s of the form `<class>:<id>`, e.g. `ingredient:101` (coriander), `cuisine:indian`. Feature classes: `ingredient`, `cuisine`, `technique`, `time`, `nutrient`, `spice`, `tool`, `other`.
- Feature posteriors are per-feature Beta distributions, `Beta(alpha, beta)`, starting from the uniform prior `(1.0, 1.0)` and updated only by evidence (2.3).

### 2.2 Contribution math (normative)

Constants (also encoded in `contracts/check.py` and the golden fixture):

| Constant | Value | Meaning |
|---|---|---|
| `H` (half-lives, days) | cook_rating 60 · cook_no_rating 30 · saved 45 · skipped 14 · substitution 45 · lechef 45 · open 7 · view 7 | Exponential decay per evidence class: `decay(dt) = 2^(−dt/H)` |
| `strength` | cook_rating 1.0 · cook_no_rating 0.3 · saved 0.4 · skipped 0.2 · substitution 0.5 · lechef 0.4 · open 0.15 · view 0.08 | Evidence weight |
| `CAP[class]` | ingredient 4.0 · cuisine 3.0 · technique 2.0 · time 2.0 · nutrient 2.0 · spice 2.0 · tool 1.0 · other 1.0 | Max magnitude of one feature's contribution |
| `K_SHRINK` | 3.0 | Evidence shrinkage constant |
| `GLOBAL_CLAMP` | 8.0 | Max |Σ contributions| per recipe |

**Update.** For a cooked meal with rating `r ∈ [1,5]`: reward `ρ = (r−1)/4`, weight `w = exposureShare × strength`, applied to every feature of the recipe:

```
alpha ← alpha·decay(Δt/H) + w·ρ
beta  ← beta ·decay(Δt/H) + w·(1−ρ)
```

`Δt` is time since the feature's last update (lazy decay). `exposureShare = |slate| / |feasible|` of the logged exposure, floored at 0.15, so being one of two shown options counts more than one of forty feasible ones — availability is not preference.

A cook with no rating is its own evidence class (reward fixed at 0.6 "it got made", strength 0.3, H=30). Ratings arriving later via `recipe_rated` merge into the cook's transaction window (same `cookEventId`); a rating event updates the same posterior at strength 1.0 with its own timestamp.

**Contribution.** At ranking time, decay each feature to the evaluation instant, then:

```
n  = alpha + beta
μ  = alpha / n
d  = 2μ − 1                                (direction, −1…+1)
c  = n / (n + K_SHRINK)                    (shrinkage: 0…1, few observations → ~0)
contribution(feature) = clamp(d · c · CAP[class], ±GLOBAL_CLAMP)
```

Properties this buys: small evidence nudges but never overturns (three bad cooks move `ingredient:101` by −0.65 against rule-score gaps of 2–3 points); a feature cannot dominate its class cap; stale evidence fades at the class half-life; cold start is exactly today's ranking. **All floating-point outputs are canonicalized to 6 decimals, round-half-even** — the golden fixture and checker enforce this, and implementations in Swift and TypeScript must match it for parity.

### 2.3 Evidence taxonomy

Consumed kinds and their effect on posteriors (class constants in the table above): `recipe_cooked` (with/without rating), `recipe_rated`, `recipe_saved`, `recipe_unsaved` (reverses a save), `recipe_skipped` (shown but not taken), `ingredient_substituted` (per-ingredient: away-from feature penalized, substitute rewarded, when motivation is `preferred` or `none_available`; ignored for `recipe_recommended`), `lechef_feedback` (tags `too_bland`/`too_spicy` map to salt/spice class features), `recipe_opened`/`recipe_viewed` (weak exposure signals only, never strong enough to act alone: at strength 0.15/0.08 with H=7 they wash out in days). `servings_edited`, `profile_edited`, and `correction_applied` do not touch posteriors — they configure or correct (§4, §5).

**Restrictions are not taste.** Hard restrictions (allergies, diets, absences) stay pre-ranking filters, exactly as today. They are never learned, never down-weighted by counter-evidence, and never rank-order anything; taste can only reorder feasible recipes.

### 2.4 Exposure logging

Every recommendation surface (`home.tonight`, meal-plan slots, search) logs an `exposure` record: the shown `slate` (ordered), the full `feasible` set the ranker chose from, and the decision context. `feasible` is what makes correction possible: without it, "recipe X wasn't shown" is indistinguishable from "X was ranked below Y", and every downstream inference silently conflates availability with preference. Skips and views resolve against their `exposureId`.

## 3. Worked example (golden fixture)

`contracts/examples/golden-fixture/coriander-v1.json` is the normative worked example, generated by `contracts/gen_examples.py` (model math mirrored verbatim) and enforced to 6 decimals by `contracts/check.py`.

Household cooks three coriander meals in five weeks — rated 2, 1, and 1 stars, each cook in the same transaction as its meal log, each against a logged exposure (shares 2/4, 1/4, 1/2). Updates use the 60-day cook-rating half-life: lazy decay between events (20 and 15 days apart) and one final decay to the evaluation instant. Result: `ingredient:101` posterior alpha 0.750847, beta 1.627927 (mean 0.316, direction negative, c = n/(n+3)), contribution **−0.652252**; `cuisine:indian` (one observation on the first meal) contributes −0.107221. Ranking: R1 62.240527, R3 60.347748, R2 60.0, R4 55.0 — the learned layer reorders nothing yet, which is the point: three bad meals nudge; the rule ranker still decides. After a fourth or fifth bad coriander meal (n ≈ 5, c ≈ 0.62) the contribution passes −2.5 and starts flipping pairwise order between rule-adjacent recipes.

The same fixture demonstrates profile rendering (§4): coriander's denominator (3 cooked meals with the feature) clears the evidence bar, so `taste.lowrating.hedged` renders; `cuisine:indian` has denominator 1 and is hidden as `thin-evidence`.

## 4. Profile statements

The profile the user sees is a list of **statements**, three layers, each with distinct truth sources and editing rules:

1. **Restriction** — set at onboarding setup, edited only in setup. Never machine-written, never suggested. Hard filter (§2.3).
2. **Inferred** — machine-written from evidence. Each carries `numerator` / `denominator` (how the claim was earned) so it is inspectable and correctable. Display rules: render only when denominator ≥ 3 cooked recipes containing the feature AND ratio ≥ 0.6 AND last evidence within 3 × class half-life; hedged wording below 10 denominators, confident above. Hidden states and reasons (`thin-evidence`, `stale-evidence`, `muted`) are machine-visible but not rendered.
3. **Pinned** — user-set overrides ("never suggest X", "always prefer Y"), carrying an explicit `pinnedValue` in [−8, +8] applied like a feature contribution, and optionally `mutedUntil` (do not surface again before this time).

**Correction is a first-class operation.** Any statement can be marked wrong (`correction_applied`), which mutes it and records the correction as an event; inferred statements regenerate only from the corrected rule set, and corrections replay deterministically (the golden fixture's `input` is exactly the replay input). The profile never states a reason the evidence does not show: if the schema field is null, the sentence must not claim a number.

## 5. Privacy and household

All posteriors, exposures, and statements are **on-device** (GRDB tables in the local store), computed on-device, backed up only through the existing local backup archive. No event, exposure, or posterior leaves the device: the backend never receives taste data, and shared/cook payloads remain redacted as in the community core contracts. Multi-eater households: events carry `eater`; `taste-residual-v1` scopes posteriors to a single composite profile ("you" = the household cook) — per-person profiles are future work gated on eater tagging coverage. Telemetry, if any is ever added, is aggregate and opt-in; nothing in this design requires it.

## 6. Deterministic verification

Everything in §2–§4 is pinned by machine-checkable contracts in [`contracts/`](contracts/):

- Schemas (JSON Schema draft-2020-12 subset, local `$ref` only): `taste-event.schema.json` (12 event kinds, discriminated by `kind` with per-kind payload properties), `exposure.schema.json`, `profile-statement.schema.json`, `golden-fixture.schema.json`.
- `contracts/examples/` — 17 validated fixtures: one example per event kind, one exposure, one statement per layer, and the golden fixture.
- `contracts/check.py` — standard-library-only (see `contracts/requirements.txt`): validates every example against its schema, enforces canonical 6-decimal floats and ISO-8601 UTC timestamps, checks statement invariants (numerator ≤ denominator, inferred requires counts, pinned requires `pinnedValue`), and **re-runs the reference model over the golden fixture's input and byte-compares the expected feature state, ranking, statements, and hidden list at 6-decimal precision**.

Run: `python3 docs/spec/taste/contracts/check.py` — exit 0 = all examples valid and self-consistent. A deliberately corrupted copy of the fixture fails the recompute comparison (verified below). `gen_examples.py` regenerates examples; the generator and the checker implement the model independently from the same constants, so a change to §2.2 that isn't reflected in both fails.

## 7. Alternatives considered

- **Linear-Gaussian learner (FLTaste-style weights):** maximally expressive; already failed the activation gate at our scale (~11% NDCG@10 deficit), and per-feature drift is unexplainable to users. Rejected for now; re-testable when event volume grows — the residual framing is compatible with swapping the contribution source later.
- **Beta trust-vector (second-place arm):** similar family to this design but ranker-global rather than feature-residual; weaker cold-start story and no per-feature statements for the profile UI. Superseded by 2.2.
- **Do nothing until data volume justifies full learning:** defensible; the cost is every household gets the rule ranker's behavior for quarters. The residual design costs little (bounded, explainable, reversible via corrections) and starts compounding evidence immediately.

## 8. Scope and out of scope

In scope: the ranker contract (§2), exposure logging (§2.4), profile statements and correction (§4), on-device persistence semantics (§5), and the deterministic contracts (§6). Out of scope, deliberately: UI screens (a taste-profile mock exists in `docs/spec-overhaul-20261011/`), per-person profiles, backend sync of taste data, the rule ranker's internals, feature-tagging pipeline for the catalog (feature keys are assumed present; their coverage is a separate evaluation), and any CI/deploy configuration.

## 9. Adversarial review

Self-review against a red-team checklist; findings and dispositions:

- **Exposure-share floor gaming.** A floor of 0.15 on a 40-recipe feasible set means an option nobody saw still trains the posterior when skipped. Disposition: skips only apply to slate members (exposureId resolves to shown items); the floor only softens *cook* credit on large feasible sets, where relative differences between shares are small.
- **Double counting cook + rating.** A cook and its later `recipe_rated` would train twice. Disposition: rated cooks consume the rating in the cook's transaction window (same `cookEventId`); the checker's fixture uses this path; a stray late rating for an already-rated cook is a correction, not new evidence.
- **Replay order sensitivity.** Posteriors depend on event order. Disposition: events sort by `(at, id)`; the golden fixture pins the tiebreak; out-of-order ingestion is reordered, never dropped.
- **Statement over-claim.** "You seem to go off coriander: the last 3 recipes…" — if the denominator were actually 5 with 2 good meals, the sentence lies. Disposition: hedged template is reserved for numerator = denominator; the confident template names both counts; `check.py` recomputes both fields from events.
- **Pinned values overpowering learning.** A user pin (+8) on a class with cap 4 could swamp everything. Disposition: `pinnedValue` range is [−8, +8] and counts toward `GLOBAL_CLAMP`; at most a couple of pins fit before the clamp saturates.
- **Feature-coverage asymmetry.** If catalog tagging covers ingredients but not cuisines, learning looks biased. Disposition: out of scope (§8) but flagged: the tagging-coverage evaluation must precede activation, and contribution reporting per class makes asymmetry visible in replay.
- **The 6-decimal parity contract.** Swift `Double` rounding and JS `Number` differ from Python's banker's rounding in edge cases. Disposition: fixtures avoid exact-half cases at the 7th decimal by construction; parity tests in implementation PRs must reproduce the golden fixture byte-for-byte via decimal-fixed formatting, not native float printing.

## 10. Verification performed on this branch

Actually run (Linux, repo sandbox):

- `python3 docs/spec/taste/contracts/gen_examples.py` — regenerated all 17 examples and the golden fixture; fixture values: alpha 0.750847 / beta 1.627927, contribution −0.652252, ranking totals 62.240527 / 60.347748 / 60.0 / 55.0.
- `python3 docs/spec/taste/contracts/check.py` — `checked 17 examples … all examples valid and self-consistent`, exit 0.
- Negative test: corrupted a copy of the golden fixture's `totalScore` (+0.5) and ran the checker from a temp copy — exits 1 with `ranking mismatch`, as intended.
- `git log`/`git status` reviewed before commit; all work is new files under `docs/spec/taste/`, no existing app or backend code touched.

Not run, with reasons:

- Any Swift/TypeScript implementation or test: this PR is spec + contracts only; there is no implementation to compile. The golden fixture's parity role (§6, §9) is what implementation PRs must satisfy.
- No Xcode/macOS in this environment: nothing here builds iOS code, so hosted macOS CI is not expected to exercise these files beyond whatever docs lint exists.
- JSON Schema conformance against the full draft-2020-12 spec: `check.py` implements the subset these schemas use (types, enums, patterns, bounds, required, `additionalProperties: false`, local file `$ref`); full validators (e.g. `jsonschema`) were deliberately not added as a dependency.

Assumptions: feature keys (`ingredient:101` = coriander, `cuisine:indian`) are illustrative identifiers for fixture purposes, not catalog IDs to resolve; evaluation time in the fixture is the last event's timestamp to stay deterministic; "reduced campaign" NDCG figures are cited from the recorded PR evaluation reports, not re-measured here.
