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
  foodSafety/         mandatory publish gate: rulebook lint +
                      compound-allergen tags (fail closed)
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
3. The mandatory food-safety gate (`foodSafety/`) stands between a signed
   publication and visibility: the canonical-rulebook lint and the
   ingredient-facts compound-allergen tags run before anything leaves the
   author's private view (SPEC 3.1/3.5). While the rulebook or
   ingredient-facts package is absent, empty, or unparsable the gate is
   CLOSED: publishing returns a 503 `unavailable` envelope and nothing is
   persisted. The packages load from `data/food-safety/canon.json` and
   `data/food-safety/ingredient-facts.json` (override per path with
   `FOOD_SAFETY_CANON_PATH` / `FOOD_SAFETY_FACTS_PATH`, or point
   `FOOD_SAFETY_DATA_ROOT` at a repo root); the JSON contracts are defined
   in `foodSafety/catalog.ts` and pinned by fixtures in
   `src/__tests__/community/fixtures/`.
4. Blocks are mutual and enforced in every part's every read and write:
   `assertCanInteract` before writes, `filterVisible` before fan-outs.
5. No sensitive data in sharing surfaces: pantry, health, and taste data are
   never in a publication payload; counts (e.g. "cooked by N") only render
   above the config floors.
6. Parsers at the boundary; internal types stay branded. Firestore documents
   are read through validating parsers (`parseSessionDoc` pattern).
7. Tests inject `shared/testing/stubs.ts` for other parts' seams. The whole
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
