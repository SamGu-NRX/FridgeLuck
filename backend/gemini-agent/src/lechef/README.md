# LeChef shared tool layer (Part 1)

The typed tool layer LeChef runs on: bounded snapshot reads the phone hands
out, typed action proposals the phone approves and executes, and the offline
evaluation harness (fake provider + fake phone) that runs design x session
and emits raw RunRecords for the Python scorer.

The phone is authoritative. This layer **reads** bounded snapshots and
**proposes** typed actions — nothing here executes an action on its own, and
nothing here can express a camera safety verdict. See `types.ts` for the
ownership boundary and SPEC section 3/4 contracts.

## Wiring contract (for the later integration task)

`server.ts` (not edited by this part) calls one factory:

```ts
import { createLeChefRuntime } from "./lechef/index.js";

const runtime = createLeChefRuntime({
  clock: systemClock,               // or an injected clock in tests
  phone,                            // PhoneExecutor — the FLAssistantCore client
  catalog: () => recipes,           // RecipeCatalog — bounded recipe cards
  camera: myCameraDevice,           // optional; omit for sessions without camera
  foodSafetyRulebook: myRulebook,   // optional; defaults to the embedded FSIS table
  substitutionLoader: myLoader      // optional; defaults to "table absent" (alpha)
});
```

`runtime.dispatch({ id, name, args }, abort?)` runs one tool call and returns
`{ id, name, args, result, status: "ok" | "cancelled" | "duplicate" | "error", dupOf? }`.
It never throws — failures come back as `status: "error"` with a `result.error`
message, so a bad model call can never take down a session.

The `PhoneExecutor` the real client implements (same surface `FakePhone`
implements): `revision()`, `pantrySnapshot()`, `sessionSnapshot()`,
`submitProposal(proposal)`, `receiptFor(id)`. Tool names, argument names and
result shapes are pinned by `types.ts` / `reads.ts` / `proposals.ts` /
`foodSafety.ts` / `substitutions.ts`.

## Design contract and gating (parent-owned join infra)

The three competing designs (companion, planner, coach) are CONFIGURATION on
top of this layer, not forks of it. `designs/contract.ts` pins the
`LeChefDesign` shape — deny-list `toolPolicy`, unprompted-speech
`turnBudget`, typed `suggestionType` matchers, and the documented
`systemPrompt` for later native wiring. `run/designRunner.ts` owns the
mechanics: `gateScript` (pure) and `runDesignSession` (gate + replay).

Gating semantics, pinned so designs cannot drift:

- **Proactive** = an assistant turn that speaks without a preceding user
  turn in the SOURCE script. Suppressing a turn never re-labels later ones
  (the gate annotates `turn.proactive`; replay honors the annotation).
- **Turn budget** — at most `maxUnpromptedTurns` proactive assistant turns
  per session, with at least `minGapTurns` emitted turns (any role)
  between two.
- **Tool policy** — deny-list only; a denied call comes back as
  `status: "error"` with `{ error: "policy-denied", deniedBy, reason }` and
  never reaches the tool layer. Denials are recorded, not hidden.
- **Third-rejection silence** — after two user rejections of a suggestion
  type, further suggestions of that type are suppressed for the session
  (SPEC 4). Rejections accrue only to suggestions the design actually
  emitted.
- **Suppressed turns stay visible** — the scorer compares the record's
  turns against the source script; the RunRecord shape is unchanged.
- **User actions on suppressed turns** reattach to the next kept turn, or
  drop (reported) when none follows.

Design directories own their config (`designs/<id>/design.ts`), local
cores, DESIGN.md, and a `run.ts` that replays a sessions directory through
`runDesignSession`. They own nothing outside `designs/<id>/` and their own
tests.


## Say-so decisions (recorded, not hidden)

