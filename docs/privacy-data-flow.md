# FridgeLuck Privacy & Data-Flow Map

Audited: 2026-10-09, `main` @ `1151588d6bc6f5dcc3e848b6115813ff36ffbf0d` (unless a PR-head ref is cited).
Every factual claim carries a `file:line` ref; `docs/check_refs.py` re-verifies all of them (`python3 docs/check_refs.py`).
PR heads cited: #13 `3e6d321f1a405be4b96aab37dd69aa7ac3df5491`, #8 `a9df6aa39e450c0f6d704acaf99baec6b36041af`, #5 `30f341847cec43b2788301ee07ee1e6a8cddb568`, #4 `8c9c88fed3007b8ce0f81f8b5684461f5ff698bc`.

**Load-bearing assumption.** This doc exists to drive a decision about the default cloud-send posture. That presumes the current behavior (cloud sends on by default for several flows) is accurate and worth changing or defending; if the hackathon build is retired as-is and never shipped further, the decision collapses and this doc is then just a record.

## 1. TL;DR — every outbound flow

| # | Trigger | Destination | Identifiers sent | Personal content sent | Local-only fallback |
|---|---------|-------------|------------------|----------------------|---------------------|
| 1 | Scan results open, high-confidence local path not taken | `POST {backend}/v1/recipes/generate` | None | Ingredient names, dietary restrictions, scan confidence, fridge photo (JPEG q0.72) | Yes (bundled recipe generator) |
| 2 | Same trigger, backend fails, `GEMINI_API_KEY` configured | `POST generativelanguage.googleapis.com` direct | None | Same fields as #1, image inline | Yes |
| 3 | Reverse meal scan, detection confidence < 0.93 | `POST {backend}/v1/reverse-scan/rank` | None | Detection labels+confidences, candidate recipe IDs/titles, meal photo (JPEG q0.72) | Yes (skips cloud, local ranking stands) |
| 4 | User opens a live cook-assistant session | `WSS {backend}/v1/live` | Random per-session UUID in query string | Recipe title/instructions/ingredients/quantities, confirmed-ingredient list, user text, camera frames (JPEG q0.55, ≤1 fps while screen open), microphone audio (PCM16 while listening toggled) | No — session ends; nothing stored locally |
| 5 | App active / inventory change / time-timezone change (use-soon rule enabled) | `POST {backend}/v1/notifications/plan` | Stable random UUID (`notificationSync_installationId`, persisted in UserDefaults), timezone, locale | Ingredient names, remaining grams, expiry dates, confidence scores | Yes (local fallback opportunities) |
| 6 | HealthKit write, user logs a meal | Apple Health (on-device OS service) | App-generated sync identifiers | Meal title, date, 7 nutrition values | N/A (already local) |

All app-to-backend calls share the base URL compiled into the binary: the hackathon Cloud Run service (`project.yml:116`, surfaced to the app via Info.plist build setting `project.yml:79` and read at `GeminiCloudAgent.swift:22` and `:27`). Requests carry no auth headers and no account concept (`server.ts` has no auth middleware on `/v1` routes; `server.ts:41`–`:122` are open posts).

## 2. Outbound flows in detail

### 2.1 Recipe generation via backend (flow #1)

Trigger: the results screen's `.task` runs after a fridge scan when ingredient names exist (`RecipeResultsView.swift:143`), passing the fridge photo re-encoded at JPEG quality 0.72 and the scan confidence (`RecipeResultsView.swift:144`). `RecommendationEngine.generateAIRecipe` routes to the cloud agent unless the high-confidence local path applies; the routing log line is `RecommendationEngine.swift:171`, the call `:173`.

Payload (`GeminiCloudAgent.generateRecipe`, signature `GeminiCloudAgent.swift:82`): ingredient names, dietary restrictions (from the local `health_profile`), scan confidence, optional photo base64. Backend request fields are assembled at `GeminiCloudAgent.swift:372`–`:375` (`ingredientNames`, `dietaryRestrictions`, `scanConfidenceScore`, `photoBase64JPEG`); the prompt embeds the same fields (`:124`, `:126`–`:128`, `:144`). The backend forwards to Gemini through the Google GenAI client, image included as `image/jpeg` (`backend/gemini-agent/src/services/recipeService.ts:13`, call at `:50`; route at `backend/gemini-agent/src/server.ts:41`).

### 2.2 Direct Gemini fallback (flow #2)

If the backend request fails and `GEMINI_API_KEY` is configured (env or Info.plist; `GeminiCloudAgent.swift:23`, `:30`), the agent calls Google's API directly from the device: `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` (`GeminiCloudAgent.swift:286`). Same fields as flow #1, image inline. If neither backend URL nor key is set the agent reports not-configured (`:73`, `:77`) and the app stays fully local for this flow.

