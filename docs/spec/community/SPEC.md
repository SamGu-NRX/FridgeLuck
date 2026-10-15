# FridgeLuck — Community spec (burst 5)

User recipes · Explore · Challenges and battles · Tables · Community API · Mocks in words

**Status:** draft for review · **Base spec:** `docs/spec/overhaul-20261011/SPEC.md` on branch `docs/spec-overhaul-20261011` (the overhaul SPEC) · **Contracts:** [`contracts/`](contracts/), machine-checked by `contracts/check.py`

This spec covers the community packet of the overhaul: sharing your own recipes (Explore), challenges and battles, Tables of 2–8, the identity/safety machinery underneath, and the API contract. The product behavior, the backend, the app-side storage, the mocks in words, and the taste-spec events are sections 1–11; sections 12–14 split the work, record the decisions, and cite the evidence the work into three packets that later threads can start without asking anyone.

**Load-bearing assumption.** The brief (overhaul §3.4 + this packet) assumes a *small, trusted-by-default community* — first-name identity, no likes or follower counts, owner-approved Tables — will produce enough shared recipes and enough opted-in cook data for Explore and "cooked by N" to feel alive, without moderation volume beyond one operator. Evidence that would confirm or break it: number of distinct publishers and the share of cards with a real `cookedBy` count after the first month (healthy: most cards carry a count and new publications get cooked within days; broken: feed dominated by never-cooked zero-count cards and a moderation queue a human cannot clear weekly). Adjacent explanations the brief skipped: if the app's audience is still mostly single-user test devices, "community" may simply have no supply yet — a cold-start problem, not a design problem — which is why §3 cold-start copy and the catalog-first feed exist. If Sam wants metrics before committing to a server spend, the lead alternative is running the Tables surface on-device sync only (P2P/CloudKit share) and deferring Explore — rejected here because it splits the contract in two (§13, decision 2).

**How to read this.** §1 fixes the invariants once; §2–§5 are the four products; §7 is safety; §8–§9 are the backend and client architecture; §10 is every screen in words; §11 is the event list the taste spec consumes; §12 is the build order. When this spec and the overhaul SPEC disagree, this spec wins for community surfaces and the overhaul wins everywhere else.

