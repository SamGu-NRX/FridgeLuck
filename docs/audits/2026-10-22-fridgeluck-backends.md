# FridgeLuck backends audit (2026-10-22)

Read-only audit of `backend/gemini-agent` and `backend/community` at `origin/alpha` 669b8114. Neither package runs in CI, so these findings come from reading each code path end to end and, where it was cheap, from running the real code locally.

Scope: allergen and diet handling, input validation at the HTTP and WebSocket boundaries, session and transcript retention, auth on webhooks and community routes, rate limits, and unbounded paid model calls. Out of scope because other tasks own it: validating `cookSession.eaters` inside `applySessionContext` (Z3), the PR #229 facts-review tests (Z4), and the community suite run (Z5).

"Proven" means I ran the production module locally and saw the result quoted. The gemini-agent proofs drive the real `attachLiveSessionGateway` or `createAgentServer` with a stub `GoogleGenAI` object that counts calls, plus the memory session store. The community proofs drive `buildApp()` on the memory store with the stub Apple verifier from `test/api.test.ts`. None of them made a model call, a network call, or used credentials. "Read-only" means the finding comes from reading the code alone.

## Findings, most severe first

### 1. Critical: the gemini-agent service has no authentication, and every route can start a paid model call (proven)

- `backend/gemini-agent/scripts/deploy-cloud-run.sh:35` deploys with `--allow-unauthenticated`. `src/agentServer.ts:57-168` and the upgrade handler at `src/agentServer.ts:182-194` never check a caller. The iOS client sends no credential either (`apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift:461` sets only `Content-Type`).
- Each WebSocket upgrade to `/v1/live` calls `ai.live.connect` right away (`src/services/liveSessionGateway.ts:213-214`) and writes a Firestore session document (`:168`). It does this before the client sends anything.
- `POST /v1/recipes/generate` (`src/agentServer.ts:57-77`) checks only that `ingredientNames` is a non-empty array. It caps neither the count nor the string lengths, and the body limit is 12 MB (`:46`). `/v1/reverse-scan/rank` has the same shape (`:79-101`).
- Nothing in the package limits requests per caller or session concurrency.
- Trigger: open `ws://<service>/v1/live` in a loop, or `POST /v1/recipes/generate {"ingredientNames":[50 000 strings]}`.
- Proof: 5 bare WebSocket connections produced 5 `live.connect` calls. One generate request with 50 000 names returned 200 after one model call whose prompt was 889 161 characters.
- Minimal fix: verify a caller credential in Express middleware and in the `upgrade` handler before `wss.handleUpgrade`. The community `fla1.` access token is already verifiable with `SessionCore.verifyAccess`, and Firebase App Check is the alternative. Then cap `ingredientNames` (for example 64 items of 80 characters) and add a per-caller limit on generate, rank and live connections.

### 2. High: a client that disconnects before Gemini Live connects leaks an open paid session (proven)

- `src/services/liveSessionGateway.ts:438-448`: on socket close, `closeSession()` closes `session` only if it is already set. The `connect` promise at `:213-214` assigns `session` after it resolves, and nothing checks whether the socket has closed in the meantime. The Live session stays open until Gemini's own limit.
- Trigger: open `/v1/live` and close the socket within the connect latency, then repeat.
- Proof: with `connect` delayed 200 ms, 3 early-close connections gave `live.connect=3 session.close()=0`.
- Minimal fix: after `await ai.live.connect(...)`, if `socket.readyState !== socket.OPEN`, call `session.close()` and return.

### 3. High: household restrictions never reach LeChef from the shipping app (backend effect proven, client cause read)

- `apps/ios/Feature/Assistant/LiveAssistantViewModel.swift:385` sends `"eaters": [["name": "you", "restrictions": []]]` in every bounded snapshot. The backend's allergen rechecks in `lookupSubstitution` (`src/lechef/reads.ts:304-332`) and the `getPlan` swap screen (`src/lechef/reads.ts:148-151`) then run against nobody. The phone rechecks a swap proposal when the user approves it, but read results go straight to the model and come back as spoken advice.
- An empty restriction list is valid input, so Z3's shape validation will not catch this.
- Trigger: a household with a milk allergy asks LeChef what to use instead of sour cream.
- Proof: with eaters `[{restrictions:["milk"]}]`, `lookupSubstitution("sour cream")` returned `swaps: []` with 9 violations. With no restrictions it offered `plain yogurt, greek yogurt, avocado`.
- Minimal fix: build `eaters` in `boundedSnapshot(from:)` from the household profile the phone already reads for `installHouseholdRecheck`. If the profile has not been read, fail closed: skip the snapshot and do not start the session. The test at `apps/ios/Tests/LiveProtocol/LiveProposalCoordinatorTests.swift:229-239` should assert that the restrictions appear in the snapshot.