### 2.3 Reverse-meal cloud re-ranking (flow #3)

Trigger: user photographs an eaten meal. `ReverseScanService.scan` runs on-device Vision first, computes local candidates, then — when overall detection confidence is below 0.93 and candidates exist — re-ranks through the backend (`ReverseScanService.swift:136`–`:137`), sending the meal photo at JPEG 0.72 (`:140`) plus detections and candidates (`:141`). Request field assembly mirrors flow #1 (`GeminiCloudAgent.swift:426` sends `photoBase64JPEG`; candidate list capped in the request struct, `:570` region). Backend route: `server.ts:63`. No identifier is attached; the photo and labels are the payload.

### 2.4 Live cook assistant (flow #4)

Trigger: the user opens a live session for a matched recipe — explicit per-session action (`ContentView.swift:743`–`:757` builds the route with a `LiveAssistantRecipeContext` containing title, instructions, ingredients and quantities; model at `LiveAssistantModels.swift:18`). Camera/microphone permission strings live in `AdditionalInfo.plist:16` (mic key; camera key at `:7`).

Transport: one WebSocket to `{backend}/v1/live` (path set at `GeminiLiveSessionClient.swift:38`; server upgrade gate at `backend/gemini-agent/src/server.ts:159`–`:171`). What crosses it:

- `session_context` envelope with recipe context and confirmed ingredients (`GeminiLiveSessionClient.swift:103`; payload assembled just above, including a hardcoded 0.95 confidence for confirmed ingredients).
- `client_content` text turns the user types (`:116`).
- `realtime_input` image frames — JPEG at quality 0.55 (`LiveAssistantCaptureCoordinator.swift:125`), throttled to at most 1 per second while the screen is open (`:119`).
- `realtime_input` audio chunks, PCM at the capture sample rate, only while `isListening` is toggled on (`GeminiLiveSessionClient.swift:142`, `:145`; toggle state at `LiveAssistantViewModel.swift:26`, `:241`).

The session UUID is generated per session and passed in the query string; it is not persisted app-side. Capture stops with the flow (coordinator tears down on stop); nothing from the session is written to local storage by the assistant.

### 2.5 Notification planning sync (flow #5)

Trigger: `handleAppDidBecomeActive` (`NotificationCoordinator.swift:46`) and inventory/time/timezone-driven refreshes; the use-soon rule gates the call (`:79` `guard rule.enabled`), and it is **enabled by default** (`NotificationModels.swift:12` `useSoonAlerts`, `:50` `defaultEnabled` returning true; rows seeded on first DB use at `NotificationRuleRepository.swift:109`). This is the only outbound flow that is on without a per-use action.

Payload (`NotificationSyncService.swift`): a stable random UUID persisted in UserDefaults under `notificationSync_installationId` (`:26`, created/persisted at `:118`–`:124`), timezone (`:61`), locale (`:62`), the rule (kind/enabled/hour/minute, `pushToken: nil`), and an inventory snapshot — ingredient ID, name, remaining grams, earliest expiry, average confidence (`:73`–`:82`). Endpoint `v1/notifications/plan` at `:84`. Backend route `server.ts:122` computes the digest in-process — a pure function, no model call, no persistence. Local fallback opportunities are generated when the sync fails (`NotificationCoordinator.swift:96`, `:103`–`:105`).

### 2.6 Apple Health (flow #6)

Reads seven dietary quantity types when authorized (`AppleHealthService.swift:36`–`:43`): energy, protein, carbs, fat, fiber, sugar, sodium. Writes a food correlation per logged meal with the same seven values (`:293`–`:302`), meal title as `HKMetadataKeyFoodType` plus app-generated external-UUID/sync-identifier/version metadata (`:320`–`:326`), via `healthStore.save` (`:155`, `:159`). Sync entry point is `MealLogSyncCoordinator.swift:19`; meal logging captures the photo locally first (`MealLogService.swift:43`). Usage strings: `AdditionalInfo.plist:18` (read) and `:20` (write). Nothing here leaves the device except into HealthKit itself.

## 3. What the backend retains and logs

