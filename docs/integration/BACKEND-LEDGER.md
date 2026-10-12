# Backend integration ledger — fleet/fl-backend-trunk-20261011

Backend integration trunk for programme fl-integration-f1, Part 2. Trunk
branched from `alpha` at `2e779381bb3939cf35f1948875bc657b7d6cb1ad` (verified
before the first fold; alpha had not moved). Draft PR: #94 ("Backend trunk
(do not merge as-is)").

Every fold is a real `git merge --no-ff` of the PR's own head (no squash, no
rebase, contributing branches untouched). Fold order was chosen so the two
server-restructuring PRs (#30 and #39) landed last, #39 after #30 (its
authority work builds on the HTTP app), with leaves first.

## Verification counts

| Point | Command (from `backend/gemini-agent`) | Result |
| --- | --- | --- |
| Before folds (alpha `2e77938`) | `bun install --frozen-lockfile && bun run check && bun test` | install ok (222 packages), typecheck 0 fail, **298 pass / 0 fail** across 20 files |
| After all folds + trunk reconciliation (this branch) | same | install ok (232 packages), typecheck 0 fail, **522 pass / 0 fail** across 33 files |

Note: the repo's typecheck equivalent is `bun run check` (`tsc -p
tsconfig.json --noEmit`); there is no `typecheck` script. #67's tests live in
`tools/offline/confidence-contract/tests/` and are picked up by the plain
`bun test` run (33 files) — no special command needed.

Mid-fold, after merging #30 onto the #24/#25/#21 contracts, 5 tests failed:
#30's `httpApp.test.ts` fixture predated the new service contracts (stale
model fake missing `ingredientsUsed` and the `rankings` array; stale
webhook-mounting test predating #25's fail-closed auth). These were
reconciled ON THE TRUNK (never on contributing branches) in the trunk
reconciliation commit; 0 failures remain.

## Per-PR verdicts

| PR | Head SHA | Verdict | Trunk merge | Reason |
| --- | --- | --- | --- | --- |
| #22 backend image Node 24 slim | `b2a6c650d0da01047b037573b2d083b0da866826` | **folded** | `003f9a4` | Sound: Node 24 LTS slim, non-root USER, prod-only install; `.dockerignore` tightened. |
| #19 numeric env fail-fast | `5c4159b4c2d207ec44460270a8fe4cf650c9d0cb` | **folded** | `5263666` | Sound: `loadConfig` rejects invalid numeric env vars with named fields at boot; tests concrete. |
| #21 reverse-scan ranking validation | `5c86759aa0f0a6f6e1dd6bfdbfb0dd386448fdb0` | **folded** | `a80bae9` | Sound: model rankings validated against requested candidates; out-of-range entries dropped, not clamped; hard failure on a missing rankings array. |
| #29 notification DST/payload integrity | `947dc8c58aebe5590e66a37783cfb5b15a7ae1e0` | **folded** | `7707f87` | Sound: local-calendar DST-safe scheduling; digest payload integrity tests. |
| #24 generateRecipe hardening | `b433aa958096a70684f3c7ce2c2abe346d528ec0` | **folded** | `368b92c` | Sound: untrusted JSON decoding, ingredient-policy screening, frozen `RecipeRejectedError` contract (`src/types/contracts.ts:139-162`). Trunk glue added: the HTTP layer now maps `RecipeRejectedError` → 422 with the frozen reason (see trunk commits). |
| #25 webhook OIDC | `dcffd6c22e01a33e0a9160e2f2794b8b0fe25da1` | **folded** | `50af6a2` | Sound: fail-closed 503 when unconfigured, 401 on invalid credentials, no raw tokens or bodies logged. |
| #26 retention | `6de7cd6d67bae801fd3be8b47a094e711e8bf941` | **folded** | `2280934` | Sound and verified on the trunk (SPEC 3.4): frame bytes confined to a bounded `TransientFrameCache` with a 2-minute TTL from trusted server receipt; metadata-only persistence; legacy persisted bytes deleted with `FieldValue.delete` on every merge write; 24h session expiry enforced on reads; tests cover both store modes. |
| #67 offline confidence contract | `257f7a40d64868cf7ce4ca8dd0d813c8790586ae` | **folded** | `7efadf3` | Sound: offline harness against the real `ConfidenceService` with an independent hand-derived oracle; no network, no secrets. |
| #30 testable HTTP app | `03b19343effa4e41e6bd18fb410e7e2ada2cc160` | **folded** | `a193953` | Sound: express app factory with bounded validation, safe error/log allowlists, per-IP rate limits on paid-model routes. Its test fixture was stale against #21/#24/#25 (see verification counts) — reconciled on the trunk. |
| #39 live-agent authority | `20dc133f4e6b9750921548549ac63b54b4570a7a` | **folded** | `a2370fa` | Sound: propose-then-confirm mutation authority (`src/authority/mutationAuthority.ts`), server-minted session ids, client `tool_response`/`latestConfidence` rejected, response guard, per-session ledgers. Also adds the `webhookOptions` verifier seam to `AppDeps` and the null-`ai` fail-safe (503 `model_unavailable`) in `src/http/app.ts`. |
| #16 backend+data CI (workflow) | `8a50a263c8ef6ee1e5a29040ff669f344925ed2c` | **folded with workflow hold** | `8017810` + hold commit | Workflow content is sound (read-only permissions, pinned actions, path-filtered), but the standing rule forbids pushing `.github/workflows/` changes. The merge was taken, then `.github/workflows/` was restored to the alpha base state in a follow-up commit ("Hold PR #16's workflow delta per Sam's standing rule"); the held workflow is staged at `ci/pending-workflows/backend-ci.yml` with first-line purpose/trigger comments. Sam approves before it lands in `.github/workflows/`. |

Checked by diff and left OUT of this ledger (substance not under backend/):
#40 and #50 (scripts/data pipeline) and #43 (scripts/recipe_scraper) — owned by
other trunks' ledgers.

Rejected: none. No folded PR required a partial take. No folded PR brought
secrets into code, weakened a check, or pinned a bug in its tests.

## Trunk reconciliation and additions (this branch's own commits)

1. **`RecipeRejectedError` → 422 glue** (`src/http/app.ts`): #24's typed
   rejection now maps to 422 with the frozen `RecipeRejectionReason` as the
   body's `error` code. Without this, policy rejections surfaced as generic
   500s. Wire test in `src/__tests__/httpApp.test.ts` › "recipe policy
   rejections map to the frozen 422 contract".
2. **`httpApp.test.ts` reconciliation**: model fake now serves both route
   contracts (#24's decoder/policy shape and #21's rankings shape);
   webhook-mounting tests rewritten to the fail-closed OIDC contract
   (503 unconfigured / 200 permissive verifier / 401 refusing verifier) using
   #39's `webhookOptions` seam; stale "clamps" test renamed (post-#21 the
   service drops out-of-range entries, it does not clamp).
3. **`src/__tests__/retentionSpec.test.ts`** — SPEC 3.4 verification on the
   trunk (both store modes): no frame bytes in any persisted document; frame
   bytes expire at the 2-minute TTL boundary; `lastUserMessage` does not
   survive the 24h session TTL; composition expiry; legacy frame-byte purge.
   SPEC 3.4 last bullet (binding): "LeChef's backend keeps no camera frames
   and no transcript beyond the live session unless the user explicitly saves
   a note. The current Firestore persistence of frames and text
   (backend/gemini-agent/src/session/liveSessionStore.ts:242-290) is removed
   or put behind a TTL by the backend trunk task." — satisfied: frame bytes
   are transient-only (2-minute TTL, metadata-only persistence, legacy bytes
   purged) and transcript content expires with the 24h session TTL. The
   "explicitly saves a note" carve-out is a phone-side feature; the backend
   has no note store, so there is nothing to exempt.
4. **`src/__tests__/authorityBoundaries.test.ts`** — boundary refusals with
   specific asserted errors (self-approval dropped, field-specific
   `MutationProposalError`, `unknown_proposal`/`already_resolved`, TTL
   expiry, idempotent proposal dedupe).
5. **`backend/gemini-agent/docs/AUTHORITY.md`** — the live-agent threat model
   with a boundary → proof map (READ / CHANGE / NEVER-DO), informed by #39 as
   merged and SPEC section 4.
6. **Fail-safe 503 test** for the null-`ai` boot at the HTTP layer (backs an
   AUTHORITY.md row).

Observation (no defect, safe direction): `MutationProposalStore` maps an
expired-but-unconfirmed proposal to `unknown_proposal` (swept before resolve);
the `ProposalRejectionReason` union's `"expired"` member is currently
unreachable from the store. Both outcomes refuse, so the boundary holds; a
future change could return `"expired"` for a sharper client message.

## Scope hygiene

- `backend/gemini-agent/src/lechef/` and `src/community/` were NOT touched by
  any fold or trunk commit; no fold dragged changes into them. Wiring them
  into `server.ts` is a later task.
- `apps/ios/` untouched. `.github/workflows/` left at the alpha base state
  (the #16 delta is held, not pushed).