### 4. High: a later `session_context` without `cookSession` wipes the eaters (proven)

- `src/services/liveSessionGateway.ts:487-499`: any envelope that carries `pantrySnapshot` or `recipes` but omits `cookSession` replaces the snapshot with a default cook session whose `eaters` is `[]`. This is the default-replacement path. Z3 covers validating the shape of eaters that are present, which is a different case.
- Trigger: `{"type":"session_context","payload":{"revision":4,"pantrySnapshot":{"revision":4,"items":[]}}}` sent after a snapshot that held a milk allergy.
- Proof: before the pantry-only envelope, `sour cream` gave `swaps: []`. After it, the same session offered `plain yogurt`.
- Minimal fix: merge each field into the existing snapshot (`cookSession ?? phone.sessionSnapshot()`), or reject an envelope that omits `cookSession` once the session has one.

### 5. High: publishing and challenge entries skip the server-side 18+ gate (proven)

- `docs/spec/community/SPEC.md:275` says every sharing surface needs an adult attestation and that "the server, not the phone, enforces the flag". Only Table cards check it (`backend/community/src/modules/tables/index.ts:469-478`). `POST /publications` (`src/modules/recipes/index.ts:36-76`) and `POST /challenges/:id/entries` (`src/modules/challenges/index.ts:231-290`) do not check it.
- Trigger: sign in with no `attest18Plus`, then `POST /v1/publications`.
- Proof: an account with `isAdult=false` got 201 and `state=published`, and the recipe appeared in the anonymous `GET /v1/explore/feed`. The existing `signUp` helper in `test/api.test.ts:49-56` publishes without attesting, so the suite currently treats this as normal.
- Minimal fix: move the Table check into a shared `requireAdult(accountData, clock)` in `src/core/http.ts`, call it in both handlers before `consumeRate`, and update the tests to attest.

### 6. Medium: an adaptation proposal passes the allergen screen when the session has no recipe id (proven)

- `src/lechef/proposals.ts:348-351`: when `session.recipeId` is undefined, the catalog filter yields no recipes and the code records "screened 0 recipe(s) ... no violations". The proposal is then routed. The iOS snapshot never sends `recipeId` (`LiveAssistantViewModel.swift:382-388`), so in the shipping app this branch runs for every adaptation. I did not check whether the phone rechecks adaptations on approval.
- Trigger: eaters `[{restrictions:["wheat"]}]`, a catalog holding a soy-sauce recipe, and no `recipeId`, then `proposeAdaptation {servings:4, change:"double it"}`.
- Proof: with `recipeId` set the proposal is blocked ("soy-sauce carries soy, wheat"). Without it, `submitted=true` and the proposal reaches the phone.
- Minimal fix: when `kind === "adaptation"` and `session.recipeId` is undefined, push an issue ("no current recipe, nothing to screen") so the proposal fails closed.

### 7. Medium: anyone can poison the process-wide confidence gate (proven)

- `POST /v1/confidence/outcome` (`src/agentServer.ts:120-130`) needs no auth, and its input is not validated. `ConfidenceService.recordOutcome` (`src/services/confidenceService.ts:122-147`) updates trust for whatever signal keys the caller names. One instance is shared by every live session (`src/services/liveSessionGateway.ts:117`). `assess_live_scene` reads the result, and its `exact` mode turns off the estimate-only response guard (`src/observability/responseGuard.ts`). Every call also appends to `events` (`:138`), which is never trimmed.
- Trigger: 300 posts of `{"assessment":{"signals":[{"key":"live.camera_frame","adjustedScore":1,"weight":1.6},...]},"outcomeReward":1}`.
- Proof: the live-scene signal set assessed as `review_required` (0.771) before the posts and `exact` (0.906) after. The service kept 1200 events in memory.
- Minimal fix: put the route behind the auth from finding 1 and accept outcomes only for an assessment id the server issued. Cap `events` with a ring buffer.

### 8. Medium: user text from tool calls goes to the logs, despite the "no transcript" contract (proven)

- `src/services/liveSessionGateway.ts:249` traces every model tool call with `fnCall.args`. `src/observability/tracing.ts:56` writes those args to stdout, which Cloud Logging keeps. `ground_food_safety.question` is declared as "The user's freshness or food-safety question" (`src/agent/systemPrompt.ts:83-95`), and `assess_live_scene.userQuestion` is the same kind of field. Both are logged twice, once by the gateway and again inside the handler (`src/agent/toolRegistry.ts:69,104`). `POST /v1/webhooks/tasks` logs its whole request body (`src/api/webhooks.ts:56`). Compare `liveSessionGateway.ts:415-416` ("the backend keeps no transcript") and the privacy note at the top of `src/session/liveSessionStore.ts`.
- Proof: a `lookupSubstitution` call logged `"args":{"ingredient":"sour cream"}`. A task body containing `"my allergy is peanuts"` was logged verbatim.
- Minimal fix: log only the arg key names in `startTrace`, and log `taskType` without `body`.

