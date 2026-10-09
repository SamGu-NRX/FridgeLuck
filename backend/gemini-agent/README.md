# gemini-agent

Cloud backend for FridgeLuck's Gemini features. TypeScript running on Bun, Express, `ws`, and `@google/genai`, with optional Firestore persistence for live-session state.

What the iOS app uses it for:

- turning a scanned ingredient list into a recipe — `POST /v1/recipes/generate`
- re-ranking on-device recipe candidates against what the camera saw — `POST /v1/reverse-scan/rank`
- planning freshness notifications — `POST /v1/notifications/plan`
- live, voice-and-camera cooking sessions — `WS /v1/live`

> This service was built for a hackathon and is deployed with `--allow-unauthenticated`. It has no authentication of its own. Read [Security posture](#security-posture) before reusing it anywhere.

## Routes

| Method | Path | What it does | Called by the iOS app? |
|---|---|---|---|
| POST | `/v1/recipes/generate` | Generates a structured recipe (title, time, servings, instructions, calories per serving) from `ingredientNames`, dietary restrictions, and an optional base64 JPEG of the scan, using Gemini structured output. | Yes — `apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift` (`generateRecipeViaBackend`, endpoint built at line 369) |
| POST | `/v1/reverse-scan/rank` | Re-ranks locally produced recipe candidates against camera detections (and optionally the photo), returning per-candidate confidence and reason. | Yes — `GeminiCloudAgent.swift` (`rankReverseScanViaBackend`, endpoint built at line 404) |
| POST | `/v1/notifications/plan` | Pure local computation, no Gemini: turns notification rules plus an inventory snapshot into schedulable notification opportunities. | Yes — `apps/ios/Platform/Notifications/NotificationSyncService.swift` (`fetchFreshnessOpportunities`, endpoint built at line 84) |
| WS | `/v1/live` | Gemini Live bridge for the live assistant: relays client text turns, realtime audio/image input, and `session_context` patches to a Live model and streams events back. Session state lives in memory or Firestore per `LIVE_SESSION_STORE_MODE`. | Yes — `apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift` (socket request path set at line 38) |
| GET | `/healthz` | Liveness and config echo: `{ ok, model, vertexAi, inventoryCount }`. | No |
| POST | `/v1/confidence/assess` | Scores detection signals with the in-process Bayesian trust vector. | No |
| POST | `/v1/confidence/outcome` | Records an outcome (returns 204) that updates the trust vector. | No |
| GET | `/v1/confidence/snapshots` | Returns calibration snapshots of the trust vector. | No |
| GET | `/v1/inventory` | Returns the in-process inventory ledger snapshot. | No |
| POST | `/v1/webhooks/scheduler` | For Cloud Scheduler: builds a restock plan from the in-memory ledger and logs it. | No |
| POST | `/v1/webhooks/tasks` | For Cloud Tasks: acknowledges `{ taskType }` (`enrich_inventory`, `send_spoilage_notification`) and logs the body. | No |

Route registrations live in `src/server.ts` and `src/api/webhooks.ts`; the WebSocket upgrade is matched in `src/server.ts` (`server.on("upgrade", ...)`). "Called by the iOS app" was determined by grepping `apps/ios` for each path: the confidence, inventory, webhooks, and healthz routes have no references in Swift — they are exercised by the backend's own test suite and automation instead.

Input validation is per-route and minimal (array/type checks before the Gemini call); `/v1/confidence/outcome` performs none — a malformed body surfaces as a 500 rather than a 400.

### /v1/live protocol at a glance

Client → server envelopes are `{ type, payload? }` with exactly five types: `client_content` (text turns), `realtime_input` (realtime audio/video/image frames — image frames are also stored as session state, audio/video are not persisted), `tool_response`, `session_context` (patches stored session state; never forwarded to Gemini), and `close`. Server → client messages: `session_open {sessionId}`, `server_message` (model output after the response guard), `session_error`, `session_close`, `client_error`. Gemini tool calls are executed server-side — `get_recipe_context`, `assess_live_scene`, `ground_food_safety`, `mutate_inventory`, `get_restock_plan` — and their results reach the client only through later model text. The session id comes from the `?sessionId=` query param or is generated server-side; there is no ping, idle timeout, or session expiry.

### How the app points at this backend

The iOS app resolves `GEMINI_BACKEND_BASE_URL` from the process environment first, then from Info.plist (`GeminiCloudAgent.swift`, `Config.load()`; the same lookup is repeated in `NotificationSyncService.swift` and `LiveAssistantViewModel.swift`). `project.yml` sets that build setting to the deployed Cloud Run URL — currently `https://fridgeluck-gemini-agent-c6qrhws74q-uc.a.run.app` — which flows into `apps/ios/Support/AdditionalInfo.plist` as `$(GEMINI_BACKEND_BASE_URL)`. When no backend URL is configured, `GeminiCloudAgent` falls back to calling Gemini directly with a device-side `GEMINI_API_KEY`; the backend routes are used only when the URL is set. Keep `GEMINI_API_KEY` unset in the app when you want key handling to stay backend-only.

## Configuration

Everything the service reads is in `src/config.ts` (`loadConfig()`). Values are loaded with dotenv from `backend/gemini-agent/.env`; `.env.example` mirrors this table.

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | HTTP/WebSocket listen port. |
| `GOOGLE_GENAI_USE_VERTEXAI` | `false` | `true` selects Vertex AI mode (requires `GOOGLE_CLOUD_PROJECT` + `GOOGLE_CLOUD_LOCATION` + Application Default Credentials); `false` selects developer API mode (requires `GEMINI_API_KEY`). |
| `GOOGLE_CLOUD_PROJECT` | *(none)* | Google Cloud project id. Required in Vertex mode; also makes `LIVE_SESSION_STORE_MODE=auto` resolve to Firestore. |
| `GOOGLE_CLOUD_LOCATION` | `us-central1` | Vertex region; required in Vertex mode. |
| `GEMINI_API_KEY` | *(none)* | Gemini API key for developer API mode; required when Vertex mode is off. |
| `GEMINI_RECIPE_MODEL` | `gemini-2.5-flash` | Model used by `POST /v1/recipes/generate`. |
| `GEMINI_RANKING_MODEL` | `gemini-2.5-flash` | Model used by `POST /v1/reverse-scan/rank`. |
| `GEMINI_LIVE_MODEL` | `gemini-2.5-flash-native-audio-preview-12-2025` | Model bridged by `WS /v1/live`. Must be non-empty; deprecated Live model ids are rejected at startup. |
| `RESTOCK_THRESHOLD_DAYS` | `3` | Days before expiry that triggers a "use soon" alert in restock plans. |
| `IDEMPOTENCY_TTL_SECONDS` | `3600` | Seconds an inventory-mutation idempotency key stays remembered. |
| `RESTOCK_BELOW_GRAMS` | `50` | Grams below which an inventory item lands on the restock list. |
| `FIRESTORE_EMULATOR_HOST` | *(none)* | If set (e.g. `localhost:8080`), the Firestore SDK targets the emulator; also satisfies firestore-mode configuration without a real project. |
| `LIVE_SESSION_STORE_MODE` | `auto` | `memory`, `firestore`, or `auto` — `auto` picks Firestore when `GOOGLE_CLOUD_PROJECT` or `FIRESTORE_EMULATOR_HOST` is set, else memory. |
| `FIRESTORE_COLLECTION` | `liveSessions` | Firestore collection for live-session documents. |
| `GROUNDING_ENABLED` | `true` | Allows Google Search grounding for food-safety/freshness questions. |

Startup validation in `src/config.ts`:

- Exactly one Gemini mode must be satisfiable: Vertex mode requires `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION`; otherwise developer API mode requires `GEMINI_API_KEY`. If neither is satisfied the process fails at startup.
- `LIVE_SESSION_STORE_MODE=firestore` requires `GOOGLE_CLOUD_PROJECT` or `FIRESTORE_EMULATOR_HOST`.
- `GEMINI_LIVE_MODEL` must be non-empty; known-deprecated Live models are rejected.

## Run locally

Prerequisites: Bun 1.3.10 (the `packageManager` pin) and Node.js 20+ (`bun run dev` executes `tsx watch src/server.ts`, which runs under Node).

With keys, developer API mode:

```bash
cd backend/gemini-agent
bun install
cp .env.example .env    # then set GEMINI_API_KEY, keep GOOGLE_GENAI_USE_VERTEXAI=false
bun run dev
curl http://localhost:8080/healthz
```

`/healthz` never touches Gemini, so it responds even with an invalid key; the Gemini routes surface upstream/credential failures as HTTP 500s. Verified behavior on this tree: with no keys, `bun run dev` immediately prints `Error: Developer API mode requires GEMINI_API_KEY.` (from `src/config.ts`) before listening — but the `tsx watch` wrapper stays alive, so interrupt it with Ctrl-C. With any `GEMINI_API_KEY` value set, the server boots into memory session-store mode and `/healthz` returns 200.

With keys, Vertex mode: set `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_CLOUD_LOCATION` in `.env`, then `gcloud auth application-default login`. For Firestore-backed session state locally, keep `LIVE_SESSION_STORE_MODE=auto` with the project set, or point `FIRESTORE_EMULATOR_HOST` at a local Firestore emulator.

Without keys: the service cannot start. `loadConfig()` throws at startup — `Developer API mode requires GEMINI_API_KEY.` unless Vertex mode is fully configured (`src/config.ts`). There is no keyless mode; the Gemini-touching routes cannot work without one of the two modes.

## Tests & typecheck

```bash
bun install --frozen-lockfile
bun test src/__tests__   # 73 tests, all passing on main
bun run check            # tsc --noEmit
```

Run these with `GEMINI_API_KEY`, all `GOOGLE_*` variables, and `OPENAI_API_KEY` unset — the suite never reaches Gemini, OpenAI, Firestore, or any other network service. The Gemini client is faked and injected: services accept their collaborators as parameters, so tests construct fake clients and stores in-process instead of stubbing global network functions.

## Security posture

State of this service as of this writing. Read this before exposing it to anyone.

- **No authentication anywhere.** No middleware, API key, signature, or token check exists on any route — including `/v1/webhooks/*` — and the deployed revision is created with `--allow-unauthenticated` (`scripts/deploy-cloud-run.sh`). Anyone who has the URL can call every route and spend your Gemini quota.
- **All state is process-wide and shared by every caller.** One in-memory inventory ledger and idempotency map (`src/inventory/inventoryLedger.ts`), one in-memory confidence/trust-vector state (`src/services/confidenceService.ts`), and — in memory mode — one shared session map (`src/session/liveSessionStore.ts`) are single instances shared across all app installations. Nothing is namespaced per user or installation, and all of it resets on restart or redeploy.
- **Camera frames are persisted to Firestore.** Realtime image frames arriving on `/v1/live` are stored base64 in the live-session document (`latestCameraFrame`: `mimeType`, `dataBase64`, `updatedAt`) in the collection from `FIRESTORE_COLLECTION` (default `liveSessions`), together with the last user message and inventory-mutation audit entries (`src/session/liveSessionStore.ts`, `src/services/liveSessionGateway.ts`). In `auto` mode — the deployed configuration — Firestore is chosen whenever a project id is present. Photos posted to the two HTTP routes are forwarded to Gemini and are not persisted by this service.
- **A session id is the only isolation between callers.** `/v1/live` sessions are keyed solely by a client-chosen `?sessionId=` (generated if absent), and the upgrade path performs no authentication or origin check — anyone with the URL who knows or guesses a session id connects to that session, and its stored context (selected recipe, confirmed ingredients, latest camera frame) feeds the model.
- **Session state has no TTL or cleanup.** Neither store evicts: the memory map lives for the process lifetime, and Firestore session documents accumulate indefinitely (the service sets no Firestore TTL policy).
- **Also worth knowing:** JSON bodies up to 12 MB are accepted (`express.json` in `src/server.ts`), exception messages are returned raw in HTTP 500 responses, there is no rate limiting or CORS configuration, and `/healthz` publicly reports the model name, Vertex flag, and inventory count.

None of this is acceptable beyond a throwaway demo. Minimum hardening before real users: require authenticated Cloud Run invocations or front the service with an API gateway, namespace state per user, add rate limits, and trim what `/healthz` reports.

## Deploy (Cloud Run)

> ⚠️ **The deploy script creates a public, unauthenticated service.** `scripts/deploy-cloud-run.sh` passes `--allow-unauthenticated`, and the service adds no auth of its own, so the resulting URL is a public Gemini proxy billed to your Google Cloud project. Keep this to a disposable hackathon project; for anything real, deploy requiring IAM authentication or front it with an API gateway that checks a key.

Bootstrap Google Cloud resources once — APIs, Artifact Registry, Firestore, the runtime service account, and Vertex AI + Firestore IAM grants:

```bash
gcloud auth login
gcloud auth application-default login

cp .env.gcp.example .env.gcp   # set GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION, service names
./scripts/bootstrap-gcp.sh
```

Then deploy:

```bash
./scripts/deploy-cloud-run.sh
```

The deploy runs in Vertex AI mode with `LIVE_SESSION_STORE_MODE=firestore` (see `--set-env-vars` in the script), prints the service URL, and echoes the exact `GEMINI_BACKEND_BASE_URL` value to use in the iOS app. The URL currently baked into `project.yml` is the one this script produced.

Deployment assets live alongside this service: `Dockerfile`, `cloudbuild.yaml`, `scripts/bootstrap-gcp.sh`, `scripts/deploy-cloud-run.sh`. The hackathon submission proof checklist is in `PROOF_CHECKLIST.md`.
