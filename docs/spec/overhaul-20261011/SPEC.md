# FridgeLuck overhaul: spec

Status: draft for Sam, 2026-10-11. Written by the overhaul lead (Opus 5.5) from three independent inputs:

- `inputs/product-direction.md` and `inputs/design-direction.md` (Fable): product direction, visual system, mocks.
- `inputs/engineering-plan.md` (GPT-6.1 Sol): current-state evidence with file:line citations, PR topology, architecture options, task breakdown.
- `inputs/product-review.md` (GPT-6 Astra): adversarial review of the product logic.

This file records what was decided. Where it disagrees with an input, this file wins and says why. Each default that only Sam can settle is marked **Sam to confirm**; work proceeds on the default until he overrides it.

## 1. What FridgeLuck is

FridgeLuck helps one or two people decide what to cook tonight from what is actually in their kitchen, cook it without friction, and remember what worked. It learns their taste in the open, where they can see and correct it.

Who it is for: people who cook most nights for one or two, shop weekly and throw out food they meant to use. Students on a budget are inside this group, served by a budget lens and by challenges (section 6), not a separate app. **Sam to confirm** the first audience; the reviewer asked whether students should lead instead.

What it is not: a calorie tracker (Cal AI and MyFitnessPal own that), a recipe magazine, a social feed.

## 2. Shell and screens

Adopted from the product direction, with the reviewer's corrections.

| Tab | Question | Mock |
| --- | --- | --- |
| Tonight | What do I cook now? | `mocks/home.html` |
| Kitchen | What do I actually have? | `mocks/pantry.html`, `mocks/scan-review.html` |
| Table | What are my people cooking, and what challenge am I in? | `mocks/community.html` |
| Cookbook | What have I cooked, what do I like? (cooks, saved, taste profile, search, nutrition lens) | `mocks/taste-profile.html` |
| Scan (action) | One camera that tells shelf, receipt and plate apart | `mocks/scan-review.html` |

LeChef has no tab. It is a mode entered from a recipe or Tonight (`mocks/cook-lechef.html`). Recipe detail: `mocks/recipe.html`.

Changes from the product direction:

- **Search, filters and saved recipes stay.** The inspiration feed goes; the ability to choose does not (review finding 13). Search lives in Cookbook and Kitchen.
- **Tonight is a default, not a verdict** (finding 5). It has explicit states: unknown kitchen (no scan, camera refused, recognition failed: manual entry is first-class), sparse kitchen (3-5 items: honest "you'd need" list), nothing feasible (shopping list or pick from saved, never a fake "cook with 2 swaps"), and repeated rejection (after the third "Something else", offer a constraint choice: quicker, different main, less effort, pick from a list). Rejections never become dislikes. The user can choose tomorrow; there is no clock cutoff.
- **Meal context**: who is eating (default: you; optionally one more eater with their own restrictions), portions, time, equipment. Hard restrictions are the union of all eaters'. Feedback is attributed to whoever gave it, or labelled household (finding 6).
- **Nutrition** is out of the tab bar but stays: a line on cook-complete, a lens in Cookbook with honest coverage ("logged 9 of your 14 meals this week"). Apple Health stays optional and writes only confirmed meals.
- **Reverse scan** ("log a meal you didn't cook here") asks whether the food came from your kitchen and defaults to no inventory deduction.
- **Leftovers** are modelled: portions, storage, date, reheat or thaw time. They appear on Tonight with their real time.
- Cut, as the product direction proposed: tutorial quests, spotlight overlays, streaks, confetti, the Progress tab, user-facing demo mode, the three-mode scan fan, hero gradients, olive slabs, ingredient sprite icons.

## 3. Binding contracts

These hold everywhere: ranking, LeChef, generation, scans, recipes and community. A violation is a release blocker.

### 3.1 Food safety

- Doneness for meat, poultry, fish, eggs and leftovers is stated as a checkable test with a thermometer temperature from a reviewed source (USDA FSIS safe minimum internal temperatures), never by colour or time alone. Timers say when to check.
- A camera look describes what a picture can show (browning, size, consistency) and says what it cannot assess. It never gives a safety verdict.
- Adapt rescales amounts. It changes a time only when a reviewed rule supports it (thickness, pan size, quantity in the pan); otherwise the step says to check rather than trust the timer.
- Every substitution rechecks all eaters' allergens, including compound ingredients (soy sauce contains wheat, pesto contains nuts). Swaps describe the difference ("a little sharper") and never promise "no change".
- Food-safety guidance is advisory and sourced. Shelf-life estimates never certify that food is safe.

### 3.2 Pantry truth