### 9. Medium: the WebSocket boundary accepts 100 MiB messages and has no per-session caps (proven)

- `src/agentServer.ts:171` creates the server without `maxPayload`, so ws's default of 100 MiB applies. `recordLatestFrame` (`src/services/liveSessionGateway.ts:520-548`) caches each image frame with no size check, and `src/services/frameCache.ts` bounds the cache by session count (500), not by bytes. `client_content` and `realtime_input` reach the model with no limit on count or size (`:414-421`). There is no idle timeout. The only bound on a connection is Cloud Run's 900 s timeout (`deploy-cloud-run.sh:37`). Model-driven `assess_live_scene` and `ground_food_safety` calls are separate paid calls, also with no per-session cap (`src/agent/toolRegistry.ts:68-115`).
- Proof: a 20 MiB `realtime_input` frame was accepted and cached (`maxPayload=104857600`, stored `sizeBytes=15728640`).
- Minimal fix: set `new WebSocketServer({ noServer: true, maxPayload: 2 * 1024 * 1024 })`, reject frames over a fixed size in `recordLatestFrame`, and keep per-session counters for turns and paid tool calls that close the session when they run out.

### 10. Medium: webhooks are unauthenticated (proven)

- `src/api/webhooks.ts:13` (`/scheduler`) and `:44` (`/tasks`) accept any caller. Scheduler is read-only today because the ledger is never written. `/tasks` lets anyone forge `cloud_task_received` log lines, which `README.md:126-133` treats as deployment proof.
- Proof: both returned 200 with no credentials.
- Minimal fix: verify the Cloud Scheduler or Cloud Tasks OIDC token (audience equal to the service URL, issuer `accounts.google.com`) before the handlers run.

### 11. Medium: anonymous sign-in attempts each fetch Apple's key set (proven)

- `backend/community/src/core/appleVerify.ts:147-150` fetches the JWKS on every verify, with no cache. `POST /auth/apple` (`src/modules/identity/index.ts:26-68`) is anonymous and has no rate limit. A flood of junk tokens becomes a flood of requests to Apple. If Apple throttles them, real sign-ins get 503.
- Trigger: `POST /v1/auth/apple` with header `{"alg":"RS256","kid":"k"}`, any payload, and a fresh UUID nonce.
- Proof: 25 anonymous attempts caused 25 JWKS fetches.
- Minimal fix: cache the JWKS in memory for its `Cache-Control` max-age, or 1 hour, and refetch only on an unknown `kid`, at most once a minute.

### 12. Low: session-context writes clear the recipe in memory mode and fail without any signal on Firestore (proven)

- The iOS client sends two `session_context` envelopes: recipe context, then the bounded snapshot (`LiveAssistantViewModel.swift:419-422`). The gateway patches the store with both fields every time (`src/services/liveSessionGateway.ts:502-509`), and `trimBoundedIngredients` turns a missing list into `[]`. On the memory store (`src/session/liveSessionStore.ts:179-194`) the second envelope wipes `selectedRecipe` and `confirmedIngredients`. On Firestore, `set({selectedRecipe: undefined})` throws, and `.catch(() => {})` at `:510` drops the error.
- Proof (memory): after the recipe envelope the store held `selectedRecipe=Udon, confirmed=1`. After the snapshot it held `undefined, 0`. Proof (Firestore, offline client against an unreachable emulator): the write was rejected with `Cannot use "undefined" as a Firestore value (found in field "selectedRecipe")` before any RPC.
- Minimal fix: build the patch only from keys present in the payload, and log the store error instead of discarding it.

### 13. Low: report and vote quota is spent before validation (proven)

- `src/modules/moderation/index.ts:37` calls `consumeRate` before `readObject` and field validation. `src/modules/challenges/index.ts:349` does the same before validating `entryId`. Publish was fixed for this earlier ("review finding 7", `src/modules/recipes/index.ts:73-76`), but these two routes were not. A buggy client loses a day of reports.
- Proof: ten `POST /v1/reports {"targetType":"nope"}` calls returned 422, and the next valid report returned 429.
- Minimal fix: move `consumeRate` below the validation and existence checks in both handlers.

### 14. Low: tables and invites have no write limit (proven)