1. **Wire types mirror the FLAssistantCore fixtures, with two additive
   fields.** `ActionProposal` carries the fixture's seven fields (`id`, `tool`,
   `payload`, `payloadHash`, `snapshotRevision`, `createdAt`, `expiresAt`) plus
   `requiredApproval: "device-auto" | "explicit"` and `userInitiated: boolean`
   that the phone needs. `ActionReceipt` is exactly the fixture's five fields
   (note `proposalID`, capital ID). Field names and semantics are pinned by
   `packages/FridgeLuckCore/Fixtures/action-proposal.json` and
   `action-receipt.json` on `origin/overhaul/core-foundation`; tests assert a
   byte-identical round-trip of both fixture shapes.

2. **Timestamps: epoch seconds on the wire, ISO 8601 in the evaluation layer.**
   The fixture contract encodes dates as integer epoch seconds (e.g.
   `813412800`) — the wire types, proposal `createdAt`/`expiresAt`, receipt
   `recordedAt` and timer deadlines all use `EpochSeconds`. The RunRecord the
   harness emits and session scripts are evaluation-layer artefacts and use
   ISO 8601 strings. The two coexist by layer: nothing converts the wire shape
   itself, and `run/harness.ts` is the only place that formats epoch seconds
   into ISO strings (pure function `iso()`). The serializer writes what the
   fixture writes; the README of the fixtures describes ISO 8601 for human
   dates elsewhere in FLDomain — the round-trip test is the authority.

3. **payloadHash = sha256 over canonical JSON of the payload** — compact,
   recursively key-sorted, no whitespace (`wire.ts`). Canonical, not
   re-serialization-dependent: the same payload always hashes the same.

4. **FSIS table embedded, pending `data/food-safety`.** The doneness table
   (poultry 74C, ground meats 71C, whole cuts 63C + rest, fish 63C, eggs 71C
   or firm yolk, leftovers 74C) lives in `foodSafety.ts` as the reviewed
   source, with the source NAMED on every answer. A future
   `data/food-safety` rulebook supersedes it: pass a loader via
   `createLeChefRuntime({ foodSafetyRulebook })` (or
   `loadFoodSafetyRulebook(path)`), which takes precedence over the embedded
   table. Uncovered products return an explicit unknown — never a colour or
   time answer.

5. **Substitutions table absent on alpha.** `lookupSubstitution` returns an
   explicit unknown (table absent), labels any offered reasoning as
   beyond-table, and ALWAYS rechecks all eaters' restrictions including
   compound ingredients. When the corpus task lands `data/substitutions`,
   pass `loadSubstitutionTable(path)` — table rows then become authoritative.
   Every swap describes the difference; none promises no-change (SPEC 3.1).

6. **Camera looks cannot carry verdicts — structurally.** `CameraLookResult`
   has `safetyVerdict: null` and the observation type has no field a verdict
   could hide in; `requestCameraLook` hard-caps clips at 3 seconds and both
   camera modes route through the same device-mediated, proposal-gated path.
   A camera look never yields a safety verdict.

7. **Dedupe: by tool-call id first, then by (tool, payloadHash).** A repeated
   call id, or a second call with an identical payload, returns the original
   proposal (`status: "duplicate"`, `dupOf`) and never creates a second live
   proposal. Cancelled calls abort before submission — nothing reaches the
   phone. Reordered calls are safe: dispatch is per-call and stateless.

8. **Usage accounting.** Text tokens are ESTIMATED as `ceil(chars / 4)`
   (`estimateTokens`) — a documented approximation, not a tokenizer count;
   the scorer should treat token numbers as comparable between runs, not
   absolute. `audioSeconds` comes from script annotations, `framesSent` from
   camera events, `connectedSeconds` from session start to completion
   excluding killed intervals (ManualClock is deterministic).

9. **RunRecords are raw.** The harness never computes job success, safety
   verdicts or approval judgements — the Part 2 Python scorer owns those.

## Session script schema (pinned)

The harness loads session scripts authored under
`evaluation/suites/lechef/sessions` (JSON). Pinned shape (`fakeModel.ts`,
validated by `parseSessionScript` — malformed scripts fail loudly with a
list of issues):

