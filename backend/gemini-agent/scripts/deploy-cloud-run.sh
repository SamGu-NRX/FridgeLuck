#!/usr/bin/env bash
set -euo pipefail

: "${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
: "${GOOGLE_CLOUD_LOCATION:=us-central1}"
: "${SERVICE_NAME:=fridgeluck-gemini-agent}"
: "${IMAGE_URI:=us-central1-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/fridgeluck/${SERVICE_NAME}:latest}"

gcloud builds submit --config cloudbuild.yaml --substitutions "_IMAGE=${IMAGE_URI}"

gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE_URI}" \
  --project "${GOOGLE_CLOUD_PROJECT}" \
  --region "${GOOGLE_CLOUD_LOCATION}" \
  --allow-unauthenticated \
  --set-env-vars "GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT},GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION},LIVE_SESSION_STORE_MODE=firestore,FIRESTORE_COLLECTION=liveSessions,GROUNDING_ENABLED=true"