- `POST /tables` (`src/modules/tables/index.ts:181-200`) and `POST /tables/:id/invites` (`:216-243`) never call `consumeRate`. Every invite is a pending record that lives 7 days, and each one adds a valid code to the 6-character join space.
- Proof: one account created 300 tables, then minted 300 invites on one table, with every request returning 201.
- Minimal fix: `consumeRate(ctx.store, "table-create", ...)` and `"table-invite"` with small daily caps, and a cap on pending invites per table.

### 15. Low: request bodies and `recipeRef.id` have no size limit (proven on memory)

- `src/app.ts:88` reads the whole body with `request.text()`, so only Bun's 128 MB default applies. `validateRecipeRef` (`src/core/validate.ts:44`) has no maximum for `id`. On Firestore an oversized document fails with a 500 after `consumeRate` has already spent the publish slot.
- Proof: a publish with a 2 MB `recipeRef.id` returned 201 on the memory store.
- Minimal fix: reject `content-length` above 256 KB in `handle()`, set `maxRequestBodySize` in `Bun.serve`, and cap `recipeRef.id` at 128 characters.

### 16. Low: recipe generation trusts the model to honor restrictions (proven)

- `src/services/recipeService.ts:25-27` puts `dietaryRestrictions` into the prompt as text and returns whatever the model writes (`:75-87`). Nothing on the server rechecks the output. The phone gates the result (`apps/ios/Capability/Core/Services/RecommendationEngine.swift:242`, `mayOfferGeneratedRecipe`), which is why this is Low.
- Proof: with `dietaryRestrictions:["peanut"]` and a stub model that returns "Peanut noodles", the route returned 200 with that recipe.
- Minimal fix: return structured ingredient lines and run `allergenViolations` over them against the given restrictions. If that is out of reach, document that the route is unscreened and that callers must gate its output.

### 17. Low: published diet tags are unchecked author text (proven)

- `validateRecipeContent` (`backend/community/src/core/validate.ts:152-156`) accepts any `dietaryTags`, and screening only runs them through the personal-data check (`src/core/screening.ts:344`). The server-computed `allergenTags` are correct. A "vegan" tag is shown even when the recipe contains milk.
- Proof: a publication with `dietaryTags:["vegan"]` and a milk line was published with `allergenTags:["milk","wheat"]`.
- Minimal fix: for each tag that `resolveRestriction` recognizes, run `allergenViolations` over every line and flag the publication on any violation.

### 18. Low: a closed live session's document can come back (read-only)

- `patchContext`, `recordFrameMetadata` and `recordLatestConfidence` all start with `ensureSession`, which creates the document if it is missing (`src/session/liveSessionStore.ts:243-256, 269-298`). Their gateway callers are fire-and-forget (`src/services/liveSessionGateway.ts:266, 502, 536`). A write still in flight when `deleteSession` runs at close (`:190`) recreates the document, and it then lives until `expireAt`, 24 h later. Nothing else can read it, because session ids are server-minted.
- Minimal fix: track a `closed` flag per connection and skip store writes after it is set. Alternatively, make the patch methods update an existing document only (`ref.update`) instead of calling `ensureSession`.

### 19. Low: community bookkeeping collections have no retention bound (read-only)

- The `nonces` collection (`src/modules/identity/index.ts:60`), `operations` (every publish, card and entry) and `rateLimits` (`src/core/rateLimit.ts:19-31`) are never deleted, and no TTL field is set on them. None of them holds content, but they grow forever.
- Minimal fix: add an `expireAt` field (for example 1 day for nonces, 30 days for operations, 2 days for rate counters) and a Firestore TTL policy on it.

## Checked and not a finding

- No community rate limit can be reset. The counters are keyed by account and UTC day (`src/core/rateLimit.ts:19-20`). Deleting an account blocks the same Apple identity from signing up again (`src/modules/identity/index.ts:96-98`), and replaying an `operationId` returns the stored response without spending quota. The only weakness is that the fixed UTC-day window allows two days' worth at midnight. gemini-agent has no rate limits to reset.
- Community auth is sound. Access tokens are HMAC-checked with `timingSafeEqual`, the account id comes from the session record rather than the token claims, refresh tokens rotate with family revocation, and operator routes check an allowlist (`src/core/sessionCore.ts`, `src/core/http.ts:12-24`).
- Live session documents expire 24 h after the last write, reads enforce that expiry, frames never reach the store, and the frame cache keeps frames for 2 minutes (`src/services/frameCache.ts`).

## Not covered

- I did not check whether the phone rechecks an adaptation on approval (finding 6). That decides whether the finding is Medium or High.
- Firestore transaction behaviour under contention and the community Firestore integration tests belong to Z5.
- This document is an audit with no code change, so the fail-first test rule does not apply. Each proof above says how it was reproduced.