```jsonc
{
  "sessionId": "plan-001",
  "job": "plan",                       // plan | substitute | coach | adapt | remember
  "cameraMode": "push-to-look",        // push-to-look | continuous
  "design": "A",
  "fixture": {                         // the scripted world (optional)
    "nowIso": "2026-01-01T00:00:00Z",  // deterministic clock start
    "pantry":   [ /* PantryLine[] */ ],
    "session":  { "recipeId": "...", "state": "cooking", "currentStepIndex": 1,
                  "eaters": [ { "name": "Sam", "restrictions": ["wheat"] } ] },
    "recipes":  [ /* RecipeContext[] */ ],
    "camera":   { "framesPerLook": 2, "clipSeconds": 2,
                  "observed": ["..."], "cannotAssess": ["..."] }
  },
  "turns": [
    { "i": 0, "role": "user", "text": "...", "audioSeconds": 2.5 },
    { "i": 1, "role": "assistant", "text": "...",
      "toolCalls": [ { "id": "c1", "name": "getRecipeCandidates",
                       "args": { "goal": "weeknight dinner" }, "userInitiated": false } ],
      "cancelled": ["c9"],            // cancelled calls never reach the phone
      "prompted": true }
  ],
  "userActions": [                     // scripted user/device actions between turns
    { "afterTurn": 1, "action": { "kind": "approve", "callId": "c2" } },
    { "afterTurn": 2, "action": { "kind": "advanceMinutes", "minutes": 12 } },
    { "afterTurn": 3, "action": { "kind": "kill" } },
    { "afterTurn": 4, "action": { "kind": "resume" } },
    { "afterTurn": 5, "action": { "kind": "offline" } },
    { "afterTurn": 6, "action": { "kind": "reconnect" } }
  ]
}
```

`approve`/`reject` target a call id that produced a proposal; referencing a
call that never did is a script error and the run fails loudly.

## Harness CLI

```sh
bun src/lechef/run/cli.ts --sessions=evaluation/suites/lechef/sessions --out=/tmp/runs --design=A --pretty
```

Emits one `RunRecord` per session as `<sessionId>.json` — the exact pinned
shape the Part 2 scorer consumes: `sessionId`, `job`, `cameraMode`, `design`,
`turns`, `toolCalls`, `proposals`, `receipts`, `timers`, `events`, `answers`,
`camera`, `usage`. RunRecord timestamps are ISO 8601; wire timestamps inside
`proposals[].payload`-adjacent hashes stay canonical wire semantics.

## File map

| File | Role |
| --- | --- |
| `types.ts` | Domain types: bounded snapshots, proposals, receipts, payloads |
| `wire.ts` | Canonical serialization/parsing of the two fixture shapes; payloadHash |
| `fit.ts` | Pantry-fit computation (complete bill, summed lines, no percentages, no double counting) |
| `allergens.ts` | All-eater, compound-aware restriction rechecks |
| `foodSafety.ts` | Sourced FSIS doneness checks; rulebook loader override |
| `substitutions.ts` | Table-absent explicit unknowns; beyond-table labelling; difference statements |
| `reads.ts` | getRecipeCandidates, getPantrySummary, getRecipeContext, getStepContext, requestCameraLook |
| `proposals.ts` | The six propose* tools; dedupe; abort-before-submit |
| `fakePhone.ts` | Phone-authoritative simulator: snapshots, approvals, receipts, timers, kill/offline |
| `fakeModel.ts` | Scripted provider: reordered/duplicated/cancelled calls |
| `runtime.ts` | `createLeChefRuntime` + `dispatch` |
| `run/harness.ts` | RunRecord assembly (raw only) |
| `run/clock.ts` | Deterministic ManualClock |
| `run/cli.ts` | The CLI entry point |

`src/lechef/designs/` is reserved for later parts — not part of this
deliverable.
