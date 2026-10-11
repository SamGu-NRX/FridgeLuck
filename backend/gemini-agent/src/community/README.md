# Community module

Server-side community features for FridgeLuck: Sign in with Apple identity,
server-issued sessions, recipe sharing with human moderation, Explore, solo
challenges, private Tables, block enforcement, abuse reporting, and account
deletion. Owned by the spec `docs/spec/overhaul-20261011/` (sections 3.4, 6),
the review findings, and the cook-mode mock guide.

## Layout and ownership

```
src/community/
  index.ts            router factory; the ONLY file server.ts imports
  config.ts           module config parsed once at the boundary
  shared/             parts program against these, never past them
    ids.ts            branded ids + parsers
    errors.ts         err* constructors -> {code,message}
    http.ts           route(), community context, bearer parsing
    parse.ts          boundary validators (expectString/...)
    time.ts           Clock (system/test), toIso
    store.ts          Firestore bootstrap (emulator or prod, lazy)
    sessionCore.ts    SessionService (mint/verify/rotate/revoke)
    auth.ts           requireAccount middleware (the account boundary)
    contracts.ts      BlockDirectory / ModerationQueue / ScreeningStage seams
    testing/stubs.ts  fixture impls for single-part tests
  identity/           Apple identity + sessions routes      (part task)
  explore/            publish, revisions, screening, Explore (part task)
  challenges/         solo challenges                        (part task)
  tables/             private Tables                         (part task)
  safety/             blocks, reports, deletion              (part task)
  directions/         benchmarks/directions doc              (part task)
```

## Rules every part obeys

1. The account boundary is `requireAccount`. An account id in a request body
   is never trusted for authorization; at most it names a target to check.
2. No LLM decides moderation. Automated screening stages can only fail a
   publication into the queue; a human moderator approves or rejects through
   a server-held endpoint. Decisions are stored server-side only.
3. Blocks are mutual and enforced in every part's every read and write:
   `assertCanInteract` before writes, `filterVisible` before fan-outs.
4. No sensitive data in sharing surfaces: pantry, health, and taste data are
   never in a publication payload; counts (e.g. "cooked by N") only render
   above the config floors.
5. Parsers at the boundary; internal types stay branded. Firestore documents
   are read through validating parsers (`parseSessionDoc` pattern).
6. Tests inject `shared/testing/stubs.ts` for other parts' seams. The whole
   composition is proven only against the real wiring in suite E
   (community-emulator/), which runs against the Firestore emulator.

## Commands

```bash
bun install                                      # from backend/gemini-agent
bun run typecheck                                # tsc --noEmit
bash community-emulator/run-tests.sh             # suite incl. emulator scenarios
```

Emulator needs a JRE (Temurin works) and `firebase-tools` (already a dev
dependency). `FIRESTORE_EMULATOR_HOST` is set by the runner script.
