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

## 2) Configure `.env`

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

## 3) Run

```bash
bun run dev
```

Health check:

```bash
curl http://localhost:8080/healthz
```

## 4) Swift app integration

Set one of these in your iOS app runtime environment or Info.plist:

- `GEMINI_BACKEND_BASE_URL` = `http://localhost:8080` (simulator)
- keep `GEMINI_API_KEY` unset in client for backend-only key handling

## 5) Notes

- Live bridge accepts text turns, realtime audio/image input, and `session_context` patches from the client.
- Firestore-backed live session state is the intended Cloud Run path. `LIVE_SESSION_STORE_MODE=auto` falls back to memory for local-only development.
- Food-safety and freshness grounding are limited to Google Search backed questions; recipe, macro, and inventory truth remain FridgeLuck-context grounded.

## 6) Cloud Run deployment proof

- Cloud Run deployment assets live alongside this service (`Dockerfile`, `cloudbuild.yaml`, `scripts/deploy-cloud-run.sh`).
- Submission proof should capture:
  - Cloud Run service URL and latest revision
  - structured logs for `live_session_open`, tool calls, and scheduler/task webhooks
  - Firestore `liveSessions` collection showing active session documents
  - websocket `/v1/live` usage in app or smoke-test flow
