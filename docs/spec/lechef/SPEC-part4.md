## 8. The proposal / receipt contract

The backend never writes to the phone's truth. Gemini tool calls return **proposals**; the phone executes on approval and returns **receipts**. This section **adopts PR #102's pinned wire contract verbatim** (`src/lechef/wire.ts` at `overhaul/lechef-f1`) rather than inventing a parallel one, and extends it in the same pattern. Schemas: `contracts/proposal.schema.json`, `contracts/receipt.schema.json`, `contracts/cook-step.schema.json`, `contracts/plan.schema.json`, `contracts/substitution.schema.json`, `contracts/scaling-rules.schema.json`. Every schema has an example fixture validated by `contracts/check.py`.

### 8.1 Proposal envelope (`ActionProposalWire`, adopted)

```json
{
  "proposalID": "prop_01J9X7Q4K2",
  "createdAt": "2026-10-15T18:22:31.000Z",
  "expiresAt": "2026-10-15T18:27:31.000Z",
  "payloadHash": "sha256:3ec4…",
  "kind": "swap",
  "payload": { },
  "rationale": "You're out of sour cream; Greek yoghurt is in the plan's shopping list.",
  "requiredApproval": "explicit"
}
```

Rules (all verbatim-adapted from #102 unless noted):

- `payloadHash` = SHA-256 over compact canonical JSON of the payload; the receipt carries it back and an approval with a mismatching hash is rejected ("payload hash mismatch"). Round-trip must be byte-identical over the Swift fixtures.
- `expiresAt` = `createdAt` + 300 s (TTL), checked **at approval time**, not just at display: expiry there yields `expired`.
- Proposals are revision-bound: a proposal built at an older snapshot revision is rejected as "superseded" at approval.
- **Timestamps canonized**: wire and fixtures are ISO-8601 ms-precision; `EpochSeconds` (integer seconds) is used only for phone-owned deadline arithmetic (`ActiveTimer.deadline`).
- `requiredApproval` and `userInitiation` are **derived audit annotations, never model-controllable inputs** — the model cannot write a claim of consent; the phone derives approval policy itself (caution adopted from #102's review history).
- **Dedupe** is call-id → payloadHash → abort checks, in that order; identical pending proposals are idempotent no-ops, resubmitting a consumed proposal id yields a rejection receipt. Session-lifetime dedupe maps are in-memory and forget on restart — **the phone's persistent receipt log (`cook_receipt`) is the dedupe authority across restarts**, not the tool layer.

**Payload kinds.** The six registered in #102's registry: `timer_start` · `timer_adjust` · `step_advance` · `inventory_correction` · `meal_log` · `save_note`. This spec adds the three application kinds the suite names speculatively — `plan` · `swap` · `adaptation` — as the natural continuation of the same discriminated-union pattern (kind, revision-bound, explicit-approval), per the research recommendation. `suggest_recipe` is **not** a proposal: recipe candidates come from the `getRecipeCandidates` read tool and the model speaks them; camera look is a read tool, not a wire kind (`requestCameraLook`, device-mediated, ≤3 s clip). No kind authorizes a share or a publish — those are not proposable. The schema's `kind` enum is the enforcement.

### 8.2 Receipt (`ActionReceiptWire`, adopted)

```json
{
  "proposalID": "prop_01J9X7Q4K2",
  "payloadHash": "sha256:3ec4…",
  "snapshotRevision": 12,
  "state": "executed",
  "recordedAt": "2026-10-15T18:23:02.000Z",
  "allergenRecheck": { "verdict": "verified", "eaters": ["you", "Ada"] }
}
```

- `state` ∈ `executed` · `rejected` · `expired` · `cancelled` (#102's pinned states). `reason?` is an additive failure/detail string (e.g. `"already_resolved"`, `"superseded"`, `"payload hash mismatch"`, the blocked allergen path).
- **Apply at most once**: the proposalID is the idempotency key; a repeated confirm resolves `already_resolved` — never a second write.
- **Approval policy** (#102's `RequiredApproval`): `meal_log` is **always `explicit`** — voice alone never authorizes it; `device-auto` is possible only for timer proposals whose `userInitiation.eventId` cites a phone-recorded, unconsumed `DeviceEvent` at the current revision naming the same tool — one event initiates one action, then it is consumed. Everything else is explicit approval via `approve() → executeApproved()`; a voice transcript alone never authorizes a meal log or a share (PR #86 §4).
- `allergenRecheck` is LeChef's additive audit extension on swap/adaptation receipts (verdict from §6: `verified | plausible | unknown | unsupported` plus the eater set); it never gates the wire contract itself, which stays byte-compatible with #102.
- Receipts are written locally (`cook_receipt` audit) and sent to the gateway opportunistically; the backend summarizes them into the bounded snapshot it keeps for the session.

### 8.3 Tool registry (backend → model surface)

Adopted verbatim from #102's `runtime.ts` dispatch — 7 read tools returning `ReadToolResult<T>`, plus the 6 registered proposal tools and the 3 this spec adds:

| Tool | Kind | Returns | Notes |
| --- | --- | --- | --- |
| `getRecipeCandidates` | read | candidate recipes for the job goal | catalogue refs only |
| `getPantrySummary` | read | `PantrySnapshot` (five `PantryLineState` states, `useSoon`, expiry) | no frames, no transcript history |
| `getRecipeContext` | read | recipe context + `hasRecentCameraFrame: boolean` | model learns a frame exists, never sees one |
| `getStepContext` | read | current step, completed history, next-step short name | |
| `lookupSubstitution` | read | `SubstitutionAnswer` (reviewed table vs labelled beyond-table, `differenceNote`) | phone runs the §6 recheck before display |
| `checkFoodSafety` | read | `FoodSafetyAnswer` / `SourcedCheck` | checkable thermometer test + named source; **unknown on uncovered products** — canon loader is fail-closed, strictest-wins (`canon/food-safety/rules.json`, SHA256-gated; supersedes any embedded fsis-table evidence kind) |
| `requestCameraLook` | read (device-mediated, proposal-gated) | `CameraObservation`, `maxClipSeconds: 3` | **structurally incapable of a safety verdict**; `cameraLint` fails closed |
| `proposeTimerStart` · `proposeTimerAdjust` | proposal | `timer_start` / `timer_adjust` | device creates/adjusts; device-auto only via phone-recorded `DeviceEvent` |
| `proposeStepAdvance` | proposal | `step_advance` | explicit approval |
| `proposeInventoryCorrection` | proposal | `inventory_correction` | corrects a wrong line; never bulk-writes |
| `proposeMealLog` | proposal | `meal_log` | always `explicit` |
| `proposeSaveNote` | proposal | `save_note` | note text never leaves the phone; proposal carries only a "note saved" marker |
| `proposePlan` · `proposeSwap` · `proposeAdaptation` | proposal (spec-added) | `plan` / `swap` / `adaptation` | the phone runs §7 allocation / §6 recheck / §5 rules; the model may only shape constraints and candidates |

Unknown tool names return `{ error: 'unknown tool "…"' }` with status `"error"` (`ToolCallStatus = "ok" | "cancelled" | "duplicate" | "error"`; results carry `duplicateOf` when deduped). The three spec-added kinds are named exactly as the suite's corpus already names them, so no harness mismatch is introduced when the registry implements them.

### 8.4 Cook step shape (RECONCILE with the recipe spec)

`obv/burst5-fridgeluck-spec-recipes` did not exist when this spec was written (checked 2026-10-15 via `git ls-remote`). The recipe spec's bundle **v2 step shape** is adopted in principle; until it lands, LeChef defines the minimum in `contracts/cook-step.schema.json` and marks it **RECONCILE**:

```json
{
  "index": 3,
  "text": "Add the noodles and 3 tbsp water. Toss for 2 min until the sauce coats everything.",
  "timer": { "durationMinutes": 2, "label": "Noodles", "source": "parsed" },
  "safetyCheck": null,
  "quantities": [ { "text": "3 tbsp water", "ingredientId": null, "evidence": "household" } ],
  "equipment": ["wok"],
  "shortName": "Noodles in"
}
```

`timer.source` ∈ `parsed` (from step text) · `authored` (recipe author) · `none`. A step without a natural timer gets none — no fake timers (PR #86 §3.5). `safetyCheck` carries a checkable test when the recipe's safety data provides one (thermometer temperature + target, per PR #126's rulebook); the cook-mode renderer gives `safetyCheck` display priority over any `timer` suggestion. When the recipe spec's v2 lands, the fields are renamed/mapped there and LeChef's parser becomes an adapter over the bundle; the contracts here reconcile before the cook-integration slice ships.

---

## 9. Privacy

**Nothing about a cook outlives the cook.** The contract (PR #86 §3.4): the backend keeps no camera frames and no transcript beyond the live session; the only server-side persistence is the bounded snapshot the proposal tools read (§8.3), deleted at session end. Nothing is kept unless the user saves a note — and notes are saved **on the phone**; the backend never receives them.

**The exact `liveSessionStore.ts` change** — adopts PR #26's design and constants verbatim:

1. **Raw frames never reach Firestore.** The store's byte persistence of `latestCameraFrame` is deleted; `PersistedSessionState` omits `latestCameraFrame` entirely (PR #26's shape). Only frame metadata persists (`StoredCameraFrameMetadata`: mimeType, receivedAt, sizeBytes).
2. The gateway keeps the current frame in a **bounded in-process cache** — PR #26's `TransientFrameCache` constants: `FRAME_TTL_MS = 2 min` measured from trusted server receipt (client timestamps cannot extend retention), `FRAME_CACHE_MAX_SESSIONS = 500` with LRU eviction (`services/liveSessionGateway.ts` `recordLatestFrame` at 365 → the cache; `attachLiveSessionGateway` owns it). Cache is per backend instance and dies with the process — accepted by design.
3. `assess_live_scene` (`toolRegistry.ts:47–76`) receives the frame from the in-memory cache via `ToolDeps`, never from the store.
4. `get_recipe_context` returns `hasRecentCameraFrame: boolean` computed from the cache — the model learns a frame exists, never sees one through the store. Legacy session docs that already hold frame bytes are ignored on read and the field is deleted on the next merge write; historical remediation is owner-run (PR #26's `planning/live_session_frame_retention.md`).
5. **Session expiry, not just frame expiry.** The store gains `expireAt` = 24 h after last activity (`SESSION_TTL_MS`), refreshed on every write; reads enforce expiry (an expired record reads as blank), `ensureSession` cannot renew or restore expired records, and the gateway calls `deleteSession` on close. A session doc surviving beyond 24 h is a bug (assertion in tests). The Firestore TTL policy on `expireAt` (`gcloud firestore fields ttls update expireAt`) is owner-run and is *not* the access-control boundary — expiry enforcement in reads is.
6. The phone sends the **bounded snapshot** (`getPantrySummary`/`getStepContext`) once per session; the store's `confirmedIngredients` is trimmed to ids + coarse quantity text, never the pantry. Client authority is stripped at the protocol layer (PR #39): client `tool_response` frames are rejected, `latestConfidence` is rejected (the exact-mode confidence gate is computed server-side only), and session ids are minted server-side — a client-supplied session id is logged as ignored.

**On the phone**, everything lives in GRDB (`cook_*` tables, §11) and backs up with the user's device — that is the "unless the user saves a note" clause, kept local by default. Sharing stays a separate, previewed action (PR #86 §3.4).

---
