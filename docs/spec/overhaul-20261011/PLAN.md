# FridgeLuck overhaul: plan, evals and rounds

This plan carries `SPEC.md` (what we build and the contracts it keeps) to the end. It covers the goal, the evals that decide "best", the rounds, the directions each round tries, and when to stop. Task prompts quote it.

## End goal

A FridgeLuck that someone would keep on their home screen, running end to end on `alpha` in the iOS simulator:

- scan your kitchen, then get one honest pick for tonight;
- cook it with LeChef doing real jobs (plan, substitute, coach, adapt, remember);
- see what the app learned about you and correct it;
- cook from a catalog several times larger, safe and rights-clear;
- share with a small table or run a three-ingredient challenge;
- the whole interface rebuilt to the design direction and polished.

## Branches

- `alpha` is the integration branch, cut from `main` (2fd0dfe) on 2026-10-11. Nothing deploys from it:
  - the only workflow, `ios-ci.yml`, runs on PRs and on pushes to `main`;
  - the repo has no GitHub environments or deployments;
  - `cloudbuild.yaml` builds an image without deploying;
  - `deploy-cloud-run.sh` only runs by hand.
- Accepted work merges into `alpha` with `--no-ff` after the caretaker's pass. Never into `main`.
- New tasks start from `alpha` and target it.

## The scorecard (evals first)

One runner, `evaluation/run.py`, built by `fl-eval-harness-f1`, writes `evaluation/out/scorecard.json` and `scorecard.md`.

- Each suite reports its metrics, its pass bar, pass or fail, the artifact identity (git SHA, toolchain) and how long it ran.
- A suite whose inputs don't exist yet reports `not-run` with the reason, never `pass`.
- Tasks report their results through their suite.

| Suite | What it runs | Pass bar (first release) |
| --- | --- | --- |
| A. Pantry truth | Seeded property tests over random pantries and recipes; a hand-labelled audit set of 200 pantry and recipe pairs | 0 stock counted twice; 0 "sufficient" without evidence; fit-line text correct on 200 of 200 |
| B. Learning | Frozen simulator suite: 5,000+ households, 20 seeds, regimes for sparsity, drift, two eaters and exposure bias | Engine beats the current rule ranker and explicit-profile-only on NDCG@10 among feasible picks, with the 95% interval above 0 and at least +10% relative; 0 restriction violations; recovers from a taste shift within 6 cooks (median) |
| C. Recipes | Corpus validator, rights records, food-safety linter, substitution coverage, distributions | At least 400 rights-clear recipes, growing toward 1,500; 100% pass the linter; at least 95% of lines resolved with quantity evidence; 0 unchecked allergen or diet claims; every cuisine and time band in SPEC 3.5 represented |
| D. LeChef | At least 150 scripted cook sessions against a fake model provider: the five jobs, offline, interruptions, adversarial text, timers | 0 food-safety violations; 0 actions executed without approval; at least 90% job success; 100% timer correctness across kill and resume |
| E. Community | Two- and three-account scenarios on the Firestore emulator: add and publish a recipe, moderation before it goes public, Explore, share, table, invite, challenge (and battle votes in direction b), report, block, delete | 0 private-field leaks; 0 authorization failures; every moderation transition covered |
| F. UI polish | macOS CI renders of every screen and state (paper, dark, hob, XXL Dynamic Type); automated checks; council taste review | Body-text contrast at least 4.5:1; touch targets at least 44 pt (64 pt in cook mode); no clipped primary labels at XXL; the chosen direction's own rules hold; Sam picks the direction and the council calls ship on every screen |
| G. Journeys | XCUITest journeys in the simulator from `alpha`, with fixture photos, screenshots at every step, on macOS CI and on the lead's Mac | All of these pass with no crash: first run, scan and review, Tonight, recipe, cook, complete, share, challenge, taste-profile edit |

The bars are the lead's choice, not measured optima. A suite can only move a bar with a recorded reason.

## Rounds

