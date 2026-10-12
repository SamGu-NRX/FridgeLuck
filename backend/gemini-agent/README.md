# Gemini Agent Backend (TypeScript)

Reusable Google Cloud-first backend for FridgeLuck Gemini features:

- `POST /v1/recipes/generate` (multimodal recipe generation)
- `POST /v1/reverse-scan/rank` (reverse-scan ranking)
- `POST /v1/confidence/assess` and `POST /v1/confidence/outcome` (Bayesian trust-vector confidence)
- `WS /v1/live` (Gemini Live websocket bridge)

## 1) Install

```bash
cd backend/gemini-agent
node --version # Node 20+ required by @google/genai
bun install
cp .env.example .env
```

## 2) Google Cloud bootstrap

If you want the backend on Cloud Run with Vertex AI and Firestore, first create
the deployment config file:

```bash
cp .env.gcp.example .env.gcp
```

Then edit `.env.gcp` and set only the values you actually need to know up front:

```dotenv
GOOGLE_CLOUD_PROJECT=your-project-id
GOOGLE_CLOUD_LOCATION=us-central1
SERVICE_NAME=fridgeluck-gemini-agent
ARTIFACT_REGISTRY_REPO=fridgeluck
SERVICE_ACCOUNT_NAME=fridgeluck-gemini-agent
```

Everything else in `.env.gcp` already has sensible defaults for this repo.

Authenticate locally:

```bash
gcloud auth login
gcloud auth application-default login
```

Create the required Google Cloud resources:

```bash
./scripts/bootstrap-gcp.sh
```

That script enables APIs, ensures Artifact Registry exists, ensures Firestore
exists, creates the runtime service account, grants Vertex AI + Firestore access,
and prints the exact resolved values it used.

## 3) Configure `.env`

### Vertex AI mode (recommended)

Edit `.env` to keep:

```dotenv
GOOGLE_GENAI_USE_VERTEXAI=true
GOOGLE_CLOUD_PROJECT=your-project-id
GOOGLE_CLOUD_LOCATION=us-central1
LIVE_SESSION_STORE_MODE=firestore
FIRESTORE_COLLECTION=liveSessions
```

Then authenticate locally:

```bash
gcloud auth application-default login
```

### Developer API mode

Edit `.env` to use:

```dotenv
GOOGLE_GENAI_USE_VERTEXAI=false
GEMINI_API_KEY=your-key
```

## 4) Run

```bash
bun run dev
```

Health check:

```bash
curl http://localhost:8080/healthz
```

## 5) Deploy to Cloud Run

After bootstrap:

```bash
./scripts/deploy-cloud-run.sh
```

The deploy script prints the final Cloud Run URL and the exact
`GEMINI_BACKEND_BASE_URL` value to use in the iOS app.

## 6) Swift app integration

Set one of these in your iOS app runtime environment or Info.plist:

- `GEMINI_BACKEND_BASE_URL` = `http://localhost:8080` (simulator)
- keep `GEMINI_API_KEY` unset in client for backend-only key handling

For Cloud Run, set:

- `GEMINI_BACKEND_BASE_URL` = your deployed Cloud Run HTTPS URL

## 7) Notes

- Live bridge accepts text turns, realtime audio/image input, and `session_context` patches from the client.
- Firestore-backed live session state is the intended Cloud Run path. `LIVE_SESSION_STORE_MODE=auto` falls back to memory for local-only development.
- Food-safety and freshness grounding are limited to Google Search backed questions; recipe, macro, and inventory truth remain FridgeLuck-context grounded.

### Live session authority model (`/v1/live`)

The client is an observer and confirmer, never a writer:

- **Session ids are server-minted.** A `sessionId` in the upgrade URL is logged as ignored; there is no attach-to-existing-session path. Over-limit connections (more than `MAX_LIVE_SESSIONS`) are closed with code 1013, as are connections when no model client is configured (`session_error` `model_unavailable` first). Sessions end at `MAX_SESSION_SECONDS` with `session_close` reason `session_expired` (close 1000).
- **Inventory mutations are propose-then-confirm.** The model calls `propose_inventory_mutation` (validated, bounded); the client then sends `confirm_mutation` with the proposal id to execute it (exactly once — the proposal id is the idempotency key) or `cancel_mutation` to withdraw it. Pending proposals expire after `MUTATION_PROPOSAL_TTL_SECONDS` (`unknown_proposal`). The phone's own ledger stays authoritative; the backend keeps a per-session shadow inventory (`inventory/sessionLedgers.ts`).
- **Client-sent authority frames are rejected.** `tool_response` envelopes get `client_error` (tools execute server-side only), and `latestConfidence` in `session_context` is rejected with `latestConfidence_not_accepted` — the exact-mode confidence gate is computed server-side.
- **Bounded input.** Each connection may send at most `LIVE_CLIENT_MESSAGES_PER_MINUTE` messages; the budget refills on a fixed 60-second timer. Over-budget messages get `client_error` `message_budget_exceeded` and are not forwarded upstream.
- **Fail-closed responses.** If the server-side response guard cannot read session state, the upstream model message is withheld and replaced with `session_error` `response_guard_failed`.

### Credential handling

- `GEMINI_API_KEY` (Developer API mode) is a secret: it lives only in `.env` locally (git-ignored) and in Cloud Run secret bindings in production. Never commit it; rotate it in Secret Manager if exposed.
- Vertex AI mode holds no API key at all — the runtime service account's Application Default Credentials authenticate to Vertex AI and Firestore (granted by `scripts/bootstrap-gcp.sh`).
- `WEBHOOK_OIDC_AUDIENCE` and `WEBHOOK_ALLOWED_EMAILS` are configuration, not secrets; webhook routes fail closed (503) when they are missing or invalid.
- The iOS app needs no AI credential for backend flows: it sets only `GEMINI_BACKEND_BASE_URL` (a public URL) and keeps `GEMINI_API_KEY` unset so the key is handled backend-side only.

## 8) Cloud Run deployment proof

- Cloud Run deployment assets live alongside this service (`Dockerfile`, `cloudbuild.yaml`, `scripts/deploy-cloud-run.sh`).
- Submission proof should capture:
  - Cloud Run service URL and latest revision
  - structured logs for `live_session_open`, tool calls, and scheduler/task webhooks
  - Firestore `liveSessions` collection showing active session documents
  - websocket `/v1/live` usage in app or smoke-test flow