**What is checked vs. trusted.** Everything machine-checkable lives in `contracts/` — 24 JSON Schemas, 31 example fixtures, 33 operations — and `python3 contracts/check.py` validates every example against its schema, manifest coverage, and OpenAPI/manifest sync (all stdlib, exit 0 required). The prose makes claims about repo files (e.g. PR #71's editor, the migration test pattern); those were verified during drafting against the alpha checkout and the four research threads cited in the appendix — anything not verified says so.


## 1. What ships first: ranking the three directions

Sam's binding words, in order of recency and authority:

- 2026-09-30: community is "being a community to share recipes and add recipes, explore page".
- Stage 0 (`planning/stage_0-brainstorm/fridgeluck planning.md`): recipe battles ("3 ingredients, what can you make?") with voting, sharing a creation with people who had the same ingredients, university and dining-hall challenges, "400 other people at your school made something this week", seasonal challenges, food-bank packs, waste tracking — and community is "small extensions … not the main focus".
- 2026-10-11 overhaul spec §1 and §6: "not a social platform where you perform your cooking for likes", user recipes, Explore, challenges at launch, Tables in beta, adult-only; three candidate directions judged by the same scorecard.

The three candidate directions from overhaul §6 are ranked below. Each is judged against (i) Sam's explicit ask, (ii) the guard rails ("small extensions", no performance-for-likes), and (iii) what can actually run: the app has no account system and no community network client today (no `ASAuthorization` / Sign in with Apple code exists under `apps/ios/` on `alpha`; the only server is `backend/gemini-agent`, whose routes at `backend/gemini-agent/src/server.ts:29-145` carry no identity), and the campus direction needs a university partner that does not exist yet.

### Decision: Explore-first leads; battles ride along as one challenge type; campus waits

**Direction (a) Explore-first — SHIPS FIRST (burst5).**

- It is the only direction Sam named in his 2026-09-30 sentence, and it is the only one whose value does not depend on anyone else: one person publishing a recipe and a second person cooking it already delivers the overhaul's "community-caused cooking" outcome (§8, outcome 5).
- Its server surface is the smallest and its moderation story is the one §3.4 already designed in detail: publish, screen, withdraw. Every other direction reuses this machinery (a battle entry is a published recipe revision; a Table shared cook is the same share payload), so building it first means nothing later is blocked.
- It matches "small extensions": Explore and user recipes hang off the personal cookbook (PR #71) rather than adding a new app surface with its own habits to maintain.
- Alternative rejected — **battle-first**: battles are the most fun idea in stage 0 and the best "400 people made something this week" vehicle, but they are the weakest first ship: they need an account base big enough to vote, a fixed ingredient-set pipeline, an anti-gaming story, and a weekly cadence to feel alive. A battle with eight participants is a dead room; the guard rail "small extensions" does not buy the operating cost of weekly cadence before the publish/explore loop even exists. Battle mechanics are nevertheless specified fully (section 6) and implemented in `burst5-fridgeluck-community-groups`, so the direction is a configuration away, not a rewrite.
- Alternative rejected — **campus-first**: Sam's stage-0 story centres students and his university, and "400 other people at your school made something this week" is the strongest single hook in the whole idea. But it requires a partner (dining hall, university) and a per-school identity mapping that do not exist; the overhaul review already flagged "built for a partner that does not exist yet". The spec keeps the counters and school-scoped challenges as designed-for extensions (section 6.7) so the data model does not paint us in, but nothing campus-specific ships in burst5.

**Direction (b) battle-first — RIDES ALONG.** Battles ship in burst5 as one challenge *type* (section 6.3), on the challenges machinery the groups slice builds anyway, without weekly cadence at launch: battles open when there is content to sustain them. Voting and anti-gaming are specified now because retrofitting vote integrity is painful.

**Direction (c) campus-first — WAITS.** Data model accommodates school-scoped challenges and aggregate counters (section 6.7); shipping waits for a named partner and Sam's go.

### What this means for burst5, concretely

1. `burst5-fridgeluck-community-api` ships identity, user recipes with publishing and moderation, and Explore.
2. `burst5-fridgeluck-community-client` ships the Swift user-recipe store on top of the personal cookbook, the share preview, the API client against the contract examples, and the outbox.
3. `burst5-fridgeluck-community-groups` ships Tables and challenges (including battles).

Feature flags, in order of turning on: user recipes (private) → publishing to author-only → Explore public feed → Tables (beta flag) → challenges and battles. Publishing to the public Explore feed additionally waits for Sam to name a moderation operator (overhaul §10 decision 4; default until then: published recipes visible to author only, Tables work).

## 2. User recipes

User recipes are a recipe source (overhaul §3.5). They live on the phone in the personal cookbook (PR #71) and gain community behaviour only through explicit publishing. This section specifies the community-owned behaviour; the cookbook's own store, editor and validation are specified by PR #71 and are referenced, not re-owned.

### 2.1 Creation, edit, duplicate, import — private by default

Every user recipe is created private. There is no path that makes a recipe public without the publish flow of §2.3.

- **Create and edit** come from the personal cookbook editor (PR #71: `CookbookRecipeEditor`, `CookbookRecipePolicy` in `apps/ios/FeatureLogic/Cookbook/` and `apps/ios/Platform/Persistence/Cookbook/`). The community layer adds no separate editor.
- **Edit semantics**: an edit produces a new **revision** of the same recipe id. The recipe keeps its local `recipes.id` (`apps/ios/Platform/Persistence/Database/Migrations.swift:14`); revisions are numbered from 1 and monotonically increase. The revision the app is a function of is always explicit — a fit line, a shared cook and a publication all name a revision, never a title.
- **Duplicate** (PR #71 `UserRecipeTransactionService` copies any row into a new `source='user'` row) copies into a new recipe id at revision 1. Duplicating someone else's published recipe (via Explore) imports the snapshot **plus a `duplicatedFrom` community attribution** — PR #71's duplicate does not carry provenance, so the community layer adds it (display name only). A duplicate is private, like everything else.
- **Import**: importing a recipe written by someone else (paste or URL) does not exist in the cookbook today (PR #71 ships no import path); when it arrives, the community rule is already fixed — **imported recipes cannot be published in burst5.** The publish gate refuses any recipe whose provenance is not `user-created` with a reason ("This recipe was imported from elsewhere; only recipes you wrote yourself can be shared in this release"). Adopted from overhaul §3.5 ("Imported text from someone else's website stays private") and made absolute for burst5; the alternative considered, allowing publication after an `ownRights` declaration, is rejected for burst5 because the automated screening cannot distinguish a paraphrased scrape from an original, and a human moderator per import does not fit "small extensions". Revisit when the recipe corpus rights pipeline (overhaul §3.5, PRs #43/#113) lands.
- **Generated recipes** ("Made for your fridge", overhaul §3.5) follow the same rule as imports: private, not publishable in burst5.

### 2.2 Revisions

| | |
|---|---|
| Numbering | integer, starts at 1, +1 per published-or-private content change; never reused |
| Immutability | a revision that has ever been **published** (or shared to a Table) is frozen on the server; edits fork to a new revision |
| Local store | `user_recipe_revisions` in `CommunityMigrations` (section 9) holds every revision locally, so offline history works |
| Server mirror | only revisions that were published or shared have a server copy; private-only revisions never leave the phone |
| Deletion of history | withdrawing a publication does not delete the revision; it is removed from the Explore index and tombstoned (§2.4) |

Rationale: immutable published revisions are what makes a fit line truthful (the reader's "you have everything" refers to exactly what the author wrote) and what makes a shared cook's rating attributable to a specific text. Alternative considered — always-live documents with no revisions — rejected: it makes "cooked by N" claims point at a moving target and makes moderation decisions unauditable.

### 2.3 The publish flow

Publishing is a separate, previewed action (overhaul §3.4), gated by the 18+ Sign in with Apple account (section 7).

**Step 1 — Gate.** The publish button is disabled with a reason line unless: the recipe is user-created (§2.1), the user has a verified account, the account is 18+, and the recipe passes the local pre-flight (food-safety lint and allergen tagging run on the phone first; see section 7.5). Local pre-flight failures are shown before the preview opens.

**Step 2 — Rights declaration.** Two attestations, shown as explicit checkboxes with plain-language copy:

- **"This recipe is mine."** — `ownRights: true`: the author wrote it or has the right to share it.
- **"It has no personal information in it."** — `noPersonalData: true`: no names, handles, emails, phone numbers or addresses in title, steps or notes.

Both must be true; the request is refused server-side with `422` otherwise (adopted from PR #104's declarations door). The declaration is stored verbatim on the publication document for moderators and future exports; readers never receive it.

**Step 3 — Preview of exactly what leaves the phone.** A full-screen sheet titled **"What leaves your phone"** showing every field the publication carries, rendered from the same struct the client will send (`SharePreviewBuilder`, section 9.2). The payload:

- recipe revision content: title, description, servings, time, ingredient lines (name, quantity, unit, preparation), steps, equipment, dietary tags, allergen tags;
- `source.provenance`: `user-created`;
- author display name (first name or chosen handle only — the account's Apple identity never appears);
- language code;
- nothing else. **Never**: pantry, health profile, taste data, exact times beyond the day, photos (overhaul §3.4; no photo upload in burst5), contact identifier (email/phone), device identifiers.

The sheet states the negatives in the same words as the spec: "Never sent: your pantry, health information, taste profile, photos, or anything else about you."

**Step 4 — Submit and moderation.** Submission runs the automated screening server-side (§7.5): food-safety lint, allergen tagging, personal-data check. The server states adopt PR #104's four publication states (`published` / `queued` / `rejected` / `withdrawn`, one visibility derivation); `queued` is the author-visible "In review":

| Server state | Author-visible state | Reader-visible state |
|---|---|---|
| `published` | Published | In Explore (index lags ≤ 1 min) |
| `published` with a non-blocking flag (e.g. uncertain allergen tag) | Published — flagged | In Explore, tag pending confirmation |
| `queued` (blocking screening hit, report, or operator sampling) | "In review" | Hidden |
| `rejected` (operator decision after a case) | "Removed by review" with the reason | Hidden |
| `withdrawn` (author or deletion) | Removed | Hidden, tombstoned |

Approval of a queued publication is bound to the exact screened content hash (PR #104's content-hash-bound `screenedEvaluation`): editing the recipe after screening forks a new revision and re-screens, so an approval can never be carried to different content. The food-safety gate is fail-closed — if the safety-lint packages cannot load, the publish refuses with `503` rather than publishing unlinted (PR #104 behaviour, kept).

With no moderation operator named (default until Sam names one, overhaul §10.4), `queued` cases simply wait: a flagged publication stays hidden, never silently published.

**Step 5 — Withdrawal.** "Remove from Explore" is one tap from the recipe page and from the published-revision card. Withdrawal deletes the Explore index entry immediately and tombstones the publication document (moderation audit retains the tombstone reference, not the content serving). Anyone who saved the recipe keeps their local copy with `source` attribution intact and a "no longer available" banner. Re-publishing after edits creates a new revision; a withdrawn revision can be re-published only unchanged, keeping its number.

### 2.4 What the phone stores locally

`CommunityMigrations` (section 9.1) adds, with `community_`-prefixed identifiers:

- `community_user_recipes` — mirrors the cookbook row plus community state (`publicationState`: `private` / `authorOnly` / `published` / `inReview` / `withdrawn`, `publishedRevision`, `serverId` nullable);
- `community_user_recipe_revisions` — frozen revision snapshots (the publish payload form);
- `community_outbox` — pending server writes (section 9.3).

The cookbook (PR #71) remains the write authority for content; the community store holds only state the cookbook does not know about. No thread edits `Migrations.swift`; community migrations live in the `Subsystems/CommunityMigrations.swift` file the shared contracts pin.

## 3. Explore

Explore answers "what could I cook that others made?", ranked by what you can make now (Sam, 2026-09-30; overhaul §6.2). It is a ranked list, not a social graph.

### 3.1 Ranking: computed on the phone

The server returns candidates (published revisions and eligible catalog recipes) with freshness metadata; **the rank order is computed on the phone**. Ranking inputs, per card:

| Input | Source | Weight character |
|---|---|---|
| **Fit** — the same fit line as every other card in the app (overhaul §3.2: sufficient / short / quantity unknown / assumed staple / needs reconfirming, computed against the complete ingredient bill of the revision) | phone (pantry truth) | dominant: cards the kitchen can't make never beat cards it can |
| **Taste** — the on-device preference score for the recipe's ingredient set and tags | phone (taste profile; section 11) | tie-breaker among feasible cards |
| **Freshness** — published date, decaying but never zero | server (`publishedAt`) | small; a good 3-month-old recipe still beats a weak 1-day-old one |

The exact blend starts from PR #106's implemented `ExploreRanking` (`packages/FLCommunityCore/Sources/FLCommunityCore/Explore/ExploreRanking.swift`), adopted as the initial formula: `score = 0.6 × fit + 0.4 × (taste ?? 0.5)` — fit and taste both normalized 0–1, computed on the phone, untagged taste defaulting to neutral 0.5, rounded to 6 dp with a 5-level tie-break — and retuned only through the learning lab. The contract fixes only that the server never needs pantry or taste data to serve the feed (the request carries no profile — what leaves the phone stays zero) and that **no server-side behavioural profile is built**. Anyone's read history stays on their phone.

Alternative considered — server-side ranking with taste uploaded — rejected: it contradicts §3.3 ("Learning runs on the phone. Nothing about taste leaves the device") and creates the exact behavioural profile a small community feature should not have. Cost: the first page of results may not be globally optimal; accepted, because with a community of hundreds (not millions) the candidate set is small and a 60-second server cache of fresh published revisions is cheap.

### 3.2 "Cooked by N"

A card may show "cooked by 37 people" only when **all** hold:

- distinct-cook count ≥ **10** (minimum adopted from the overhaul mock's aggregate-notes rule: "Counts appear at 10 cooks or more; below that … nothing is invented"; the same threshold applies here so one number governs);
- the count comes from **opted-in aggregate data only** (overhaul §3.4: aggregate statistics are a separate opt-in from sharing, structured fields only);
- below the minimum, the card shows nothing — no "new", no "🔥", nothing invented.

Counts update at most daily and are never per-user attributed.

### 3.3 Filters and search

- Text search (title, ingredients) — client-side over the fetched candidate set for burst5; the candidate set is capped (default 500, contract field `limit`).
- Filters: **max time**, **diet** (vegetarian/vegan/etc. from recipe tags), **allergen exclusions** (hard, from the user's explicit restrictions — applied on the phone and never weakened, overhaul §3.3), **challenge source** (recipes published as battle entries, section 6).
- Filters are computed on the phone like ranking.

### 3.4 What Explore deliberately does not have

- **No like counts. No follower counts. No author profiles. No comments.** (overhaul §3.4/§6.2, Sam's guard rail.) The only social numbers in the whole community surface are "cooked by N" at ≥ 10 and challenge entry counts.
- No following, no DMs, no sharing-to-a-feed. Sharing goes to a friend (system share sheet), a Table, or a challenge — never to an audience.

### 3.5 Sources in the feed

The Explore feed interleaves **published community recipes** and **eligible catalog recipes** (rights-clear, per overhaul §3.5). Catalog recipes appear so Explore is useful on day one with zero publications; each card carries a `RecipeRef` (shared contract), `source: "user"` or `"catalog"`. `generated` recipes never appear in Explore (private drafts).

## 5. Challenges and battles

Challenges give the community a reason to cook the same thing at the same time — Sam's stage-0 idea, kept as an extension, never as the main focus. Packs they draw from are owned by PR #116 and referenced, not re-owned.

### 5.1 Types

| Type | Stage-0 origin | What it is | Where its constraints come from |
|---|---|---|---|
| **battle** | "3 ingredients, what can you make?" with voting | A fixed ingredient set, everyone cooks their own dish from it, everyone votes | ingredient set defined in the challenge document (burst5 ships battles with hand-set ingredient lists resolved to `fdcId`s against the USDA catalog; later generated from PR #116 packs) |
| **use-it-up** | use-it-up packs | Cook something from a common waste-prone set before it goes | `use_it_up_packs.json` (PR #116) |
| **budget** | "Made 10 meals under $3" | Cook within a stated budget for the ingredient basket | `budget_packs.json` (PR #116), `priceUsd` items |
| **seasonal** | seasonal challenges | Cook with what is actually in season this month | `seasonal_packs.json` (PR #116), US region + month windows |
| **food-bank** | food-bank packs | Recipes from common donation items | `food_bank_packs.json` (PR #116) |
| **campus** | university/dining-hall challenges, "400 other people at your school" | School-scoped challenges and aggregate counters | waits for a named partner (section 1); schema reserved below |

### 5.2 Lifecycle

States: `draft` (operator-created) → `open` (entries accepted) → `voting` (entries frozen, votes accepted) → `closed` (results final, page stays readable). Times are explicit contract fields (`opensAt`, `entryClosesAt`, `votingClosesAt`, ISO-8601 UTC). burst5 creates challenges server-side by operator tooling or seed documents; there is **no user-created challenge** in burst5 (alternative considered — letting users open challenges — rejected for burst5: it needs its own moderation surface; revisit after Tables leave beta).

- **Entries.** An entry links a `RecipeRef` whose `source` is `"user"` (a published revision, passing the full publish flow of §2.3 — battles create no publish bypass) plus an optional one-line note and, for battles, the ingredient set match. One entry per account per challenge. Entries appear to everyone only after the author's publication is visible — an in-review entry shows only to its author as "In review".
- **Voting.** One vote per account per challenge; the vote can be moved until `votingClosesAt`; self-votes are stored but never counted. Votes are anonymous: no voter list is ever exposed, to anyone.
- **Results.** Tallies are revealed only after `votingClosesAt` (section 10.5 for the mock rationale: hiding live tallies removes bandwagon-voting and most of the incentive to brigade). A closed battle shows the top 3 with "most cooked" wording preferred over "winner" — the copy celebrates what was made, not who beat whom. There are no prizes, no badges, no leaderboards-over-time in burst5.

### 5.3 Anti-gaming

1. **One verified account, one vote** — votes are keyed to the Sign in with Apple account, not device.
2. **Account age ≥ 24 h** before a vote counts (dampens burst sign-ups); the vote UI says "Your vote counts tomorrow" rather than failing silently.
3. **No live tallies** (§5.2).
4. **Rate limits** server-side on entry and vote writes per account (contract: 429).
5. **Entries must pass the same publish moderation** as anything in Explore; a reported entry is hidden from the challenge until the report resolves.
6. **One entry per account per challenge**, enforced server-side; replacing your entry before `entryClosesAt` is allowed and moves the vote (an entry replacement re-points the author's own vote if already cast).
7. Blocks apply: a voter who is blocked by an entrant still sees the challenge (challenges are operator-run) but the block removes that entrant's cards from their Explore views.

### 5.4 Links readable without the app

Challenge and entry links open a **server-rendered web page** (`GET /web/challenges/{id}` — HTML, no app, no login) showing the challenge brief, the ingredient set, and — after close — the top entries with their recipes. This is Sam's stage-0 "share your result" loop: the link must be worth opening for someone who has never heard of FridgeLuck. The page renders the same publication payload as the app (no personal data beyond display name), is statically cacheable while the challenge is open, and carries no scripts beyond basic styling. Alternative considered — a Universal Link that falls back to a marketing page — rejected: a dead-end marketing page wastes the share; a readable page is the share.

### 5.5 PR #116 packs, by reference

Challenge constraints reference packs by **`packId` and item `usdaFdcId`**, exactly as defined in `data/kitchen-knowledge/packs/` (PR #116: `budget_packs.json`, `food_bank_packs.json`, `seasonal_packs.json`, `use_it_up_packs.json`, each under an envelope `{schemaVersion, kind, retrieved, data}`). The community spec owns none of that data: challenges store `{ "packId": string }` and resolve items at read time.

Resolved join rules (adopted because the pack files themselves leave the join contract open — PR #116/#108 open question):

- The canonical join key is **`usdaFdcId`**, which PR #116 guarantees resolves against the 800-row bundled `usda_ingredient_catalog.sqlite` or the 27-entry reason-bearing allowlist. The packs' `ingredientKey` (lowercase, with inconsistent space/underscore normalization across files) is display-only in challenges, never a join key.
- If a pack changes, in-flight challenges keep the `packId` and the resolved snapshot frozen into the challenge document at creation (`resolvedItems`: fdcId, display name, quantity), so a price update can never mutate a running battle.
- PR #116 does not carry durations, difficulty or `RecipeRef` keys, and `safetyRuleRefs` wait on the recipe rulebook (PR #97): the challenge document owns duration and entry rules itself (§5.2), and safety rules come from the recipe spec's linter, not from packs.

### 5.6 Waste tracking

Stage-0 waste tracking ("visualize impact in dollars, CO2") stays out of burst5. The outbox and cook records already carry what a later waste model needs (used-quantity from cook sessions, pack `quantityKg`), and section 11's events log `challenge.entry.completed` so a waste view can be added from real history, not estimates. Nothing community-side computes a waste claim in burst5.

### 5.7 Reserved for campus (not built)

The challenge document reserves optional `scope: { "kind": "school", "schoolKey": string }`. Counters like "400 other people at your school made something this week" require school attribution (email-domain or invite mapping) and a partner; the field exists so the shape is settled, and nothing reads or writes it in burst5.

## 4. Tables

A Table is 2–8 people who see each other's shared cooks (overhaul §6.4, behind a beta flag). The unit is a cook the user chose to share — never a pantry, never a profile. The interaction model (cards in time order, one "Cook tonight" button per card, aggregate notes at ≥ 10 cooks) is already specified in `mocks/community.html` on the overhaul branch (§10.7 adopts it verbatim); this section specifies the data and permissions underneath it.

### 4.1 Membership, invites, roles

| Role | Powers |
|---|---|
| **owner** (exactly one) | approve and revoke invites, remove members, rename the table, delete the table |
| **member** | share cooks, leave, block and report other members |

- Size 2–8 including the owner; the server refuses a 9th member (contract: `409` with `reason: "table_full"`). A table of 1 (owner alone) exists transiently after others leave and shows the mock's "Invite someone. Tables work from 2." state.
- **Invites are approved by the owner**: a join request created from an invite link or code sits as `pending` until the owner approves. The mock's invite flow (share sheet with code + link, editable table name, prompt never in onboarding — first appears after the third cook) is the product surface (§10.8).
- **Invite lifecycle**: `pending` → `approved` (member) / `revoked` / `expired` (7 days) / `declined`. Revoking an invite invalidates its code immediately. A former invite code is never reusable.
- **Removal and leaving**: the owner removes a member ("Remove"); anyone leaves themselves ("Leave Flat 4B? Your cooks stay in your Cookbook." — mock copy). Either takes effect immediately: **former members lose access** to the table feed, and their past shared cooks are kept in the table's history but rendered without the cook content (name removed, card shows "left the table") — alternative considered, deleting their cards outright — rejected: it rewrites the remaining members' history without their action; hiding content preserves the record while removing the departed person's data.
- **Blocks between members** (§7.3) are incompatible with a shared table: a block between two members removes the blocked pair's cards from each other's view within the table, and the owner sees a "there is a conflict in your table" hint — the smallest thing that does not force either party out.

### 4.2 Shared cooks

- A shared cook is **the share payload of overhaul §3.4, verbatim**: recipe revision reference, dish name, servings, swaps, rating (e.g. "5 of 5"), an optional one-line note, the day. Never pantry, health, taste data, exact times or photos. The same payload type (`SharedCook`, contracts `shared-cook.schema.json`) serves a Table, a friend share, and a challenge result share.
- Sharing a cook into a Table requires the same 18+ account as publishing; no moderation queue for Table content in burst5 — shared free text is limited to Table members (overhaul §3.4's default without an operator) — but the one-line note runs the personal-data screen (§7.5) client-side before send, and reports work (below).
- **"Cook tonight"** on a card sets the dish on Tonight with the author's note attached to the relevant step (mock). This is a local action against the referenced revision — if the revision came from a published recipe, the phone has or fetches it; the never-published recipe content a Table member shares is carried **inside the share payload itself** (the full revision content ships in `shared-cook.schema.json`), so the card is cookable without touching the author's phone. This is the only case where recipe content reaches the server outside the publish flow; it is stored as the table's card, invisible to Explore.
- Revocation of a specific shared cook: the author can delete their own card from the table at any time.

### 4.3 Reporting in Tables

Any member can report a card or a member (§7.4). A report on a card hides it from all members pending review immediately; a report on a member is visible to the owner as a hint and to the operator as a case. With no operator named, hidden-stays-hidden (same default as §2.3).

### 4.4 Data the server holds per table

members (accountId, role, joinedAt), invites (code hash, state, expiry), cards (shared cook payloads, author accountId, createdAt), and the table record (name, createdAt, state). The server holds nothing else about members — no contact details, no profile beyond display name (§7.2).

## 7. Identity and safety

Community is adult-only, Apple-verified, and moderated before content is public (overhaul §3.4). This section specifies the server machinery; the contract is `contracts/openapi.yaml` (identity paths).

### 7.1 Sign in with Apple, verified server-side

- The app performs the normal Sign in with Apple flow and receives an identity token (JWS). **The app never sends the token's decoded claims as proof** — it sends the raw JWS to `POST /v1/auth/apple`, and the server verifies it:
  1. signature against Apple's JWKS (`https://appleid.apple.com/auth/keys`, cached with rotation);
  2. `iss` is `https://appleid.apple.com`;
  3. `aud` is FridgeLuck's bundle identifier (Services ID not accepted for app sign-ins);
  4. `exp`/`iat` validity with small clock skew;
  5. `nonce` matches a value the client generated and bound into the request (blocks replay of a token captured elsewhere);
  6. `email_verified`/`is_private_email` recorded but never required (private relay emails are fine).
- On first sign-in the server creates an **account** keyed by the Apple `sub` (the stable identifier). Display name is taken from the Apple name (first name only) once, editable, and is the only identity that ever reaches another user. Apple email is stored for account recovery/ops and never exposed.
- **Sessions are server-issued** (overhaul §6), adopting PR #104's session mechanics verbatim (`shared/sessionCore.ts`): short-lived HMAC-SHA256 access tokens (prefixed `fla1.`, 15-minute TTL, no server state needed to verify integrity) and single-use refresh tokens (prefixed `flr1.`, 30-day TTL, stored only as sha-256 hashes) with atomic rotation that revokes the whole refresh family on reuse — replaying an old refresh token kills the attacker's session, not just the client's. API calls carry `Authorization: Bearer <session>`; the contract treats tokens as opaque.

Alternative considered — Firebase Auth / Auth0 — rejected: a new dependency and a second identity truth, for a feature with no user-facing sign-in surface beyond Apple; Apple verification is ~100 lines against a stable JWKS.

### 7.2 The 18+ gate

- Sharing anything (publishing, Tables, challenges, Table shared cooks) requires an account attested as adult. Apple does not expose date of birth, so the gate is **self-attested birth year** asked once, before the first share: "To share recipes you need to confirm you're 18 or over." The server stores the attestation timestamp (`attested18PlusAt`, first-write-wins per PR #104) and the stated birth year; the server, not the phone, enforces the flag (`account.isAdult`). **Adaptation of PR #104**: it enforced 18+ only on publishing; this spec extends the gate to every sharing surface, because overhaul §3.4 says "Sharing requires a Sign in with Apple account and is adult-only" — sharing to a Table is sharing.
- A refused attestation (under 18) keeps every local feature working; the share affordances show "Sharing is 18+." No appeal flow in burst5; Sam may revisit.

### 7.3 Blocks

- `PUT /v1/blocks/{accountId}` / `DELETE /v1/blocks/{accountId}`; list via `GET /v1/blocks`.
- A block is private: the blocked person is never told. Blocking is **mutual** in effect (adopting PR #104): the pair's content is filtered from each other's views in both directions, computed server-side, never by notifying either side. Additionally: neither can invite the other to a Table, and the blocked cannot vote on your challenge entries.
- Blocks do not remove content from the server or from other people. Reports are rate-limited to 10/day/account (PR #104) so blocking-then-mass-reporting is not a harassment vector.

### 7.4 Reports

- `POST /v1/reports` with `targetType` (`recipe` | `tableCard` | `challengeEntry` | `tableMember`), `targetId`, a `reason` enum (`food_safety`, `rights`, `personal_data`, `spam`, `harassment`, `other`) and optional free text (one line, 280 chars).
- Effect is immediate for content: the reported target is hidden from everyone pending review (overhaul §3.4 "reports hide it pending review"). The reporter sees "Thanks — we've hidden this while it's reviewed."; the author sees "In review" (§10.9).
- Reports are not feedback to the author and carry no counter ("reported N times" never appears).

### 7.5 Automated screening

Three checks run server-side on every publish (and client-side as a pre-flight, §2.3):

1. **Food-safety lint** — against the recipe spec's rulebook (the cited, sourced rules shipped by PR #126: `data/food-safety/rules.json`, thermometer-based doneness, unsafe-handling phrasing, spoilage claims). Fail-closed: a rule the linter cannot evaluate is a block, matching `FLFoodSafety`'s fail-closed behaviour.
2. **Allergen tagging** — ingredient lines resolve against the ingredient-facts data (PR #127): allergen tags are computed, and any ingredient that cannot be resolved tags as `unknown-contents` rather than passing clean. Tags ship with the publication.
3. **Personal-data check** — regex + heuristics over all free text (title, steps, note) for emails, phone numbers, URLs, @handles, long digit runs (addresses/cards). A hit blocks; the author sees which line and edits without losing the recipe.

Screening verdicts and reasons are stored on the publication document for moderators. A blocking screening result is always overridable **only by a human operator** (§7.6), never by resubmission spam.

### 7.6 Moderation queue and operator tools

- A case is created by: blocking screening, a report, or operator sampling. `GET /v1/moderation/queue` (operator-only, Basic-auth allowlist of account ids) lists cases oldest-first with target content, declarations (§2.3), screening verdicts and report reasons.
- `POST /v1/moderation/{caseId}/decision` with `action` (`dismiss` → content returns; `hide` → content stays hidden, author notified; `remove` → content removed, publication withdrawn; `escalate_sam` → held for Sam) and a free-text note (internal). Every decision is an audit row (who, when, action, note) retained for the life of the account.
- Operator tools are API-only in burst5; there is no admin UI. burst5's queue is empty until an operator exists, and hidden-stays-hidden until it is drained.

### 7.7 Retention and deletion

| Data | Retention | On account deletion |
|---|---|---|
| account (Apple sub hash, birth year, display name) | life of account | deleted |
| published recipes | until withdrawn or deleted | withdrawn (tombstoned, §2.3); readers' saved copies keep attribution with "no longer available" |
| shared cooks (Table cards) | life of table | removed from tables |
| blocks, sessions, invites | life of account / TTL | deleted |
| moderation audit rows (decision, actor, reason) | **retained** (safety exception), content replaced by tombstone reference | retained, minimal fields |
| reports | life of case + audit | retained, minimal fields |

`DELETE /v1/account` deletes the account and triggers the table above in one request the client confirms twice ("This removes your recipes from Explore. It can't be undone.").

## 8. Backend

### 8.1 Where it lives: `backend/community/`, its own package

The community backend is a **separate bun + TypeScript package at `backend/community/`**, not a module inside `backend/gemini-agent`. This overrides overhaul §6's "extend `backend/gemini-agent` with an isolated community module"; the reason is Sam's own instruction for this burst: gemini-agent is LeChef's home, and community work must proceed in parallel with LeChef without touching the same package (version bumps, review collisions, deploy surface). gemini-agent keeps its identity today (`@fridgeluck/gemini-agent`, `backend/gemini-agent/package.json`); community gets `@fridgeluck/community`, its own `package.json` (bun ≥ 1.3, `engines.node >= 20`), its own `tsconfig.json` and tests, and its own port. Shared types with the contract come from `contracts/` JSON Schema (compiled to TS types via a checked-in generator script in the community package), so the two packages share the contract, not code.

Alternative considered — a module inside gemini-agent (overhaul §6 default) — rejected: the two programs have different deployment rhythms (LeChef cost work vs. moderation safety work), and a moderation failure should never be deployed or reverted with a LeChef change. Cost: a second server to run; accepted, because "small extensions" should not buy LeChef-incident risk.

### 8.2 Module discovery at startup

Each feature is a directory `src/modules/<name>/` discovered at startup:

```
backend/community/
  package.json  tsconfig.json
  src/
    server.ts           # boots, discovers modules, mounts routers
    core/               # auth middleware, errors, openapi assembly, repository interfaces
    modules/
      identity/         # apple sign-in, sessions, accounts, blocks
      recipes/          # user recipes, revisions, publish, withdrawal
      moderation/       # screening, queue, decisions, reports
      explore/          # feed, cook-count aggregation
      tables/           # tables, invites, shared cooks
      challenges/       # challenges, entries, votes, battle logic
  test/                 # harness: emulator boot, module fixtures
```

Startup globs `src/modules/*/index.ts`; each module exports a fixed shape:

```ts
export default {
  name: "recipes",
  version: 1,
  routes: (ctx: ModuleContext) => Router,
  schema: (registry: SchemaRegistry) => void,     // stores + indexes this module owns
  migrations: (runner: MigrationRunner) => void,  // schema changes it owns
}
```

The server mounts each module's router under its prefix and assembles the served OpenAPI from modules' contributions. **Adding a feature later adds only a directory** — no central route file, no central schema file — which is the property that keeps a four-slice burst from merging through one file. `server.ts` refuses duplicate module names and unknown schema owners.

### 8.3 Store: Firestore, behind a repository interface

**Production store: Cloud Firestore.** Alternatives:

- **Firestore — chosen.** It is already in the dependency tree (`@google-cloud/firestore` in `backend/gemini-agent/package.json`), already used by the live session store (`backend/gemini-agent/src/session/liveSessionStore.ts`), and the overhaul engineering plan's test target is its emulator. Community data is document-shaped (publications with revisions, table cards, challenge entries), mostly read, moderate write volume, no cross-table transactions beyond membership counters — a fit for Firestore's model. Using it avoids standing up Postgres operations (migrations, connection pooling, backups) that burst5 does not have an owner for.
- **Postgres** — rejected for burst5: the stronger long-term store for rich queries, but nothing else in FridgeLuck runs a SQL database server today; introducing the first one for the smallest feature inverts the operational gradient.
- **Convex** — rejected for burst5: Sam once preferred it (overhaul §10.6), but it is a new platform dependency, and the community spec must not couple burst5 to a provider decision Sam has not made. The repository interface below is what makes "move to Convex later" a bounded change instead of a rewrite.

**Repository interface**: every module talks to its store through interfaces defined in `src/core/repositories/` (e.g. `PublicationRepository`, `TableRepository`), with a Firestore implementation per module and an **in-memory implementation per module for tests**. The interface is the seam for a later store swap; modules never import `@google-cloud/firestore` directly.

**Local/test running**: unit tests run against the in-memory repositories with zero infrastructure. Integration tests run against the **Firestore emulator**: `FIRESTORE_EMULATOR_HOST=localhost:8089`, booted by `bun run test:integration` (starts the emulator via `firebase emulators:exec` or the standalone jar, seeds fixtures, runs, tears down). The emulator is the same target the overhaul engineering plan named. CI runs both tiers; neither needs GCP credentials.

### 8.4 Server shape

- Bun-native (`Bun.serve` with the same express compatibility gemini-agent uses, or plain `Bun` router) — matches the repo's `packageManager: bun@1.3.10` convention.
- Every response validates against the module's contribution to `contracts/openapi.yaml` in tests (round-trip: examples in `contracts/examples/` are replayed as request fixtures).
- Config via environment (`PORT`, `FIRESTORE_PROJECT_ID`, `APPLE_BUNDLE_ID`, `OPERATOR_ACCOUNT_IDS`, `COMMUNITY_BASE_URL` for link building); no secrets in code; the Apple JWKS is fetched, not vendored.
- Health: `GET /healthz` like gemini-agent (`backend/gemini-agent/src/server.ts:32`).

## 9. App side

All iOS community work lands in the directories the shared contracts pin. No thread edits `apps/ios/Platform/Persistence/Database/Migrations.swift` (today a single 537-line file, `apps/ios/Platform/Persistence/Database/Migrations.swift`); community migrations live in their own subsystem file.

### 9.1 `CommunityMigrations`

New file `apps/ios/Platform/Persistence/Database/Subsystems/CommunityMigrations.swift`, registered the way the other subsystems (`RecipeCatalogMigrations`, `TasteMigrations`, `CookSessionMigrations`) are or will be, with identifiers prefixed `community_`:

| Migration | Tables | Purpose |
|---|---|---|
| `community_user_recipes_v1` | `community_user_recipes` | server linkage + publication state for cookbook recipes: `recipe_id` (FK to `recipes.id`), `server_recipe_id TEXT NULL`, `publication_state TEXT` (`private`/`author_only`/`published`/`in_review`/`withdrawn`), `published_revision INTEGER NULL`, `last_synced_at TEXT NULL` |
| `community_user_recipe_revisions_v1` | `community_user_recipe_revisions` | frozen revision snapshots (the publish payload form): `recipe_id`, `revision INTEGER`, `payload_json TEXT` (the exact contract JSON), `frozen_at TEXT` |
| `community_outbox_v1` | `community_outbox` | pending server writes (§9.3): `id INTEGER PK`, `operation TEXT` (`publish`/`withdraw`/`share_cook`/`table_event`), `payload_json TEXT`, `created_at TEXT`, `attempts INTEGER`, `next_retry_at TEXT NULL`, `last_error TEXT NULL` |
| `community_cache_v1` | `community_feed_cache`, `community_table_cache` | last-known Explore feed / table cards for offline (§9.4) |

The user recipe **content** tables stay owned by the cookbook (PR #71: `recipes`/`recipe_ingredients` rows with `source='user'`); the community tables hold only community state and frozen payloads.

### 9.2 Share preview builder

`SharePreviewBuilder` (Feature/Community layer) renders, from a user recipe at a given revision, the exact `publication.schema.json`/`shared-cook.schema.json` payload the client will send — the same struct, serialized once, previewed and sent. The "What leaves your phone" sheet (§2.3, §10.3) displays that struct; it is a rendering of data, not a parallel hand-built view that can drift from what is sent.

### 9.3 Outbox retry

All community writes from the phone go through `community_outbox`: the write is recorded locally first, then drained when online. Retry: exponential backoff (1 min → 2 → 4 → … capped 1 h, `next_retry_at`), attempts logged with `last_error`. Idempotency: every operation carries a client-generated `operationId` (UUID) — the server deduplicates (contract: identical `operationId` replays the first response, not a duplicate write; overhaul's idempotency principle, `pstack-principle-make-operations-idempotent`). Ordering per recipe/operation is preserved by `created_at` + attempt; outbox items are removed only on confirmed success. Conflicts surface to the user, never auto-resolve: e.g. a `publish` answered `409 recipe_revised_offline` (§10.3 error state).

### 9.4 Offline

- **Authoring** (create/edit/duplicate recipes, cook, rate) is fully offline, unchanged from the cookbook.
- **Publishing/share**: queued in the outbox; the publish sheet shows "Will send when you're online."
- **Explore offline**: renders `community_feed_cache` (last fetch, ≤ 24 h old shown as "As of 18:40" like the Table mock), with **fit still computed locally** (ranking never needed the network for inputs); a stale banner, never a blank page.
- **Tables offline**: same cached-cards behaviour as the overhaul mock's offline state.
- **First run / never signed in**: community surfaces show their empty states (§10.2) with a sign-in prompt at the point of share intent only — no account nags in cooking flows.

### 9.5 API client

`CommunityAPIClient` (Feature/Community) is a thin typed client generated/validated against `contracts/openapi.yaml`, with its response decoding **tested against `contracts/examples/`**: every example fixture is decoded in a unit test, so a contract change that breaks the app fails a test the same day it lands. Auth token storage in the Keychain; refresh handled transparently with one retry on 401.

## 10. Mocks, in words

Mocks are words, not images: the app shell and visual direction are decided in the separate UI redesign (overhaul §5), so every screen below is specified by purpose, entry points by **user intent** (never tab position), layout top to bottom with exact copy, every state, the data each interaction changes, and accessibility. The Table feed is specified already on the overhaul branch (`mocks/community.html`) and adopted verbatim (§10.7).

Accessibility rules that bind every screen below, stated once: every control has a VoiceOver label and hint; Dynamic Type must lay out correctly to XXL (cards reflow, no fixed heights); interactive targets ≥ 44 pt, ≥ 64 pt in cook mode; Reduce Motion replaces all springs/movement with fades ≤ 200 ms; contrast ≥ 4.5:1 for body text (overhaul §5 craft rules).

### 10.1 Explore

- **Purpose**: answer "what could I cook that others made?" — ranked by what you can make now; a ranked list, never a feed to perform into.
- **Entry points**: intent "I want inspiration from people like me" (Explore surface); intent "cook something from a challenge I joined" (challenge-sourced filter); intent "see that recipe again from a shared link" (deep link to a publication).
- **Layout, top to bottom**:
  1. Title **Explore**, line under it: **"What could you cook tonight?"**
  2. Filter row: chips `Under 30 min`, `Vegetarian`, `Your challenges`, and a filter button. Chip copy is literal.
  3. Recipe cards, each: dish name; author first name ("Maya"); the **fit line**, identical in wording to every fit line in the app (§3.1) — e.g. "9 of 10 · 1 swap" or "7 recorded · check eggs and oil"; time ("27 min"); "cooked by 37 people" only when the ≥ 10 rule holds (§3.2); allergen tag row when tags exist. No likes, no followers, no avatars.
- **States**:
  - *First run, no account*: cards render (catalog + published recipes are public), share/publish affordances hidden; a single footer line "Sign in with Apple to share your own."
  - *Empty (no publications yet, catalog only)*: header card "The kitchen just opened. Be one of the first to share a recipe." then catalog cards.
  - *Loading*: skeleton cards, exact card height pre-reserved (no layout shift).
  - *Offline*: `community_feed_cache` with "As of 18:40" under the title; fit still computed locally; report/upload affordances disabled with hints.
  - *Error*: "Couldn't reach Explore. Your saved recipes are safe on this phone." + Retry.
  - *Partial data*: a card whose author has since withdrawn renders from the local copy with "no longer available" under the title and no "Cook tonight".
- **Interactions → data**: tap card → recipe detail (fetches the full published revision, cached to `community_feed_cache`); chip → local filter (no request); pull-to-refresh → `GET /v1/explore/feed` (no profile in the request).
- **Accessibility**: card is one VoiceOver element: "Butter bean curry, by Maya, 9 of 10 lines sufficient, 1 swap, 35 minutes, cooked by 37 people"; fit line is the value, not decoration.

### 10.2 Recipe editor (community additions only)

- **Purpose**: write and revise your own recipe. The editor itself is the cookbook's (PR #71 `CookbookRecipeEditor`); the community adds the publish affordance and the provenance line.
- **Entry points**: intent "write down something I made" (new recipe); intent "fix or improve my recipe" (edit → new revision); intent "make it public" (publish from the editor).
- **Community additions, in place**: a provenance row under the title: "Your recipe — private until you share it." For imported/generated recipes: "Imported — this one stays on your phone." A **Share** button, disabled with reason line when the §2.3 gate fails ("Sign in with Apple to share", "Sharing is 18+", "This recipe was imported from elsewhere").
- **States**: every editor state is the cookbook's; the community adds:
  - *Unpublished edits on a published recipe*: banner "You've changed this since publishing. Publish again to share the changes." (edits fork to a new revision, §2.2).
  - *In review*: the recipe page (not editor) shows "In review — hidden from Explore until a person checks it."
- **Interactions → data**: Save → local cookbook write + new local revision; Share → publish flow (§10.3).

### 10.3 Publish preview ("What leaves your phone")

- **Purpose**: make the boundary visible and consented before anything leaves the device.
- **Entry points**: intent "publish my recipe" (Share from editor or recipe page).
- **Layout, top to bottom**:
  1. Title **"What leaves your phone"**
  2. The payload, rendered as a read-only preview of the exact outgoing struct (§9.2): title, description, servings, time, ingredient lines, steps, equipment, tags, author first name.
  3. The negatives, verbatim: **"Never sent: your pantry, health information, taste profile, photos, or anything else about you."**
  4. Two checkboxes: **"This recipe is mine."** / **"It has no personal information in it."** Both required.
  5. Primary button **"Share to Explore"**, disabled until both boxes are checked. Secondary: "Keep private."
- **States**:
  - *Local screening failure before the sheet*: the sheet does not open; the editor shows the failed rule ("Add a checked temperature for the chicken — see the safety guidance").
  - *Submitting*: button becomes "Sending…" with spinner; no layout shift.
  - *Offline*: button reads "Share when online" and queues to the outbox (§9.3); a note "Will send when you're online." replaces the button.
  - *Server `422` (declaration missing)*: inline "Both confirmations are needed to share." (should be unreachable via UI; still specified for the client).
  - *Server `503` (screening unavailable)*: "We couldn't check the recipe right now. Nothing was shared. Try again soon." — never a silent queue into public visibility.
  - *`queued`*: success screen "In review. We check every recipe before it appears in Explore." Publication state becomes `in_review` locally.
  - *`409 recipe_revised_offline`*: "You changed this recipe since you tried to share it. Share the new version?" → re-opens the preview with the current revision.
- **Interactions → data**: confirm → outbox `publish` operation → server publication + moderation; cancel → nothing stored server-side, ever.
- **Accessibility**: the preview is plain text, fully traversable; each checkbox is one element with its exact copy as the label; the negative list is read as one paragraph.

### 10.4 Challenge page

- **Purpose**: everything about one challenge — brief, ingredient set, your entry, everyone's entries.
- **Entry points**: intent "join something bigger than dinner tonight" (challenge surface); intent "open a challenge link someone sent" (deep link).
- **Layout, top to bottom**:
  1. Challenge name, e.g. **"3 ingredients: eggs, tortillas, scallions"**; type badge ("Battle" / "Use-it-up" / "Budget $10").
  2. One-line brief: "Cook something using all three. One entry each. You vote for your favourite when entries close."
  3. Timeline line, states-aware: "Entries close Fri 18:00 · Voting ends Sun 18:00."
  4. Ingredient set row (battle): the three items with quantities as `resolvedItems` names.
  5. **Your entry** block (if entered): your dish card + "Change entry" before `entryClosesAt`; if not entered: "Enter with a recipe you've published" + entry button (goes through the publish flow if not yet published — a battle never bypasses moderation, §5.2).
  6. Entries list during `open`/`voting`: dish name, author first name, one-line note, fit line. **No vote counts** during voting (§5.3).
  7. After `closed`: top 3 with "most cooked" wording: "Most cooked this week" — no "winner", no prizes (§5.2).
- **States**: empty entries ("No entries yet. Be the first."), voting-not-yet-open ("Voting opens when entries close Friday."), closed-but-empty ("Nobody entered this one."), loading/offline/error as §10.1. *Account under 24 h*: entry allowed; vote button shows "Your vote counts tomorrow" (§5.3).
- **Interactions → data**: enter → `POST /v1/challenges/{id}/entries` (links the published `RecipeRef`); change entry → replaces entry, moves own vote; vote → `PUT /v1/entries/{id}/vote` (one vote, movable until close; self-vote never counted).
- **Accessibility**: timeline is one VoiceOver element with full sentence; each entry card one element ending "vote" as an action, not a separate unlabeled button.

### 10.5 Battle vote

- **Purpose**: choose the entry you'd most want to cook — quietly, with no scoreboard pressure.
- **Entry points**: intent "pick my favourite in a battle" (from the challenge page during voting).
- **Layout**: the entries list becomes a choice list. Each card ends with a **"Vote"** button (44 pt). Selecting one card's Vote moves your vote there (no confirm dialog; an undo is the same gesture on another card). Copy under the list: **"Your vote is private. Counts appear when voting ends."**
- **States**: *no vote yet* ("Vote for the one you'd cook."); *voted* (the voted card carries "Your vote", others plain); *under-24h account* ("Your vote counts tomorrow."); *voting closed* (buttons replaced by final "Most cooked" ranking, §5.2); *error on vote* ("Couldn't record your vote. It isn't saved yet." + Retry — optimistic UI is explicitly NOT used here; a vote is saved or says so).
- **Interactions → data**: vote → server vote row (anonymous); moving vote → update; nothing else. No broadcast, no notification to the entry author that they received a vote.
- **Accessibility**: vote button label is "Vote for [dish name]"; selected state announced as "your vote".

### 10.6 Invite (Table)

- **Purpose**: bring one specific person into a Table, with the owner in control.
- **Entry points**: intent "start a table with someone I eat with"; intent "add one more person to my table".
- **Layout (share sheet)**: table name (editable, e.g. "Flat 4B"); a 6-character join code and a link `https://…/join/{code}`; the text "Anyone with this link asks to join. You approve." Buttons: Share link, Copy code, Done.
- **States**: *invite pending* (joiner sees "Asking Flat 4B…"; owner sees a pending row "Dev wants to join" with Approve / Decline); *expired* (7 days: "This invite has expired. Make a new one."); *revoked* (link dies immediately); *table full* ("Tables are 2–8 people. Someone has to leave first.").
- **Interactions → data**: create invite → server invite row (code stored hashed); approve → membership row; revoke → invite `revoked`; join request from a blocked pair is refused silently (`404` to the blocked joiner, §7.3).
- **First-appearance rule** (mock, adopted): the invite prompt never appears in onboarding; it first appears after the third cook.
- **Accessibility**: the join code is exposed as selectable text with "Copy code" as the accessible action (no manual transcription required).

### 10.7 Table feed — adopted verbatim

The Table feed (cards in time order, one "Cook tonight" button per card ending in the viewer's own fit meter, aggregate "Notes on recipes you've cooked" at ≥ 10 cooks, "Be the first to leave a note" below, own cook rendered without a button, motion/states for no-table/alone/quiet/loading/offline/error/invite/leave) is specified in `mocks/community.html` on the overhaul branch and adopted **verbatim** into this spec by reference; its copy ("Tables are small on purpose: 2 to 8 people who cook. Start one with someone you eat with." / "Leave Flat 4B? Your cooks stay in your Cookbook.") is exact copy. The data underneath is §4.

### 10.8 Report and block

- **Purpose**: give every member an immediate, honoured exit from content or a person, with no confrontation.
- **Entry points**: intent "this shouldn't be here" (report, from any card/recipe menu); intent "I don't want to see this person" (block, same menu).
- **Layout (report sheet)**: title **"Report this"**; reason list, each a full-width row: "Food safety", "Not their recipe", "Personal information", "Spam", "Harassment", "Something else"; optional one-line detail ("Anything we should know? (optional)"); button **"Report"**. After: "Thanks — we've hidden this while it's reviewed." The content disappears immediately, for everyone.
- **Layout (block confirm)**: "Block Maya? You won't see each other's recipes or cooks. Maya won't be told." Buttons: "Block" / "Back".
- **States**: report failure (offline) → "Report saved on your phone. We'll send it when you're online." (queued via outbox — a report is never dropped); double-report of the same target is idempotent (one case).
- **Interactions → data**: report → `POST /v1/reports` + immediate hide; block → `PUT /v1/blocks/{accountId}` + both-direction filtering; unblock reverses visibility only going forward.
- **Accessibility**: reasons are one VoiceOver element each; the sheet is a modal with a proper title and escape ("Back" cancels, nothing recorded).

### 10.9 Moderation states an author sees

One vocabulary, everywhere (recipe page, challenge entry, Table card), so an author is never left guessing:

| Author-visible state | Appears when | Exact copy |
|---|---|---|
| **Private** | never published | "Private — only you can see this." |
| **Published** | live in Explore | "In Explore." (+ "Remove from Explore" action) |
| **Flagged** | non-blocking screening note | "In Explore — one tag is being double-checked." |
| **In review** | `queued` (report, blocking screen, sampling) | "In review — hidden from Explore until a person checks it." |
| **Removed by review** | `rejected` by operator | "Removed by review. Reason: [rights / food safety / personal information / other]. You can edit and share a new version." |
| **Withdrawn** | author or deletion | "Removed from Explore. Your recipe is still yours, here." |

No counters, no "reported N times", no reporter identity — ever (§7.4).

## 11. Events for the taste spec

Community surfaces emit `TasteEvent`s (shared contract: `{"id": uuid, "at": ISO-8601 UTC, "kind": string, "eater": string|null, "recipe": RecipeRef|null, "ingredient": IngredientID|null, "surface": string, "payload": object}`). The taste spec owns kinds and payloads; this spec lists what its surfaces emit. All community events carry `surface: "community"` and are **local records on the phone** — they leave the device never (overhaul §3.3).

| kind | recipe | payload | When |
|---|---|---|---|
| `community.recipe_created` | the RecipeRef | `{"revision": 1}` | a user recipe is created (private) |
| `community.recipe_revised` | RecipeRef | `{"revision": int}` | an edit forks a revision |
| `community.recipe_published` | RecipeRef | `{"revision": int, "queued": bool}` | publish accepted (`queued` records moderation reality) |
| `community.recipe_withdrawn` | RecipeRef | `{"revision": int}` | withdrawal |
| `community.recipe_duplicated` | RecipeRef | `{"duplicatedFrom": {"source": "user", "id": string, "revision": int, "author": string} \| null}` | duplicate from Explore or self |
| `community.explore_open` | null | `{"cardCount": int, "cacheAgeHours": number \| null}` | Explore surfaced |
| `community.explore_recipe_viewed` | RecipeRef | `{"rank": int \| null}` | a card opened (rank = position in the user's own ranked list) |
| `community.explore_cooked` | RecipeRef | `{"revision": int, "via": "explore" \| "table" \| "challenge" \| "link" \| "friend"}` | a community recipe was cooked |
| `community.cook_shared` | RecipeRef | `{"rating": int \| null, "swaps": int, "to": "table" \| "friend" \| "challenge"}` | a shared cook sent |
| `community.table_cook_tonight` | RecipeRef | `{"authorName": string \| null}` | "Cook tonight" tapped on a Table card |
| `community.challenge_entered` | RecipeRef | `{"challengeId": string, "challengeType": string}` | entry created |
| `community.challenge_voted` | null | `{"challengeId": string}` | vote cast or moved (never which entry — votes are private; even the local event records only the challenge) |
| `community.challenge_entry_completed` | RecipeRef | `{"challengeId": string, "challengeType": string}` | the entry's dish cooked |
| `community.account_18plus_attested` | null | `{}` | the gate answered |
| `community.report_submitted` | RecipeRef \| null | `{"targetType": string, "reason": string}` | a report filed |

Notes for the taste spec:

- **`community.explore_cooked` is the highest-value learning signal the community adds**: it is a cook that arrived from outside the user's own loop, so availability is not preference (overhaul §3.3) — the exposure came from a person, not from what the app showed. It should weigh like a deliberate user choice, not like a recommendation impression.
- **`community.explore_recipe_viewed` is weak evidence by design**: viewing a ranked card is closer to "the app showed it" than "I chose it"; the taste engine should log it as exposure, not preference.
- **What never feeds taste — other people's data.** No event derived from another person's behaviour ("37 people added lemon", a Table member's rating, aggregate notes, vote outcomes) may enter the local taste model. Other people's data informs *presentation* (counts, notes shown on cards), never *learning*. This is the community-side restatement of "nothing about taste leaves the device": the profile learns only from what this eater did, including what this eater chose from what others made.
- Event ids are UUIDs generated on the phone; `eater` is the local eater label ("you"/household attribution per overhaul §2), null when unattributed.

## 12. Implementation slices

Three packets, exactly the burst5 community packet ids. Later threads start from these slices without asking anyone. Each owns distinct files; none edits another's directories. All iOS local-persistence work lands through `apps/ios/Platform/Persistence/Database/Subsystems/CommunityMigrations.swift` (identifiers prefixed `community_`); all backend work in `backend/community/src/modules/<name>/`; all contracts in `docs/spec/community/contracts/`.

### 12.1 `burst5-fridgeluck-community-api`

- **Owns**: `backend/community/` (package scaffolding: `package.json`, `tsconfig.json`, `src/server.ts`, `src/core/`), modules `src/modules/identity/`, `src/modules/recipes/`, `src/modules/moderation/`, `src/modules/explore/`, and `test/` (in-memory repositories + Firestore emulator harness).
- **Public types and functions**: `ModuleContext`, `ModuleDefinition` (the discovery shape, §8.2); `SessionCore` (`createAccessToken`, `rotateRefreshToken` per §7.1, ported from PR #104 `shared/sessionCore.ts`); `AppleVerifier` (`verifyIdentityJWS` per §7.1, ported from `identity/appleVerify.ts`); `PublicationRepository` (`create`, `publish`, `queue`, `reject`, `withdraw`, `get`), `ScreeningPipeline` (`run: food-safety lint + allergen tagging + personal-data check`, fail-closed); `ExploreRepository` (`feedCandidates`, `cookCount`); in-memory + Firestore implementations of each.
- **Tests**: module boot/discovery test (duplicate names refused); Apple JWS verification table (good, wrong-aud, expired, replayed nonce, wrong-issuer); session rotation family-revocation; publish state machine (`published`/`queued`/`rejected`/`withdrawn`, content-hash-bound approval); screening fail-closed `503`; explore visibility derivation incl. blocked-pair filtering; examples round-trip: every response validated against `contracts/openapi.yaml` and replayed from `contracts/examples/`.
- **Done when**: `bun test` (in-memory) and `bun run test:integration` (Firestore emulator) pass with no GCP credentials; `GET /healthz` answers; a module added as a directory-only change boots without editing `server.ts`; every endpoint's example in `contracts/examples/` round-trips.

### 12.2 `burst5-fridgeluck-community-client`

- **Owns**: `apps/ios/Platform/Persistence/Database/Subsystems/CommunityMigrations.swift`; `apps/ios/Platform/Persistence/Community/` (`CommunityStore`, `OutboxService`, `CommunityAPIClient`); `apps/ios/Feature/Community/` (`SharePreviewBuilder`, publish flow views, Explore views); adopts PR #106's `packages/FLCommunityCore` types (`RecipeSharePayload`, `RecipeRightsDeclaration`, `RecipeExportGate`, `SharedCook`, `ExploreRanking`) as the Swift-side source of truth, extended with the revision and outbox model #106 lacks (its research found no server contract, API client, outbox or moderation states in the package).
- **Public types and functions**: `CommunityStore` (`publicationState(of:)`, `recordRevision`, `freezePayload`); `OutboxService` (`enqueue`, `drain`, retry/backoff per §9.3, `operationId` idempotency); `CommunityAPIClient` (one method per contract operation; Keychain session storage; transparent refresh); `SharePreviewBuilder` (`preview(for revision: RecipeRevision) -> PublicationPayload` — the exact outgoing struct); view-state models for Explore and publish.
- **Tests**: migration test (`community_*` identifiers register and upgrade, following `apps/ios/Tests/MigrationUpgradeTests.swift`); outbox retry/backoff/dedup table tests; APIClient decoding of **every fixture in `contracts/examples/`** (a contract change that breaks the app fails here); `SharePreviewBuilder` redaction test (no pantry/health/taste/instant fields — extending PR #106's `SharedCookRedactionTests` policy to publications); Explore ranking fixture tests against #106's `ExploreRanking` formula; publish state machine UI states per §10.9.
- **Done when**: all portable tests pass in CI (macOS host compiles the app target; `packages/` stays outside CI per current reality — the PR #106 finding that CI doesn't build `packages/` is respected, so the outbox/client logic that must be CI-verified lives in `apps/ios/` test targets, not only in the package); every contract example decodes; the publish flow renders "What leaves your phone" from the same struct that is sent.

### 12.3 `burst5-fridgeluck-community-groups`

- **Owns**: `backend/community/src/modules/tables/` and `backend/community/src/modules/challenges/` (including battles); `apps/ios/Feature/Community/Tables/` and `.../Challenges/`; the web link pages `GET /web/challenges/{id}` (server-rendered, §5.4).
- **Public types and functions**: `TableRepository` (`create`, `approve`, `revoke`, `remove`, `leave`, `shareCook`); `ChallengeRepository` (`get`, `list`, `enter`, `replaceEntry`, `vote`, `results`); `BattleService` (lifecycle transitions `draft→open→voting→closed`, self-vote exclusion, 24 h vote-age rule, no-live-tallies derivation); `PackResolver` (`resolve(packId) -> resolvedItems`, freezing the snapshot per §5.5, referencing PR #116 data by `packId`/`usdaFdcId`).
- **Tests**: table lifecycle (invite approve/revoke/expire, 8-member cap `409`, departed-member card redaction §4.1); block-pair filtering inside tables; battle vote integrity (one vote per account, movable, self-vote not counted, tally hidden until `votingClosesAt`, 24 h rule); pack freeze immutability (pack file change does not mutate a running challenge); link pages render without auth; examples round-trip for every new endpoint.
- **Done when**: emulator integration tests cover the full battle lifecycle and the full table lifecycle; `GET /web/challenges/{id}` renders from seeded data with no session; contract examples for tables/challenges endpoints all validate.

### Dependency order

`community-api` → `community-client` (needs identity + recipes + explore) → `community-groups` (needs identity; extends the same modules). The client slice may start against contract examples before the API slice finishes — that is what the examples are for.

## 13. Decisions taken, and the open ones for Sam

Closed in this spec (default chosen, reversible, one line of why each):

1. **Explore leads; campus waits** (§1) — matches the September direction; works with zero partner dependencies.
2. **Battles ride along as a challenge type**, not a separate surface — one lifecycle, one vote rule, five kinds (§5).
3. **PR #104's backend logic is adopted, re-homed** from `backend/gemini-agent/` to a separate `backend/community/` package with module discovery (§8) — the packet brief binds the location; the logic deserved the rescue.
4. **PR #106's Swift types are the client source of truth**, extended with revisions and an outbox the package lacks (§12.2).
5. **18+ extended to every sharing surface** (§7.2) — PR #104 gated only publishing; sharing to a Table is sharing.
6. **Sessions per PR #104 mechanics** (§7.1) — 15-min access, 30-day single-use refresh, family revocation. Better than the 24 h opaque-token draft; nothing here depends on the difference.
7. **Cook counts below 10 render as nothing**, never a small number (§3.2) — per PR #104's floor; "cooked by 3" reads as "nobody cooked this".
8. **No author appeal flow in burst5** (§7.2) — the rejected state carries the reason; an appeal needs an operator SLO that does not exist yet.
9. **Web links are read-only challenge pages**, no auth, no sharing API (§5.4) — enough for "look what we're cooking"; a share-sheet deep link into the app can come later.

Open — Sam decides, none blocks the three packets (§12):

- **O1 — moderation operator.** Until a person is named, `queued` cases wait hidden (§2.3, §7.6). If burst5 launches with Sam as the only operator, expect weekly queue-clearing; an SLO ("every case answered in 7 days") should be written down before launch, not after the first angry report.
- **O2 — Google Cloud project + Apple service key.** The backend is Firestore-native (§8); if GCP is not wanted, the Postgres alternative in §8 is a different schema day — say so before `community-api` starts.
- **O3 — moderation-operator identity.** A single allowlisted account id in config (§7.6) is the minimum; a second account for review independence costs nothing to add now.
- **O4 — budget challenge spend verification.** Out of scope (receipts are iOS-native scanning work, PR #51); if Sam wants budget challenges to *verify* spend rather than trust the entry note, that is a separate packet after burst5.

## 14. Evidence appendix

Drafted against, verified in this session (alpha checkout + PR threads):

- **Overhaul SPEC** — branch `docs/spec-overhaul-20261011`, `docs/spec/overhaul-20261011/SPEC.md` (community §3.4, Tables mock `docs/spec/overhaul-20261011/mocks/community.html`), and Sam's stage-0 brainstorm `docs/brainstorm/community-stage0.md`.
- **PR #104 (community backend draft)** — read at sha `branch pr/104` as of 2026-10-15. Gave: Apple RS256 JWKS verification with audience/issuer/nonce checks (`identity/appleVerify.ts`); `fla1.`/`flr1.` session tokens, 15-min/30-day TTLs, single-use refresh with family revocation (`shared/sessionCore.ts`); publication states `published/queued/rejected/withdrawn`; content-hash-bound moderation approvals; fail-closed food-safety gate (`503` when screening packages unloaded); mutual blocks; 10/day report limit; resumable deletion plan (`safety/deletion.ts`); `cookedBy` floor 10. Caveats recorded: 18+ enforced only on publishing (extended here); lives under `backend/gemini-agent/` and `server.ts` never mounts it (re-homed to a separate `backend/community/` package here per the packet brief); collections `communityBattleVotes`/`communityRetentionRecords` unused.
- **PR #106 (FLCommunityCore)** — `packages/FLCommunityCore` on alpha as of 2026-10-15: `RecipeSharePayload`/`RecipeRightsDeclaration` redaction policy (frozen wire keys, no instants/pantry/health/taste), `RecipeExportGate`, `SharedCook`/`SharedCookSwap`, `ExploreRanking` (0.6 fit + 0.4 taste, 6 dp, 5-level tie-break), `UserRecipe` via `RecipeKey(source:.user, sourceRecipeID, revision)`, fixtures under `Fixtures/`. Caveats: no API client, outbox, Tables model, or moderation states in the package; CI does not build `packages/`; `check_core_fixtures.py` hardcodes the `fldomain.v1` path.
- **PR #71 (personal cookbook draft)** — `CookbookRecipeEditor` exists; edits are in-place (no revision numbers), duplicate provenance and import gating are absent — §2 supersedes.
- **PR #116 (challenge packs draft)** — pack data keyed by `packId`/`usdaFdcId`; no community join contract — §5.5 freezes packs at challenge creation and references its data without modifying it.