The fit line is the app's central promise, so it must be true (finding 2). Fit is computed over a complete ingredient bill for the chosen recipe revision, servings and accepted swaps:

- Repeated lines are summed; optional garnish is separate.
- Each line is matched by quantity with compatible units and preparation, allocated from eligible inventory lots without counting the same stock twice (across lines, swaps, or several dinners in a plan).
- Each line has a state: **sufficient**, **short** (with the amount), **quantity unknown**, **assumed staple**, or **needs reconfirming** (stale evidence).
- The fit line uses those states: "9 of 10 · 1 swap" only when nine lines are sufficient; otherwise "7 recorded · check eggs and oil". Never a percentage, and never "you have everything" unless every line is sufficient.
- **Scans observe; purchases add** (finding 7). A shelf scan reconciles observed stock ("Still 2 lemons?"). Only a receipt, "New groceries" or manual entry adds stock. Retried confirmations are idempotent. Recognition confidence is not quantity confidence; unknown amounts stay unknown.
- Each item carries its last confirmation and source. A scan of one shelf refreshes only what it saw.
- **Pantry ownership**: one person's pantry on one phone in the first release, with manual corrections. A Table never implies shared inventory. A synced household pantry is a later decision.

### 3.3 Learning

The taste profile is a page of sentences with evidence, each correctable (product direction, `mocks/taste-profile.html`), built on these rules (finding 8):