- **Live-session store** — mode is `auto | memory | firestore` (`backend/gemini-agent/src/config.ts:3`); `auto` picks Firestore when a GCP project or emulator is configured, memory otherwise (`session/liveSessionStore.ts:101`–`:105`, Firestore branch `:108`). The record holds recipe context, `confirmedIngredients`, `latestConfidence`, **`latestCameraFrame`**, `mutationAudit` (last 30 inventory mutations), `lastUserMessage` (`liveSessionStore.ts:45`–`:49`, writes at `:154`, `:165`, `:175`, `:189`). No deletion or TTL path exists in the inspected store code.
- **Tool calls inside a session** — `assess_live_scene`, `ground_food_safety`, `mutate_inventory` (`agent/toolRegistry.ts:48`, `:79`, `:96`). Every tool call is traced to stdout **with its arguments** and sessionId (`observability/tracing.ts:12`, `:20`–`:25`, args captured at `:52`–`:56`) — so camera-frame-derived scene text and user questions can land in Cloud Run logs. The inventory ledger behind `mutate_inventory` is in-memory (`inventory/inventoryLedger.ts:13`–`:14`).
- **Webhook route** — logs the full request body of each cloud task (`api/webhooks.ts:56`, `console.log(JSON.stringify({... body}))`).
- **Recipe / reverse-scan / notifications routes** — no visible persistence in the route handlers (`server.ts:41`–`:122`); the request passes through to Gemini or the planner.
- **No auth on `/v1`** — any caller reaching the service can invoke recipe generation, reverse-scan ranking, or notification planning with arbitrary payloads.

## 4. Local-only storage (never leaves the device)

- **SQLite** at `Application Support/fridgeluck.sqlite` (`AppDatabase.swift:66`), GRDB, foreign keys on. Personal-data tables (15 migrations, `Migrations.swift`): `health_profile` (display name, age, goal, dietary restrictions, allergen IDs — v1 + v12), `cooking_history` (rows, `image_path`, servings, saved-winner flag — v1/v6/v14), `user_corrections` (vision label → ingredient), `ingredient_favorites` (v13), `pantry_assumptions` (v14), `inventory_lots`/`inventory_items`/`inventory_events` (v9, quantities + confidence), `confidence_signal_events`/`trust_vector_state` (v10), `notification_rules`/`notification_opportunities` (v15 — `Migrations.swift:449`), `badges`, `streaks`.
- **Meal photos** — JPEGs resized to max 1200px at quality 0.82 in Application Support/`MealPhotos` (`ImageStorageService.swift:7`, `:8`, `:19`), saved on meal log (`MealLogService.swift:43`), referenced by `cooking_history.image_path` (v6, `Migrations.swift:206`).
- **Scan diagnostics** — last 80 scan runs as JSON at Application Support/FridgeLuck/`scan_run_records.json` (`ScanRunStore.swift:52`, `:131`): input sources, provenance, crop/OCR evidence tokens, detection labels + confidences, pass errors. No images.
- **On-device inference** — Vision framework only: `VNClassifyImageRequest` (food labels) and `VNRecognizeTextRequest` (packaging OCR) (`VisionService.swift:9`–`:10`, `:369`). No network in the recognition path.

## 5. User controls — what exists, what's missing

Exists (`Feature/Settings/SettingsDataAndPrivacyView.swift`): a local-storage footnote (`:11`–`:13`), "Open iOS Settings" (`:16`), and "Reset all user data" (`:22`–`:29`) → `performFullReset` (`ContentView.swift:843`) → `UserDataRepository.resetAllUserData` deleting exactly five tables: `health_profile`, `cooking_history`, `badges`, `streaks`, `user_corrections` (`UserDataRepository.swift:158`–`:166`).

Gaps visible from the same code path:

1. **Reset misses files and diagnostics.** MealPhotos JPEGs and `scan_run_records.json` survive the reset; `ImageStorageService.delete(relativePath:)` (`ImageStorageService.swift:41`) has no callers in the app (grep: zero non-test call sites), so photo files are also orphaned when the referencing history row is deleted.
2. **Reset misses inventory, favorites, pantry assumptions, notification rules/opportunities, and the installation UUID.** The UserDefaults sweep in `performFullReset` covers tutorial + learning keys only; `notificationSync_installationId` persists.
3. **No server-side counterpart.** Nothing deletes Firestore session docs or requests log deletion — there is no account to hang a deletion request on.
4. **No toggle for flows #1–#3.** Cloud recipe generation, direct-API fallback, and reverse-scan re-ranking are silent on behavior; the only off switch is deleting the compiled-in backend URL (a rebuild) or not using the feature.
5. **Flow #5's only control is the use-soon rule toggle** in notification settings — effective (`:79` guard) but not framed as a data-sharing control.
6. **Flow #4 is the most consent-shaped by construction**: explicit per-session entry, per-session ID, capture stops with the screen. Remaining exposure is the backend-side retention above.