**Round 1** (queued 2026-10-11, about 11:30Z). Each task tries the directions listed:

- `fl-eval-harness-f1`:
  - the scorecard runner;
  - suites A, C, F and G and their fixtures;
  - suites B, D and E are wired as the owning tasks deliver them.
- `fl-learning-lab-f1`, suite B. Two problems.
  - Recognition confidence: Sam's Beta trust vector as built (`ConfidenceLearningService`, harnesses in PRs #7 and #53) against alternatives.
  - Taste, with these model families compared inside one campaign:
  - Sam's trust-vector design applied to taste: Beta posteriors per source and feature;
  - Bayesian linear model with Thompson sampling;
  - regularized logistic regression with shrinkage;
  - pairwise learning-to-rank;
  - a small embedding model.
- `fl-lechef-f1`, suite D. Three LeChef designs as competing sub-threads on one tool layer:
  - a cook-mode companion;
  - a planner-first kitchen manager;
  - a proactive use-it-up coach;
  - camera modes compared across the designs: push-to-look versus continuous camera plus voice (Sam's stage-4 second priority).
- `fl-recipe-platform-f1`, suite C. Licensed ingestion and original recipes written with verification, compared by yield and quality. User-added recipes are the third source; the core build and the community service own that path. The bundled catalog is flagged as a rights risk (SPEC 10).
- `fl-core-build-f1`, suites A, D and E on the client side.
- `fl-design-build-f1`, suite F. A visual round first:
  - Direction P, Sam's approved pastel palette rebuilt;
  - Direction F, the prep list;
  - an optional hybrid;
  - Shell F and Shell S;
  - quests and badges, and a constrained tour, as candidates.
  
  All are rendered on the same screens for Sam to compare. The design system is then built with the chosen tokens, kept swappable until he picks.
- `fl-community-f1`, suite E. The community service: user recipes, publishing with moderation, Explore, challenges, Tables. Three competing directions:
  - (a) Explore-first;
  - (b) recipe battles with voting;
  - (c) campus challenges with waste counters.
- `fl-integration-f1`: the trunks, the ledger, and the #44, #45 and #85 continuations.

**Council 1**, after Round 1's Handoffs:

- Fable: taste-check of the renders and the running app.
- Astra: product logic and the safety and learning claims.
- Sol: engineering and test review.
- Opus (the lead): integration.

The council recommends winners (LeChef design and camera mode, learning model, community direction, and a visual direction for Sam to pick) and grafts the best ideas from the others. Accepted PRs merge into `alpha`, and the lead runs it in the simulator.

**Round 2**, aimed at what the scorecard and council say is missing:

- host integration: the new screens and FridgeLuckCore wired into the app on `alpha`;
- the winning LeChef wired end to end;
- the shipped learning model with event instrumentation;
- recipe scale-up toward 1,500;
- polish tasks from the council's critique.

**Round 3 and later**: polish and the remaining gaps, until the stop rule fires.

## Directions held in reserve

Used only if a round shows the need:

- Server-side collaborative recommendations, only after real usage exists. Not for the first release.
- A synced household pantry, if Tables show that people share kitchens.

## Stop rule

Stop a workstream when:

- its suite meets its bar and the council calls it ship; or
- two consecutive rounds don't move its suite's metrics.

Record which condition fired and why in this file. The overhaul is done when every suite passes and suite G runs clean on `alpha`.

## Log

- 2026-10-11 10:00Z: spec inputs from Fable, Sol and Astra; `SPEC.md` decided.
- 2026-10-11 11:30Z: Round 1 queued.
- 2026-10-11 11:30Z: SPEC revision 2. Sam's own asks are restored as competing directions: user recipes and Explore, community ideas, the Beta trust vector, the pastel palette, quests and badges, the continuous camera. The bundled recipes are flagged as a rights risk.
- 2026-10-11 11:45Z: the integration branch is `alpha`, cut from main at 2fd0dfe, by Sam's direction. The earlier `beta` and `fleet/beta` (both at 2fd0dfe, no PRs) were deleted.
