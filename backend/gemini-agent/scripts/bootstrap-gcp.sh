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

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"
IMAGE_URI="${GOOGLE_CLOUD_LOCATION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${ARTIFACT_REGISTRY_REPO}/${SERVICE_NAME}:latest"

echo "==> Setting gcloud project to ${GOOGLE_CLOUD_PROJECT}"
gcloud config set project "${GOOGLE_CLOUD_PROJECT}" >/dev/null

echo "==> Enabling required Google Cloud APIs"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  aiplatform.googleapis.com \
  firestore.googleapis.com

echo "==> Ensuring Artifact Registry repository '${ARTIFACT_REGISTRY_REPO}' exists"
if ! gcloud artifacts repositories describe "${ARTIFACT_REGISTRY_REPO}" \
  --location "${GOOGLE_CLOUD_LOCATION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${ARTIFACT_REGISTRY_REPO}" \
    --repository-format docker \
    --location "${GOOGLE_CLOUD_LOCATION}" \
    --description "FridgeLuck container images"
fi

echo "==> Ensuring Firestore database exists"
if ! gcloud firestore databases describe --database="(default)" >/dev/null 2>&1; then
  gcloud firestore databases create \
    --database="(default)" \
    --location="${GOOGLE_CLOUD_LOCATION}" \
    --type=firestore-native
fi

echo "==> Ensuring service account '${SERVICE_ACCOUNT_NAME}' exists"
if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
    --display-name "FridgeLuck Gemini Agent"
fi

echo "==> Granting runtime IAM roles"
gcloud projects add-iam-policy-binding "${GOOGLE_CLOUD_PROJECT}" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/aiplatform.user" >/dev/null

gcloud projects add-iam-policy-binding "${GOOGLE_CLOUD_PROJECT}" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/datastore.user" >/dev/null

echo
echo "Bootstrap complete."
echo
echo "Resolved values:"
echo "  GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"
echo "  GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION}"
echo "  SERVICE_NAME=${SERVICE_NAME}"
echo "  SERVICE_ACCOUNT_EMAIL=${SERVICE_ACCOUNT_EMAIL}"
echo "  ARTIFACT_REGISTRY_REPO=${ARTIFACT_REGISTRY_REPO}"
echo "  IMAGE_URI=${IMAGE_URI}"
echo "  FIRESTORE_COLLECTION=${FIRESTORE_COLLECTION}"
echo "  GEMINI_LIVE_MODEL=${GEMINI_LIVE_MODEL}"
echo "  GEMINI_RECIPE_MODEL=${GEMINI_RECIPE_MODEL}"
echo "  GEMINI_RANKING_MODEL=${GEMINI_RANKING_MODEL}"
echo
echo "Next:"
echo "  1. gcloud auth login"
echo "  2. gcloud auth application-default login"
echo "  3. ${SCRIPT_DIR}/deploy-cloud-run.sh"
