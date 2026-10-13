# Live session frame retention and expiry policy

Status: implemented in `backend/gemini-agent/src/session/liveSessionStore.ts`.
Owner for the operational steps below: Sam. This change ships no operational
commands being run and makes no cloud/account/storage changes.

## What changed and why

The live-session store previously persisted the most recent raw camera frame
(`latestCameraFrame`, full base64 JPEG bytes) inside the session document, and
session records had no expiry. That put kitchen camera photos into Firestore
storage indefinitely and made them readable from persisted state.

The new policy:

- **Raw frames are transient and in-process only.** Frame bytes live in a
  bounded `TransientFrameCache` inside the backend process and expire 2
  minutes after trusted server receipt. They are never written to Firestore
  and never restored from persisted data.
- **Both store implementations use the same bounded cache.** Memory mode and
  Firestore mode each hold at most 500 sessions' worth of frames (least
  recently used evicted first). Recording a frame counts as session activity.
- **Only frame metadata is persisted.** A new `latestCameraFrameMetadata`
  field (`mimeType`, `receivedAt`, `sizeBytes`) is written to the session
  record instead of bytes.
- **No client timestamp can extend retention.** Receipt time is taken from
  the store's own clock when the server records the frame; any
  client-provided timestamp is ignored for retention purposes.
- **Logical session expiry: 24 hours after last activity.** Every write
  refreshes `updatedAt` and `expireAt`. Application reads enforce expiry
  before returning state; `ensureSession` cannot renew or restore an expired
  record — an expired record reads as blank, and the next write on it starts
  a fresh session lifecycle (in place). Reads of missing or expired sessions
  write nothing.
- **Legacy persisted frames.** Old documents may still contain a
  `latestCameraFrame` field with photo bytes. That field is now ignored on
  every read. When an existing document is touched by a merge write, the
  field is removed with real field-deletion semantics
  (`FieldValue.delete()` carried in the merge payload — not merely omitted),
  and an expired-document reset rewrites the document in full. Documents that
  are never touched keep their legacy field.
- **Session contract.** Under the Lead025 contract each connection starts a
  fresh server-owned session; there is no resume feature or configuration,
  so resetting an expired record cannot interrupt a resumable session.
- The `LiveSessionStore` interface is unchanged: `toolRegistry` still reads
  `getSession(sessionId).latestCameraFrame` and the scene-assessment caller
  still receives frame bytes for fresh frames (from the transient cache).

## Policy durations (unmeasured)

These values are constants in `liveSessionStore.ts` enforced only by the
backend process clock. Nothing external measures them, renews them, or
alerts when they are violated; there is no monitoring, metrics, or alerting
around them. They are policy, not SLAs.

| Policy | Value | Constant | Enforcement |
|---|---|---|---|
| Frame retention | 2 minutes after trusted server receipt | `FRAME_TTL_MS` | Process clock at read/write time |
| Frame cache bound | 500 sessions per store instance | `FRAME_CACHE_MAX_SESSIONS` | LRU eviction on insert |
| Logical session expiry | 24 hours after last activity | `SESSION_TTL_MS` | Process clock on every read/write |

Caveats that follow from this being unmeasured and in-process:

- The transient cache is per backend instance. Frames recorded on one
  instance are not readable from another. The current gateway and tool
  dispatch share one process per connection, so this does not affect the
  scene-assessment path.
- If the process restarts, all transient frames are gone immediately (by
  design). Session records in Firestore survive; memory-mode sessions do
  not.
- Server clock skew or a wrong system clock would shift all three durations
  together; nothing detects that automatically.

## Firestore TTL deletion (asynchronous, not the access-control boundary)

Every session document now carries an `expireAt` field (a Firestore
`Timestamp`, `updatedAt + 24h`) so a TTL policy can delete whole expired
documents later. Two things to keep in mind:

- Firestore TTL deletion is asynchronous. Deleted documents can persist for
  some time after `expireAt` passes. It is a storage-hygiene mechanism.
- It is **not** the access-control boundary. Application reads enforce the
  24-hour logical expiry (and the 2-minute frame TTL) before returning any
  state; expired documents are unreadable through the store regardless of
  whether TTL has collected them yet.

### TTL policy command (for Sam — not executed as part of this change)

Run manually with the real values substituted. Explicit placeholders:

- `<GCP_PROJECT_ID>` — the Google Cloud project Firestore runs in
- `<FIRESTORE_DATABASE_ID>` — the Firestore database id (often `(default)`)
- `<COLLECTION_ID>` — the live-session collection (default in this repo's
  config: `liveSessions`, set by `FIRESTORE_COLLECTION`)

```bash
gcloud firestore fields ttls update expireAt \
  --project=<GCP_PROJECT_ID> \
  --database=<FIRESTORE_DATABASE_ID> \
  --collection=<COLLECTION_ID> \
  --enable-ttl
```

Check status afterwards with:

```bash
gcloud firestore fields describe expireAt \
  --project=<GCP_PROJECT_ID> \
  --database=<FIRESTORE_DATABASE_ID> \
  --collection=<COLLECTION_ID>
```

Enabling a TTL policy is a one-time field-level setting on the database; the
command above only configures it. No Cloud Function, scheduler, or other
infrastructure is required, and none is included here.

## Historical remediation (separate recommendation — not done by this change)

This change stops future frame persistence and cleans documents as they are
touched. It does **not** delete or rewrite untouched historical documents,
and no claim of historical deletion or remediation is made: documents that
are never written again may still contain kitchen camera photos in their
legacy `latestCameraFrame` field.

Recommended (owner: Sam, separate change/operation, not covered by this PR):

1. Decide whether historical photo bytes must be purged for privacy reasons.
2. If yes, run a one-off remediation script (or a short-lived scheduled job)
   that queries the collection for documents containing
   `latestCameraFrame` and updates each with
   `latestCameraFrame: FieldValue.delete()` — the same field-deletion
   semantics the store now uses on touch. Snapshot/backup the collection
   first if the data has any value.
3. Afterward, enable the TTL policy above so expired whole documents are
   deleted by Firestore.

Do not treat Firestore TTL deletion as remediation for historical frames: it
deletes whole expired documents only, asynchronously, and leaves live
documents untouched.

## Test coverage

`backend/gemini-agent/src/__tests__/liveSessionStore.test.ts` covers both
store implementations against a fake Firestore that honors merge/delete
semantics, with a controllable clock: no persisted frame bytes; legacy frame
data ignored on reads and deleted on touch via `FieldValue.delete()`;
reads of expired documents return blank state without writes; expired
records are never renewed or restored; TTL boundaries (frame at 2 minutes,
session at 24 hours, including the exact boundary); LRU eviction at the
500-session default bound; and the scene-assessment tool path reading a
current transient frame (and nothing after expiry).
