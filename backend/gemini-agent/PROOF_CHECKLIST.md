# GCP Proof Checklist

Use this when recording hackathon proof for Gemini Live Agent Challenge submission.

- Show the Cloud Run service detail page with:
  - service name
  - region
  - HTTPS URL
  - latest revision
- Open Cloud Logging and filter for:
  - `live_session_open`
  - `tool_call: assess_live_scene`
  - `scheduler_restock_plan`
- Open Firestore and show the `liveSessions` collection with at least one active session document.
- Show the app or smoke flow using `/v1/live` and causing a tool call.
- Keep the clip separate from the demo video, as required by the challenge rules.