## 6. What changes on open PR heads (as of audit)

Checked `git diff origin/main <head>` for every open PR; only these touch data-flow surfaces:

- **#13** `3e6d321f` (fix/scan-failure-report): `ScanRunRecord` gains `outcome` (completed/failed + message) and `requestFailures` — failure records with error text join the **local** scan-run JSON (head file: `ScanRunStore.swift:35`, `:47`; `ScanContracts.swift:44`). Slightly widens what local diagnostics retain; nothing new leaves the device.
- **#8** `a9df6aa3` (fix/recognition-precision): same two fields on its base — same effect, local-only.
- **#5** `30f34184` (feat/meal-photo-confirmation-v1): reverse-scan confirmation UX in `ReverseScanMealView`; the `ReverseScanService` change is local template-fallback selection (`static func fallbackTemplate` at head `:367`). The cloud re-ranking call and its payload are unchanged.
- **#4** `8c9c88fe` (feat/minimal-product): `AppDependencies` passes `kitchenIngredientIDs` from inventory (`:137`); HealthKit macro writes gain swaps/portion scaling inputs (`MealLogService.swift:52`). No new destinations, no new fields leaving the device.
- **#3, #6, #7, #9, #11, #12**: no diffs in network, storage, notification-sync, HealthKit, or assistant files (file-list filter over full diffs).

None of the open heads change the default-on posture or add a destination.

## 7. Unknowns (not determinable from code)

1. **Deployed backend configuration** — whether the live Cloud Run service runs `sessionStoreMode` `auto`→Firestore or memory, and its Gemini client mode (Vertex AI vs Developer API). Read from the service's env at deploy time; the repo's `project.yml:116` only proves the URL.
2. **Provider retention** — Google's log/retention behavior for Gemini API/Vertex calls and Cloud Run/Cloud Logging is governed by accounts and console settings outside this repo. Not verified; treat as unbounded until checked.
3. **Account settings** — there is no account system, so "account settings control" is N/A rather than unknown.
4. **Log retention on the deployed service** — Cloud Logging sink configuration is not in the repo.

## 8. Backend-default decision — keep / opt-in / remove

Framing from `planning/stage_4-gemini_live/agent-architecture-scope-decision.md` and `planning/stage_4-gemini_live/user-direction-and-feature-intent.md`: the Cloud Run backend was chosen as the stage-4 hackathon default (GCP-first for competition compliance; `user-direction-and-feature-intent.md` "Pragmatic stage-4 default"). The privacy audit doesn't invalidate that reasoning — it prices what keeping it costs.

**Recommendation: keep cloud flows on by default, with two narrow changes.**

- **What improves under "keep":** the demo and rubric score (backend tool use is 30% of the stage-4 rubric), and the product's core promise — photo-grounded recipe generation and live assistance cannot work from bundled data alone.
- **What it costs:** flows #1/#3 ship fridge/meal photos plus dietary restrictions to a GCP service with no auth, no identifier, and no deletion path; flow #5 ships inventory contents by default with only a buried toggle; the backend logs tool arguments and full webhook bodies. For a hackathon demo build this is defensible; for any real distribution it is not.
- **The two changes that close most of the gap without touching the demo:** (a) stop logging tool arguments and webhook bodies, or redact before `console.log` (`tracing.ts:52`–`:56`, `webhooks.ts:56`) — one-file change each; (b) add TTL/deletion to the live-session store so `latestCameraFrame` and `lastUserMessage` don't outlive the session (`liveSessionStore.ts` — Firestore branch has no expiry path today).
- **"Opt-in" variant** — a first-run choice that gates flows #1/#3/#5 behind consent — is the right shape if this ships beyond the hackathon. It costs demo friction and a settings surface that doesn't exist yet (`SettingsDataAndPrivacyView` has no toggle infrastructure); flip to this if the app leaves demo status.
- **"Remove cloud" variant** — kills flows #1/#3/#4/#5, keeps the app fully local. Regains the cleanest privacy story and loses the graded demo paths; only right if the hackathon build is being retired.
- **What would reverse this call:** evidence that the deployed service runs Firestore with real sessions accumulating (turns "keep as-is" into "keep + TTL immediately"), or a decision to distribute the TestFlight build publicly before the changes above land.

**Stable-identifier check (explicit ask):** the only stable identifier sent anywhere is the random `notificationSync_installationId` UUID in flow #5 (`NotificationSyncService.swift:26`, `:118`–`:124`) — random, not derived from device or user identity. Flows #1–#4 send no identifier at all; live sessions use per-session UUIDs (`GeminiLiveSessionClient.swift:38` path + client-generated session ID).
