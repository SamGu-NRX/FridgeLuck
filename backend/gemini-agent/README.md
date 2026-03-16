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

## 8) Cloud Run deployment proof

- Cloud Run deployment assets live alongside this service (`Dockerfile`, `cloudbuild.yaml`, `scripts/deploy-cloud-run.sh`).
- Submission proof should capture:
  - Cloud Run service URL and latest revision
  - structured logs for `live_session_open`, tool calls, and scheduler/task webhooks
  - Firestore `liveSessions` collection showing active session documents
  - websocket `/v1/live` usage in app or smoke-test flow
