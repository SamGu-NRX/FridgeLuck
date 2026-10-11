# Live agent authority — what LeChef's backend model may read and change

Threat-model note for the live agent (`src/gemini-agent`), written on the backend
trunk (`fleet/fl-backend-trunk-20261011`) after folding PRs #19, #21, #22, #24,
#25, #26, #29, #30, #39, #67. It reflects the authority boundaries as merged in
#39 (`src/authority/mutationAuthority.ts`, `src/agent/toolRegistry.ts`,
`src/services/liveSessionGateway.ts`) and SPEC section 4's model: **the backend
reads bounded snapshots and proposes typed actions; the phone authorizes,
executes, and returns receipts; the model cannot manufacture approval; a voice
transcript alone never authorizes a meal log or a share.**

This file is the base for LeChef's tool surface. Every boundary row cites the
test that proves it; each refusing test asserts a specific, machine-checkable
error, never a generic failure.

## Trust boundaries

| Actor | Trust level |
| --- | --- |
| The user, physically present, tapping a confirm button in the iOS app | Fully trusted for their own data; the only source of approvals |
| The iOS client (WebSocket connection) | Trusted to relay user input and confirmations for the session it authenticated; NOT trusted to mint session ids, inject tool results, or set model confidence |
| The backend session gateway (`liveSessionGateway.ts`) | Trusted mediator: owns session state, mints ids, filters model output through a response guard |
| The model (Gemini, over the live socket) | UNTRUSTED. It may propose; it may never approve, execute, or read outside its bounded context |
| Any unauthenticated HTTP caller | Untrusted. Paid-model routes rate-limited; webhooks fail closed without OIDC (#25) |

## What the live agent may READ

1. **Bounded, server-owned session state only** — the snapshot the gateway
   assembles: selected recipe, confirmed ingredients, the last user message,
   and the current server-owned confidence assessment. It never sees other
   sessions, other users, the raw ledger of another device, or provider
   credentials beyond the runtime client handle.
2. **Camera frames, only transiently.** Raw frame bytes live in the bounded
   in-process `TransientFrameCache` for at most 2 minutes from trusted server
   receipt (`FRAME_TTL_MS`, `src/session/liveSessionStore.ts`); client
   timestamps cannot extend retention. Frame bytes are never persisted to
   Firestore — only minimal metadata is, and legacy persisted bytes are deleted
   on every merge write (PR #26).
3. **The transcript, only for the live session.** `lastUserMessage` is session
   state that expires with the 24h session TTL (`SESSION_TTL_MS`). Unless the
   user explicitly saves a note on the phone, nothing from the session
   survives it (SPEC 3.4; verified on the trunk by
   `src/__tests__/retentionSpec.test.ts`).
4. **No secrets.** Model/API credentials are injected at boot as the runtime
   client; request/response logging is allowlisted (`src/http/logger.ts`,
   #30), so prompts, photos, and provider messages never reach logs.

## What the live agent may CHANGE (on the user's behalf)

1. **Nothing directly.** The only mutation path is a typed proposal created
   through `validateProposalArgs` → `MutationProposalStore.create`:
   operation `add`|`decrement`, at most 25 items, each with a bounded
   `ingredientName`/`quantityGrams` and optionally a validated `expiresAt` and
   `source` ∈ {scan, manual, restock}. Everything else is dropped.
2. **Execution happens only after the matching client confirm.** The gateway
   executes a proposal at most once, only on `confirm` from the session's own
   client connection, only while the proposal is pending (5-minute TTL). The
   phone authorizes and executes; the backend records the outcome.
   Proposals are memory-only by design — a process restart forgets them, which
   is the safe direction (an unconfirmed proposal is only a draft).
3. **Webhook-driven background tasks** (scheduler/job callbacks) authenticate
   via OIDC with fail-closed behavior: misconfiguration → 503, missing/invalid
   credentials → 401 (#25). Unauthenticated callers cannot trigger task work.

## What the live agent may NEVER do

1. **Manufacture approval.** Confirmation-shaped fields in model tool args
   (`confirmed`, `userApproved`, `executed`, receipts, self-chosen proposal
   ids) are dropped by `validateProposalArgs`; no argument the model can pass
   flips a proposal to executed. Execution requires a client `confirm` on the
   server-minted proposal id.
2. **Supply its own evidence.** Client-sent `tool_response` messages are
   rejected by the gateway (#39); tool results come only from server-executed
   tools. Client-pushed `latestConfidence` is refused; the confidence gate is
   server-owned (`ConfidenceService`).
3. **Persist frames or outlive the session.** No frame bytes are ever written
   to Firestore; no transcript survives the session TTL; nothing a proposal
   touches survives a restart before confirmation.
4. **Authorize from voice alone.** A voice transcript is user INPUT, never an
   approval. A meal log or a share may be executed only from an explicit
   client confirm of a typed proposal (SPEC 4). The backend has no
   "transcript said yes" path, and LeChef's tool surface must not add one.
5. **Escape its bounded output.** Model responses pass a response guard
   (`liveSessionGateway.ts`, #39): when the guard cannot run, the upstream
   message is withheld rather than delivered unguarded.

## Boundary → proof map

Every refusal below is asserted with its specific error in the cited test.

| Boundary | Refusal behavior | Proof (test) |
| --- | --- | --- |
| Model cannot self-approve | `validateProposalArgs` drops confirmation-shaped fields | `authorityBoundaries.test.ts` › "the model cannot approve its own mutation…" |
| Malformed proposal args | `MutationProposalError` naming the exact field (`operation`, `items`, `items[0].quantityGrams`, `items[0].source`, `items[0].expiresAt`), static message only | `authorityBoundaries.test.ts` › "refuses malformed proposal args with a specific field…" |
| Confirm/cancel of unknown, other-session, cancelled, or already-resolved proposals | `{ ok: false, reason: "unknown_proposal" \| "already_resolved" }` | `authorityBoundaries.test.ts` › "confirm is refused…", "executes at most once…"; `liveSessionGateway.test.ts` › "executes a mutation only after confirm, at most once; cancel never writes" |
| Unconfirmed proposals expire | Refused after the TTL (swept → `unknown_proposal`) | `authorityBoundaries.test.ts` › "an unconfirmed proposal dies at its TTL…" |
| Client forges tool results | Gateway rejects client `tool_response` messages (specific gateway error) | `liveSessionGateway.test.ts` › "never accepts a client tool_response" |
| Client sets model confidence | Gateway rejects client-pushed `latestConfidence`; gate stays server-owned | `liveSessionGateway.test.ts` › "rejects client-pushed latestConfidence…" |
| Client mints session identity | Server mints session ids, ignores client-supplied ones | `liveSessionGateway.test.ts` › "mints a server-side session id and ignores a client-supplied one" |
| Unguarded model output | Upstream message withheld when the response guard cannot run | `liveSessionGateway.test.ts` › "withholds the upstream message when the response guard cannot run" |
| No credentials → no paid routes | Paid-model routes answer 503 `model_unavailable` (fail-safe boot) | `liveSessionGateway.test.ts` › "fails safe without model credentials"; `httpApp.test.ts` (null-ai seam) |
| Unauthenticated webhooks | 503 when OIDC unconfigured, 401 on invalid credentials, 200 only with a valid verifier | `httpApp.test.ts` › "webhook mounting" block (fail-closed / permissive / refusing verifier) |
| Frames never persist | No frame bytes in any Firestore write; legacy bytes purged; TTL expiry in both store modes | `retentionSpec.test.ts` (whole file); `liveSessionStore.test.ts` › "persists frame metadata only…", "deletes the legacy frame field…" |
| Transcript does not outlive the session | `lastUserMessage` gone at the 24h TTL in both store modes | `retentionSpec.test.ts` › "the transcript does not survive the 24h session expiry…"; `liveSessionStore.test.ts` expiry tests |
| HTTP abuse and leakage | Bounded validation, safe error/log allowlist, per-IP rate limits on paid routes | `httpApp.test.ts`, `httpLogs.test.ts`, `httpUpgrade.test.ts` (#30) |
| Recipe policy violations | `RecipeRejectedError` maps to 422 with the frozen reason (`uses_avoided_ingredient` \| `uses_unlisted_ingredient`), never a 500 or a provider echo | `httpApp.test.ts` › "surfaces RecipeRejectedError as 422…"; `recipeService.test.ts` (#24) |

## Notes for LeChef's tool surface

- Tools propose; only the client confirms. New tools must add no argument that
  can carry approval.
- New client-visible errors must come from the frozen unions
  (`StableErrorCode`, `RecipeRejectionReason`, `ProposalRejectionReason`) or a
  gateway-refusal type — never from provider text.
- New persistence must name its retention: if it holds frames or transcript
  content, it needs a TTL and tests here, or it must not exist (SPEC 3.4).
