#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env.gcp}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT in .env.gcp or the shell.}"
: "${GOOGLE_CLOUD_LOCATION:=us-central1}"
: "${SERVICE_NAME:=fridgeluck-gemini-agent}"
: "${ARTIFACT_REGISTRY_REPO:=fridgeluck}"
: "${SERVICE_ACCOUNT_NAME:=fridgeluck-gemini-agent}"
: "${FIRESTORE_COLLECTION:=liveSessions}"
: "${GEMINI_LIVE_MODEL:=gemini-2.5-flash-native-audio-preview-12-2025}"
: "${GEMINI_RECIPE_MODEL:=gemini-2.5-flash}"
: "${GEMINI_RANKING_MODEL:=gemini-2.5-flash}"
: "${GROUNDING_ENABLED:=true}"
: "${PORT:=8080}"
: "${IMAGE_URI:=${GOOGLE_CLOUD_LOCATION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${ARTIFACT_REGISTRY_REPO}/${SERVICE_NAME}:latest}"

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"

gcloud builds submit --config cloudbuild.yaml --substitutions "_IMAGE=${IMAGE_URI}"

gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE_URI}" \
  --project "${GOOGLE_CLOUD_PROJECT}" \
  --region "${GOOGLE_CLOUD_LOCATION}" \
  --service-account "${SERVICE_ACCOUNT_EMAIL}" \
  --allow-unauthenticated \
  --port "${PORT}" \
  --timeout 900 \
  --set-env-vars "GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT},GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION},LIVE_SESSION_STORE_MODE=firestore,FIRESTORE_COLLECTION=${FIRESTORE_COLLECTION},GROUNDING_ENABLED=${GROUNDING_ENABLED},GEMINI_LIVE_MODEL=${GEMINI_LIVE_MODEL},GEMINI_RECIPE_MODEL=${GEMINI_RECIPE_MODEL},GEMINI_RANKING_MODEL=${GEMINI_RANKING_MODEL}"

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --project "${GOOGLE_CLOUD_PROJECT}" --region "${GOOGLE_CLOUD_LOCATION}" --format='value(status.url)')"

echo
echo "Deploy complete."
echo "  Cloud Run URL: ${SERVICE_URL}"
echo "  Health check: ${SERVICE_URL}/healthz"
echo
echo "Set this in the iOS app runtime environment or plist:"
echo "  GEMINI_BACKEND_BASE_URL=${SERVICE_URL}"