- Three separate layers: **explicit restrictions** (allergies, diets; hard filters, never weakened, survive any reset), **stated preferences** (from setup and edits), **inferred taste** (from behaviour).
- Evidence is counted as distinct opportunities with denominators and recency: "removed coriander 4 of the 5 times it was in a recipe you cooked", not "5 observations". There is no universal threshold.
- Availability is not preference. Cooking what was in the fridge, or what the app showed, is weak evidence. The engine logs exposures and feasible alternatives so it can tell the two apart.
- Explicit "I don't like this" outweighs any frequency. A swap records whether it was necessary (didn't have it) or preferred, when the user says so.
- "Don't ask again" is different from "This is wrong". Weak inferences expire. The user can reopen any sentence. Changing your mind never requires a full reset.
- Learning runs on the phone. Nothing about taste leaves the device.
- The learned ranker ships only when it beats the current rule-based ranking and an explicit-profile-only baseline on a frozen simulated suite with zero restriction violations (section 8, outcome 3).

### 3.4 Sharing and consent

- Finishing a cook saves it **locally**. Sharing is a separate action with a preview of exactly what leaves the phone (finding 3).
- What a shared cook contains: recipe revision, servings, swaps, rating, an optional one-line note. Never pantry, health profile, taste data or exact time beyond the day. No photo sharing in the first release.
- Contributing to aggregate statistics is a separate opt-in from sharing with a Table, and uses structured fields only (rating, swaps made), never notes or photos.
- Tables: invite by link, which the owner approves; the owner can revoke invites and remove members; anyone can leave, block and report. Former members lose access.
- Sharing requires a Sign in with Apple account and is **adult-only (18+)** in the first release. **Sam to confirm**, and name a moderation operator. Until one is named, reports go to a review queue and shared free text is limited to Table members.
- LeChef's backend keeps no camera frames and no transcript beyond the live session unless the user explicitly saves a note. The current Firestore persistence of frames and text (`backend/gemini-agent/src/session/liveSessionStore.ts:242-290`) is removed or put behind a TTL by the backend trunk task.

### 3.5 Recipes

- Ship only recipes the app has the right to ship (finding 4). For each recipe the corpus records separately whether text, images, modification, attribution, caching and offline use are permitted. Unknown rights means quarantine.
- **The bundled catalog has a rights problem.** 141 of 166 bundled recipes cite BBC Good Food URLs with no licence evidence; the other 25 are not automatically clear. A recipe's ingredient list is generally not copyrightable, but its written expression is. Default: rewrite each kept dish as an original recipe in our own words with our own structured steps, and remove the rest. **Sam to confirm**, ideally with legal advice.
- Structured or not shipped: ingredient lines with quantity evidence (weighed, source grams, household measure with a conversion, or unknown; never an invented mass), steps split at timer and action boundaries where real, equipment, safety checks. A step without a natural timer does not get a fake one; eggs can be counted, not weighed.
- Corpus size follows the legal yield. Targets: about **400 reviewed recipes for the first release**, growing past 1,500 as sources allow. The corpus task (`fl-recipe-corpus-f1`) reports the honest yield. The reviewer's illustrative figures were about 100 for a pilot and 250-400 for a first release.
- LeChef-generated recipes are private drafts labelled "Made for your fridge". A rating of 4+ can nominate the version actually cooked for review; it enters the catalog only after rights, safety and a human test cook.
- Substitutions come from a reviewed, context-specific table (ingredient pair, recipe context, quality note, macro delta, allergen check). LeChef reasons beyond the table only when it is empty, and says so.

## 4. LeChef

LeChef is a cooking companion with five jobs: plan, substitute, coach, adapt, remember. Chat is the fallback, behind a transcript toggle. Each job has a reliable local core that works with no network (finding 11):

| Job | Local core (always works) | With Gemini Live |
| --- | --- | --- |
| Plan | Deterministic allocation of current stock to 3-4 feasible dinners plus a short shopping list, reserving quantities across the plan | Conversational planning, preferences in words |
| Substitute | Reviewed swap table with allergen recheck | Reasoning when the table has nothing, labelled as such |
| Coach | Steps, timers, the five-word vocabulary (next, back, repeat, timer N minutes, show) and touch equivalents | Answers questions, reads steps, camera look on request |
| Adapt | Amounts rescale predictably; time changes only under rules | Explains the change |
| Remember | Rating and one-line note saved locally with a visible receipt | Note by voice, transcribed and confirmed |

- The phone is authoritative for pantry, cook sessions and logs (engineering plan, Goal 3 option A). The backend reads bounded snapshots and proposes typed actions; the phone checks revision and approval, executes, and returns a receipt. The model cannot manufacture approval. A voice transcript alone never authorizes a meal log or a share.
- Timers live on the device with persisted deadlines, independent of the Live session; a timer is acknowledged only after the device created it.
- Camera is push-to-look: a single frame or a clip of up to 3 seconds, with a visible viewfinder and an explicit upload.
- **Cost**: there is no budget yet. A benchmark task measures connected minutes, tokens and reconnects on realistic recorded sessions (with a fake provider for logic, and real pricing applied as a parameter). Until Sam sets a monthly cost per active cook, voice is opt-in per cook and "Just the steps" is the default. **Sam to confirm** what pays for LeChef.

## 5. Visual and motion system

Adopted as written in `inputs/design-direction.md`: "a prep list, not a magazine"; paper and hob palettes; SF Pro for words, SF Mono for every number; one accent, yolk #F5C400, meaning attention; flat content with hairlines; Liquid Glass only where the system puts it; five motion tokens (snap, move, settle, fade, none) with frequency deciding duration; the Avoid list is binding. The yolk-as-only-accent risk is accepted, with tomato #D7301F as the one-line fallback if testing reads yellow as a warning.

The mocks were corrected for the safety and pantry contracts above (cook-mode doneness copy, swap copy, scan duplicates, leftovers, generated-recipe promotion).

## 6. Community

The order is solo first, then small groups, then aggregates, so each layer is useful without the next (findings 9 and 10):

1. **Challenges (first release, works alone).** Restored from Sam's original idea: "three ingredients, what can you make?" A challenge is a constraint (three ingredients, a reviewed low-budget pack, a use-it-up item, a time limit). You get viable recipes, cook, and record your result privately. You can send the challenge to a friend as a link that reads without the app. This is where the student, budget, food-bank and sustainability story lives. A university or dining-hall partner can host challenges later.
2. **Tables (first release, behind a beta flag).** Private groups of 2-8 who see each other's shared cooks (section 3.4). Each card carries the viewer's own fit line and "Cook tonight". No likes, comments, follower counts or ranking; cards are in time order. Success is measured by recipients who actually cook a shared recipe, not by invites sent.
3. **Cook notes (after launch).** Aggregates of structured, opted-in outcomes per recipe revision, with distinct-contributor counts and minimum support per claim. Below the floor the section reads "Not enough shared notes yet". Not promised at launch.

Backend: extend `backend/gemini-agent` with an isolated community module (engineering plan, Goal 1 option A): Sign in with Apple verified on the server, server-issued sessions, collections for accounts, tables, memberships, invites, shared cooks, challenges, challenge entries, blocks, reports and moderation decisions. Firestore is the store already in the dependency tree; its emulator is the test target. No media uploads in the first release.

## 7. Architecture

Adopted from the engineering plan, Goal 5 option A, with one change.

- `packages/FridgeLuckCore`: one SwiftPM package, Linux-buildable, with targets FLDomain, FLPersistence (GRDB), FLRecipeCore, FLInventoryCore, FLPreferenceCore, FLAssistantCore, FLFlowCore, FLCommunityCore, FLRecipeDelivery, added by the task that needs each, never as empty placeholders. The foundation task owns the manifest; each later task adds only its own target. Domain contracts in section 3 are implemented in FLDomain.
- Change: the preference engine is first built as `packages/FLTaste` (`fl-taste-engine-f1`), a standalone research package with its evaluation, because evaluation has to come before shipping. Its proven model then moves into FLPreferenceCore.
- `packages/FLDesignTokens` (portable) and `packages/FLDesignSystem` (SwiftUI). macOS CI renders every component to PNG so a Linux agent can see its work.
- `apps/ios` stays the native host: thin SwiftUI views over portable state machines, Apple adapters in Platform/Integration/Capability.
- The phone holds the single local write authority (one GRDB queue). Meal log, inventory consumption, nutrition snapshot and preference event commit in one transaction; HealthKit and community sync run after commit with retry state.
- The recipe corpus is built offline by Python (`data/recipes/`), validated against the USDA catalog, and installed through the bundle-refresh path (#44) without rewriting historical nutrition (#45) or taking over edited user recipes.

Integration: about 80 open PRs sit on chained bases. Two trunk tasks build integration branches with a ledger of every PR's verdict (`fleet/fl-trunk-20261011` for the app, `fleet/fl-backend-trunk-20261011` for the backend). New native work bases on the app trunk once its Handoff is checked; new packages base on `main` because they add new directories. Sam merges; no agent merges to main.

Verification labels, used in every Handoff: `verified-linux` (a command ran against the named artifact on Linux), `verified-native-ci` (an actual macOS CI run at that artifact, with its URL), `UNVERIFIED-NATIVE` (not run). Obvious sandboxes have no Xcode or simulator, so native screens are verified by macOS CI compilation and rendered PNGs, and the rest is labelled.

## 8. How we will know it worked

From the review, with definitions fixed before evaluation:

1. Decision-to-dinner success: sessions that end in a confirmed cooked meal without a surprise shopping trip. Empty kitchens and third-rejection sessions count in the denominator.
2. Fit truth: audited "ready to cook" picks against actual stock; surprise shortages and correction burden. Unsafe or allergy-incompatible suggestions are release blockers.
3. Learning value: the learner against explicit-profile-only and current-rule baselines among equally feasible candidates; frozen simulated suite first, randomized comparison later.
4. Week-4 solo utility: activated households completing at least two app-assisted dinners in week four, solo and Table members reported separately.
5. Community-caused cooking: recipients who cook a shared recipe or challenge.

Guardrails: cost per completed cook, timer delivery, safety failures, privacy failures.

## 9. Work plan

Each task owns distinct directories, names its base and branch, ends with Proof and Handoff, and labels what it could not verify. Task prompts live in the fleet repo (`packets/focus/fridgeluck.jsonl`).

The work runs as five long programmes, each a parent thread with parallel sub-threads that own separate directories (queued 2026-10-11):

- `fl-integration-f1`: app and backend trunks with a PR ledger; finishes the #45, #44 and #85 continuations and folds them in.
- `fl-recipe-platform-f1`: rights audit, #43, the licensed and original corpus, the food-safety rulebook and recipe linter, and the substitution table.
- `fl-learning-lab-f1`: the preference engine, a household simulator, and an evaluation campaign over thousands of simulated users, ending in a recommendation for what ships.
- `fl-core-build-f1`: FridgeLuckCore (FLDomain, GRDB on Linux, CI), then pantry truth, the dinner and cook state machines, LeChef authority and community sharing and challenges, joined by a week-long household scenario suite.
- `fl-design-build-f1`: the design system and every main screen as SwiftUI driven by view-state values, rendered through macOS CI.

**Next, after the backend trunk Handoff is checked:**

- Community backend: auth, tables, invites, challenges, report and block, moderation queue, on the Firestore emulator.
- LeChef app tools over snapshots and proposals.
- LeChef cost benchmark.

**Then, after the app trunk, core build and design build Handoffs:**

- Host integration: replace the old Feature screens with the FLScreens packages, wire them to FridgeLuckCore and migrations, instrument preference events, and render the whole app through macOS CI.

**Last:**

- Corpus delivery into the bundle through #44.
- Preference activation gate on the frozen suite.
- Linux system scenarios across the whole journey.
- A list of the native checks still owed, for Sam or a Mac.

## 10. Decisions for Sam

Defaults are in force until he overrides them.

1. First audience: one- and two-person households, with students served through the budget lens and challenges.
2. Bundled BBC-cited recipes: rewrite the kept dishes as original recipes and remove the rest, after legal advice.
3. Community at launch: challenges plus Tables behind a beta flag; adult-only sharing; no photo sharing; a moderation operator to be named.
4. LeChef cost: voice opt-in per cook until a monthly budget per active cook is set.
5. Recipe rights and test-cooking budget: none assumed; the corpus grows with free, rights-clear sources and original recipes.
