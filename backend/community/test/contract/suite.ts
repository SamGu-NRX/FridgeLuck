/**
 * The contract round-trip suite (SPEC §7.4): for every operation openapi.yaml
 * declares, drive the real app — the production module wiring over a swappable
 * store — with requests built from contracts/examples where they exist, and
 * validate the status code and body against the schema the contract declares
 * for that exact status, with Ajv's 2020-12 build. Every error envelope is
 * validated against error.schema.json as well.
 *
 * Two structural assertions ride along:
 *   - every declared operation has a served route, and every served route is
 *     either declared or in KNOWN_CONTRACT_GAPS (stale gap entries fail too);
 *   - coverage: every operation is exercised and every declared status is hit,
 *     except the explicit NOT_EXERCISABLE list (flagged in the PR body).
 *
 * The suite runs twice: once against the in-memory adapter (unit tier) and
 * once against the production Firestore adapter under the emulator
 * (test/integration/, `bun run test:integration`).
 *
 * Scenario state is sequential and deliberate: the publisher exhausts their
 * daily publish budget inside one test, so every later publisher action only
 * reads, lists, or withdraws documents created before that budget ran out.
 */

import { beforeAll, describe, expect, test } from "bun:test";
import { loadContractArtifacts, type OpenApiOperation } from "./contractArtifacts.js";
import { KNOWN_CONTRACT_GAPS, routeGapFor, statusGapFor } from "./knownGaps.js";
import {
  api,
  buildHarness,
  publishRevision,
  resolvedPublicationContent,
  signIn,
  type ContractHarness,
  type Session,
  type StoreSelection,
} from "./harness.js";
import { createChallengeDocument } from "../../src/modules/challenges/views.js";
import { exampleRequest } from "./requests.js";

const artifacts = loadContractArtifacts();

const ERROR_REF = "https://fridgeluck.dev/community/schemas/error.schema.json";
const TABLE_CARD_REF = "https://fridgeluck.dev/community/schemas/table-card.schema.json";

const BATTLE_NAME = "Chili week"; // entries open long enough to vote too early
const USE_IT_UP_NAME = "Leftover rice"; // entries close 30 min in; voting opens after

/** Declared statuses the server cannot produce; each is flagged in the PR body. */
const NOT_EXERCISABLE: ReadonlyMap<string, readonly number[]> = new Map([
  [
    "createTable",
    [
      409,
      // openapi.yaml declares 409 "Owner already owns a table (table_full)";
      // the server (and SPEC §5.1) enforce no one-table-per-owner cap, so the
      // status is unreachable. Changing behaviour is Sam's call, not the suite's.
    ],
  ],
]);

async function bodyOf(response: Response): Promise<unknown> {
  const text = await response.text();
  return text.length === 0 ? undefined : (JSON.parse(text) as unknown);
}

/** The machine-readable key: the envelope's reason when set, else its code. */
function errorReason(body: unknown): string | null {
  const error = (body as { error?: { code?: string; reason?: string | null } })?.error;
  if (error === undefined) {
    return null;
  }
  return error.reason ?? error.code ?? null;
}

/** Indexed access with a named failure (noUncheckedIndexedAccess is on). */
function at<T>(items: readonly T[], index: number, label: string): T {
  const value = items[index];
  if (value === undefined) {
    throw new Error(`missing fixture item: ${label}[${index}]`);
  }
  return value;
}

export function runContractSuite(label: string, store: StoreSelection, opts: { skipUnlessEmulator?: boolean } = {}): void {
  // The Firestore tier runs only under an emulator (test:integration sets
  // FIRESTORE_EMULATOR_HOST); without the guard, plain `bun test test/` would
  // try to reach real GCP credentials.
  const configured = !opts.skipUnlessEmulator || Boolean(process.env.FIRESTORE_EMULATOR_HOST);
  (configured ? describe : describe.skip)(`community contract round-trip (${label})`, () => {
    let harness: ContractHarness;

    const coverage = new Map<string, Set<number>>();
    const gapCoverage = new Set<string>();
    for (const op of artifacts.operations) {
      coverage.set(op.operationId, new Set());
    }

    // Cross-test fixture state (documented above; the suite is sequential).
    let suiteTableId: string;
    let publisherRev1: string;
    let publisherRev2: string;
    let mayaBattleEntryId: string;
    let mayaUseItUpEntryId: string;

    function operation(method: string, openapiPath: string): OpenApiOperation {
      const op = artifacts.operations.find((o) => o.method === method && o.path === openapiPath);
      if (op === undefined) {
        throw new Error(`openapi.yaml declares no ${method} ${openapiPath}`);
      }
      return op;
    }

    function validateErrorEnvelope(where: string, body: unknown): void {
      if (body !== null && typeof body === "object" && "error" in (body as Record<string, unknown>)) {
        const ok = artifacts.compile(ERROR_REF)(body);
        if (!ok) {
          throw new Error(`${where}: error envelope fails error.schema.json: ${artifacts.lastAjvErrors()}`);
        }
      }
    }

    /** A response to a declared operation: the status must be declared and its schema must hold. */
    function expectResponse(op: OpenApiOperation, response: Response, body: unknown): void {
      const declared = op.responses[String(response.status)];
      if (declared === undefined) {
        throw new Error(
          `${op.operationId}: status ${response.status} is not declared in openapi.yaml (declared: ${Object.keys(op.responses).join(", ")})`,
        );
      }
      if (declared === null) {
        expect(body, `${op.operationId} ${response.status} must have no body`).toBeUndefined();
      } else {
        const ok = artifacts.compile(declared)(body);
        if (!ok) {
          throw new Error(`${op.operationId} ${response.status}: body fails ${declared}: ${artifacts.lastAjvErrors()}`);
        }
      }
      validateErrorEnvelope(op.operationId, body);
      coverage.get(op.operationId)?.add(response.status);
    }

    /** A driven status the operation does not declare: must be an exact KNOWN_CONTRACT_GAPS entry. */
    function expectGapResponse(method: string, openapiPath: string, response: Response, body: unknown): void {
      const where = `${method} ${openapiPath} ${response.status}`;
      expect(operation(method, openapiPath).responses[String(response.status)], `${where} must be undeclared`).toBeUndefined();
      expect(statusGapFor(method, openapiPath, response.status), `${where} must be a listed gap`).toBeDefined();
      validateErrorEnvelope(where, body);
      gapCoverage.add(`${method} ${openapiPath} ${response.status}`);
    }

    beforeAll(async () => {
      harness = await buildHarness(store);
    });

    test("every declared operation has a served route, and every served route is declared or a listed gap", () => {
      const served = new Set(harness.app.routes.map((r) => `${r.method} ${r.pattern}`));
      const missingRoutes: string[] = [];
      for (const op of artifacts.operations) {
        if (!served.has(`${op.method} ${op.routePattern}`)) {
          missingRoutes.push(`${op.method} ${op.routePattern} (operationId ${op.operationId})`);
        }
      }
      expect(missingRoutes, "declared operations with no route").toEqual([]);

      const undeclared = [...served].filter((route) => !artifacts.operationByRoute.has(route));
      const unlisted = undeclared.filter((route) => {
        const space = route.indexOf(" ");
        return routeGapFor(route.slice(0, space), route.slice(space + 1)) === undefined;
      });
      expect(unlisted, "served routes openapi.yaml does not declare and KNOWN_CONTRACT_GAPS does not list").toEqual([]);

      const stale = KNOWN_CONTRACT_GAPS.flatMap((gap) =>
        gap.kind === "route" && !served.has(`${gap.method} ${gap.pattern}`) ? [`${gap.method} ${gap.pattern}`] : [],
      );
      expect(stale, "KNOWN_CONTRACT_GAPS route entries the server no longer serves — delete them").toEqual([]);
    });

    test("authApple signs in against the contract session schema", async () => {
      const op = operation("POST", "/auth/apple");
      const body = {
        ...exampleRequest("authApple"),
        identityToken: "stub-jwt-maya-sub",
        nonce: crypto.randomUUID(),
        attest18Plus: { birthYear: 1990 },
      };
      const response = await api(harness.app, "POST", "/auth/apple", { body });
      expectResponse(op, response, await bodyOf(response));
    });

    test("getMe returns the contract account view (200)", async () => {
      const session = await signIn(harness, "maya-sub");
      const op = operation("GET", "/me");
      const response = await api(harness.app, "GET", "/me", { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("updateMe renames and returns the contract account view (200)", async () => {
      const session = await signIn(harness, "maya-sub");
      const op = operation("PATCH", "/me");
      const response = await api(harness.app, "PATCH", "/me", { token: session.token, body: exampleRequest("updateMe") });
      expectResponse(op, response, await bodyOf(response));
    });

    test("createPublication publishes clean content (201), refuses a false rights declaration (422), and rate-limits the day's 21st publish (429)", async () => {
      const op = operation("POST", "/publications");
      const session = await signIn(harness, "publisher-sub");
      // rev1 is driven through expectResponse so the declared 201 lands in
      // coverage; rev2 feeds withdrawPublication.
      const first = await api(harness.app, "POST", "/publications", {
        token: session.token,
        body: {
          ...exampleRequest("createPublication"),
          operationId: crypto.randomUUID(),
          source: { source: "user", id: "ur_7Kq2m", revision: 1 },
          // The example's lines are not in the reviewed canon (queued since
          // #224); reader-view flows need a published record.
          content: resolvedPublicationContent,
        },
      });
      const firstBody = (await bodyOf(first)) as { publicationId: string };
      expectResponse(op, first, firstBody);
      publisherRev1 = firstBody.publicationId;
      publisherRev2 = ((await publishRevision(harness, session, { source: "user", id: "ur_7Kq2m", revision: 2 }, { content: resolvedPublicationContent })) as { publicationId: string })
        .publicationId;

      const refused = await api(harness.app, "POST", "/publications", {
        token: session.token,
        body: { ...exampleRequest("createPublication"), operationId: crypto.randomUUID(), declaration: { ownRights: false, noPersonalData: true } },
      });
      const refusedBody = await bodyOf(refused);
      expectResponse(op, refused, refusedBody);
      expect(errorReason(refusedBody)).toBe("declarations_missing");

      // Fill the daily publish budget (20/day): two 201s so far (the refused
      // 422 does not burn a slot — review finding 7), so revisions 3-20 take
      // the count to 20 and the next publish is the day's 21st.
      for (let revision = 3; revision <= 20; revision += 1) {
        await publishRevision(harness, session, { source: "user", id: `ur_fill${revision}`, revision: 1 }, { content: resolvedPublicationContent });
      }
      const limited = await api(harness.app, "POST", "/publications", {
        token: session.token,
        body: { ...exampleRequest("createPublication"), operationId: crypto.randomUUID() },
      });
      const limitedBody = await bodyOf(limited);
      expectResponse(op, limited, limitedBody);
      expect(errorReason(limitedBody)).toBe("rate_limited");
    });

    test("getPublication serves the reader view (200)", async () => {
      const session = await signIn(harness, "publisher-sub");
      const op = operation("GET", "/publications/{publicationId}");
      const response = await api(harness.app, "GET", `/publications/${publisherRev1}`, { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("listMyPublications returns the owner's list (200) and withdrawPublication withdraws (204)", async () => {
      const session = await signIn(harness, "publisher-sub");
      const listOp = operation("GET", "/publications/mine");
      const listResponse = await api(harness.app, "GET", "/publications/mine", { token: session.token });
      expectResponse(listOp, listResponse, await bodyOf(listResponse));

      const withdrawOp = operation("DELETE", "/publications/{publicationId}");
      const withdrawResponse = await api(harness.app, "DELETE", `/publications/${publisherRev2}`, { token: session.token });
      expectResponse(withdrawOp, withdrawResponse, await bodyOf(withdrawResponse));
    });

    test("getExploreFeed returns the public feed (200)", async () => {
      const session = await signIn(harness, "maya-sub");
      const op = operation("GET", "/explore/feed");
      const response = await api(harness.app, "GET", "/explore/feed", { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("getCookCounts returns the cook calendar (200)", async () => {
      const session = await signIn(harness, "maya-sub");
      const op = operation("GET", "/explore/cook-counts");
      const response = await api(harness.app, "GET", "/explore/cook-counts", { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("listChallenges lists seeded challenges (200) and getChallenge returns the detail (200)", async () => {
      const base = harness.clock.now();
      await createChallengeDocument(harness.app.store, {
        type: "battle",
        name: BATTLE_NAME,
        brief: "Best chili wins.",
        opensAt: base.toISOString(),
        entryClosesAt: new Date(base.getTime() + 48 * 3600e3).toISOString(),
        votingClosesAt: new Date(base.getTime() + 96 * 3600e3).toISOString(),
        resolvedItems: null,
        packId: null,
      });
      await createChallengeDocument(harness.app.store, {
        type: "use-it-up",
        name: USE_IT_UP_NAME,
        brief: "Use yesterday's rice.",
        opensAt: new Date(base.getTime() - 48 * 3600e3).toISOString(),
        entryClosesAt: new Date(base.getTime() + 0.5 * 3600e3).toISOString(),
        votingClosesAt: new Date(base.getTime() + 48 * 3600e3).toISOString(),
        resolvedItems: [{ fdcId: 204445, name: "rice", quantityText: "2 cups" }],
        packId: null,
      });
      const session = await signIn(harness, "maya-sub");
      const listOp = operation("GET", "/challenges");
      const listResponse = await api(harness.app, "GET", "/challenges", { token: session.token });
      const listBody = (await bodyOf(listResponse)) as { challenges: { challengeId: string; name: string }[] };
      expectResponse(listOp, listResponse, listBody);
      const battle = listBody.challenges.find((c) => c.name === BATTLE_NAME);
      expect(battle).toBeDefined();

      const detailOp = operation("GET", "/challenges/{challengeId}");
      const detailResponse = await api(harness.app, "GET", `/challenges/${battle?.challengeId}`, { token: session.token });
      expectResponse(detailOp, detailResponse, await bodyOf(detailResponse));
    });

    test("createEntry links a published revision (201), refuses a moved revision (409 recipe_revised_offline) and an unpublished recipe (409 quarantined_rights)", async () => {
      const op = operation("POST", "/challenges/{challengeId}/entries");
      const session = await signIn(harness, "publisher-sub");
      const listResponse = await api(harness.app, "GET", "/challenges", { token: session.token });
      const listBody = (await bodyOf(listResponse)) as { challenges: { challengeId: string; name: string }[] };
      const battle = listBody.challenges.find((c) => c.name === BATTLE_NAME);
      expect(battle).toBeDefined();

      // ur_fill3 is one of the publisher's fill publications: exactly one
      // revision, never revised or withdrawn, so the revision check passes.
      const created = await api(harness.app, "POST", `/challenges/${battle?.challengeId}/entries`, {
        token: session.token,
        body: { ...exampleRequest("createEntry"), operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_fill3", revision: 1 } },
      });
      expectResponse(op, created, await bodyOf(created));

      const revised = await api(harness.app, "POST", `/challenges/${battle?.challengeId}/entries`, {
        token: session.token,
        body: { ...exampleRequest("createEntry"), operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_fill3", revision: 99 } },
      });
      const revisedBody = await bodyOf(revised);
      expectResponse(op, revised, revisedBody);
      expect(errorReason(revisedBody)).toBe("recipe_revised_offline");

      const foreign = await signIn(harness, "entryless-sub");
      const quarantined = await api(harness.app, "POST", `/challenges/${battle?.challengeId}/entries`, {
        token: foreign.token,
        body: { ...exampleRequest("createEntry"), operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_fill3", revision: 1 } },
      });
      const quarantinedBody = await bodyOf(quarantined);
      expectResponse(op, quarantined, quarantinedBody);
      expect(errorReason(quarantinedBody)).toBe("quarantined_rights");
    });

    test("castVote records a vote (204), refuses voting before entries close (409 vote_too_early), rate-limits the day's 31st vote (429), and refuses accounts younger than 24 h (403 account_too_new — KNOWN_CONTRACT_GAPS)", async () => {
      const op = operation("PUT", "/challenges/{challengeId}/vote");

      // Setup: maya publishes her own revision and enters both challenges while
      // entries are open. Her entries are the vote targets below.
      const maya = await signIn(harness, "maya-sub");
      await publishRevision(harness, maya, { source: "user", id: "ur_maya_stirfry", revision: 1 }, { content: resolvedPublicationContent });
      const listResponse = await api(harness.app, "GET", "/challenges", { token: maya.token });
      const listBody = (await bodyOf(listResponse)) as { challenges: { challengeId: string; name: string }[] };
      const battle = listBody.challenges.find((c) => c.name === BATTLE_NAME);
      const useItUp = listBody.challenges.find((c) => c.name === USE_IT_UP_NAME);
      expect(battle).toBeDefined();
      expect(useItUp).toBeDefined();
      const enteredBattle = await api(harness.app, "POST", `/challenges/${battle?.challengeId}/entries`, {
        token: maya.token,
        body: { ...exampleRequest("createEntry"), operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_maya_stirfry", revision: 1 } },
      });
      expect(enteredBattle.status).toBe(201);
      mayaBattleEntryId = ((await bodyOf(enteredBattle)) as { entryId: string }).entryId;
      const enteredUseItUp = await api(harness.app, "POST", `/challenges/${useItUp?.challengeId}/entries`, {
        token: maya.token,
        body: { ...exampleRequest("createEntry"), operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_maya_stirfry", revision: 1 } },
      });
      expect(enteredUseItUp.status).toBe(201);
      mayaUseItUpEntryId = ((await bodyOf(enteredUseItUp)) as { entryId: string }).entryId;

      // The battle's entries are still open: voting is refused there. The
      // operator signs in fresh after the clock jump below (their earlier
      // token expires during the jump).
      harness.clock.advance(25);
      const tooYoung = await signIn(harness, "tooyoung-sub");
      const tooNew = await api(harness.app, "PUT", `/challenges/${useItUp?.challengeId}/vote`, {
        token: tooYoung.token,
        body: { ...exampleRequest("castVote"), entryId: mayaUseItUpEntryId },
      });
      const tooNewBody = await bodyOf(tooNew);
      expectGapResponse("PUT", "/challenges/{challengeId}/vote", tooNew, tooNewBody);
      expect(errorReason(tooNewBody)).toBe("account_too_new");

      const publisher = await signIn(harness, "publisher-sub");

      const counted = await api(harness.app, "PUT", `/challenges/${useItUp?.challengeId}/vote`, {
        token: publisher.token,
        body: { ...exampleRequest("castVote"), entryId: mayaUseItUpEntryId },
      });
      expectResponse(op, counted, await bodyOf(counted));
      // Moving the same vote 29 more times exhausts the 30/day budget; the
      // 31st is limited.
      for (let i = 0; i < 29; i += 1) {
        const moved = await api(harness.app, "PUT", `/challenges/${useItUp?.challengeId}/vote`, {
          token: publisher.token,
          body: { ...exampleRequest("castVote"), entryId: mayaUseItUpEntryId },
        });
        expect(moved.status, `vote move ${i + 2}`).toBe(204);
      }
      const limited = await api(harness.app, "PUT", `/challenges/${useItUp?.challengeId}/vote`, {
        token: publisher.token,
        body: { ...exampleRequest("castVote"), entryId: mayaUseItUpEntryId },
      });
      const limitedBody = await bodyOf(limited);
      expectResponse(op, limited, limitedBody);
      expect(errorReason(limitedBody)).toBe("rate_limited");

      // Take the vote back while voting is open (removeVote, 204 only).
      const removeOp = operation("DELETE", "/challenges/{challengeId}/vote");
      const removed = await api(harness.app, "DELETE", `/challenges/${useItUp?.challengeId}/vote`, { token: publisher.token });
      expectResponse(removeOp, removed, await bodyOf(removed));

      // A fresh token: the one minted before the 25 h jump has expired (the
      // contract's session TTL), which would surface as an unrelated 401.
      const freshOperator = await signIn(harness, "operator-identity-sub");
      const early = await api(harness.app, "PUT", `/challenges/${battle?.challengeId}/vote`, {
        token: freshOperator.token,
        body: { ...exampleRequest("castVote"), entryId: mayaBattleEntryId },
      });
      const earlyBody = await bodyOf(early);
      expectResponse(op, early, earlyBody);
      expect(errorReason(earlyBody)).toBe("vote_too_early");
    });

    test("tables: create (201), get (200), invite (201), join (202), approve (200), the 9th member is refused (409 table_full), revoke (204)", async () => {
      const owner = await signIn(harness, "owner-sub", { attestedBirthYear: 1990 });
      const createOp = operation("POST", "/tables");
      const created = await api(harness.app, "POST", "/tables", { token: owner.token, body: exampleRequest("createTable") });
      const createdBody = (await bodyOf(created)) as { tableId: string };
      expectResponse(createOp, created, createdBody);
      suiteTableId = createdBody.tableId;

      const getOp = operation("GET", "/tables/{tableId}");
      const got = await api(harness.app, "GET", `/tables/${suiteTableId}`, { token: owner.token });
      expectResponse(getOp, got, await bodyOf(got));

      // Eight invites minted up front so the 9th approval can be refused at the cap.
      const inviteOp = operation("POST", "/tables/{tableId}/invites");
      const codes: { inviteId: string; joinCode: string }[] = [];
      for (let i = 0; i < 8; i += 1) {
        const inviteResponse = await api(harness.app, "POST", `/tables/${suiteTableId}/invites`, { token: owner.token, body: {} });
        const inviteBody = (await bodyOf(inviteResponse)) as { inviteId: string; joinCode: string };
        expectResponse(inviteOp, inviteResponse, inviteBody);
        codes.push(inviteBody);
      }

      const joinOp = operation("POST", "/invites/{code}/join");
      const approveOp = operation("POST", "/tables/{tableId}/invites/{inviteId}/approve");
      const memberTokens: Session[] = [];
      for (let i = 0; i < 7; i += 1) {
        const member = await signIn(harness, `member-${i}-sub`, { attestedBirthYear: 1990 });
        memberTokens.push(member);
        const joined = await api(harness.app, "POST", `/invites/${at(codes, i, "invite").joinCode}/join`, { token: member.token, body: {} });
        expectResponse(joinOp, joined, await bodyOf(joined));
        const approved = await api(harness.app, "POST", `/tables/${suiteTableId}/invites/${at(codes, i, "invite").inviteId}/approve`, {
          token: owner.token,
          body: {},
        });
        expectResponse(approveOp, approved, await bodyOf(approved));
      }

      // The eighth member fills the table (owner + 7); approving their join hits 409.
      const eighth = await signIn(harness, "member-7-sub");
      await api(harness.app, "POST", `/invites/${at(codes, 7, "invite").joinCode}/join`, { token: eighth.token, body: {} });
      const full = await api(harness.app, "POST", `/tables/${suiteTableId}/invites/${at(codes, 7, "invite").inviteId}/approve`, { token: owner.token, body: {} });
      const fullBody = await bodyOf(full);
      expectResponse(approveOp, full, fullBody);
      expect(errorReason(fullBody)).toBe("table_full");

      const revokeOp = operation("DELETE", "/tables/{tableId}/invites/{inviteId}");
      const revoked = await api(harness.app, "DELETE", `/tables/${suiteTableId}/invites/${at(codes, 7, "invite").inviteId}`, { token: owner.token });
      expectResponse(revokeOp, revoked, await bodyOf(revoked));
    });

    test("tables: share a cook (201), read the card feed (200 — KNOWN_CONTRACT_GAPS route), delete the card (204)", async () => {
      const owner = await signIn(harness, "owner-sub");
      const member = await signIn(harness, "member-0-sub");

      const shareOp = operation("POST", "/tables/{tableId}/cards");
      // The author display name rides the session account: the server refuses a
      // client-supplied cook.authorDisplayName (422), so the example drops it.
      const { authorDisplayName: _omitted, ...shareCook } = exampleRequest("shareCookToTable").cook as Record<string, unknown>;
      const shared = await api(harness.app, "POST", `/tables/${suiteTableId}/cards`, {
        token: member.token,
        body: { ...exampleRequest("shareCookToTable"), operationId: crypto.randomUUID(), cook: shareCook },
      });
      const sharedBody = (await bodyOf(shared)) as { cardId: string };
      expectResponse(shareOp, shared, sharedBody);

      // KNOWN_CONTRACT_GAPS: the card feed is served but openapi.yaml does not
      // declare it yet; the response shape is pinned against table-card.schema.json.
      expect(routeGapFor("GET", "/tables/:tableId/cards")).toBeDefined();
      const feedResponse = await api(harness.app, "GET", `/tables/${suiteTableId}/cards`, { token: member.token });
      expect(feedResponse.status).toBe(200);
      const feedBody = (await bodyOf(feedResponse)) as { cards: unknown[] };
      expect(Object.keys(feedBody).sort()).toEqual(["cards"]);
      expect(feedBody.cards.length).toBeGreaterThan(0);
      for (const card of feedBody.cards) {
        const ok = artifacts.compile(TABLE_CARD_REF)(card);
        if (!ok) {
          throw new Error(`table card feed item fails ${TABLE_CARD_REF}: ${artifacts.lastAjvErrors()}`);
        }
      }
      gapCoverage.add("GET /tables/{tableId}/cards 200");

      const deleteOp = operation("DELETE", "/tables/{tableId}/cards/{cardId}");
      const deleted = await api(harness.app, "DELETE", `/tables/${suiteTableId}/cards/${sharedBody.cardId}`, { token: member.token });
      expectResponse(deleteOp, deleted, await bodyOf(deleted));
    });

    test("tables: remove a member (204), a member leaves (204), the owner cannot leave (409 — KNOWN_CONTRACT_GAPS), blocks (204/200/204)", async () => {
      const owner = await signIn(harness, "owner-sub");
      const memberTwo = await signIn(harness, "member-2-sub");
      const memberThree = await signIn(harness, "member-3-sub");
      const memberFour = await signIn(harness, "member-4-sub");

      const removeOp = operation("DELETE", "/tables/{tableId}/members/{accountId}");
      const removed = await api(harness.app, "DELETE", `/tables/${suiteTableId}/members/${memberTwo.accountId}`, { token: owner.token });
      expectResponse(removeOp, removed, await bodyOf(removed));

      const leaveOp = operation("POST", "/tables/{tableId}/leave");
      const left = await api(harness.app, "POST", `/tables/${suiteTableId}/leave`, { token: memberThree.token, body: {} });
      expectResponse(leaveOp, left, await bodyOf(left));

      const ownerLeave = await api(harness.app, "POST", `/tables/${suiteTableId}/leave`, { token: owner.token, body: {} });
      const ownerLeaveBody = await bodyOf(ownerLeave);
      expectGapResponse("POST", "/tables/{tableId}/leave", ownerLeave, ownerLeaveBody);
      expect(errorReason(ownerLeaveBody)).toBe("conflict"); // the envelope's code; no reason field

      const addBlockOp = operation("PUT", "/blocks/{accountId}");
      const blocked = await api(harness.app, "PUT", `/blocks/${memberFour.accountId}`, { token: memberThree.token });
      expectResponse(addBlockOp, blocked, await bodyOf(blocked));

      const listOp = operation("GET", "/blocks");
      const listed = await api(harness.app, "GET", "/blocks", { token: memberThree.token });
      expectResponse(listOp, listed, await bodyOf(listed));

      const removeBlockOp = operation("DELETE", "/blocks/{accountId}");
      const unblocked = await api(harness.app, "DELETE", `/blocks/${memberFour.accountId}`, { token: memberThree.token });
      expectResponse(removeBlockOp, unblocked, await bodyOf(unblocked));
    });

    test("moderation: reports (202, then 429), the operator queue (200), decisions (200) and non-operator refusals (403)", async () => {
      const reporter = await signIn(harness, "reporter-sub");
      const reportOp = operation("POST", "/reports");
      for (let i = 0; i < 10; i += 1) {
        const reported = await api(harness.app, "POST", "/reports", {
          token: reporter.token,
          body: { ...exampleRequest("createReport"), targetType: "tableCard", targetId: "crd_testtarget01" },
        });
        expectResponse(reportOp, reported, await bodyOf(reported));
      }
      const limited = await api(harness.app, "POST", "/reports", {
        token: reporter.token,
        body: { ...exampleRequest("createReport"), targetType: "tableCard", targetId: "crd_testtarget01" },
      });
      const limitedBody = await bodyOf(limited);
      expectResponse(reportOp, limited, limitedBody);
      expect(errorReason(limitedBody)).toBe("rate_limited");

      const operator = await signIn(harness, "operator-identity-sub");
      const queueOp = operation("GET", "/moderation/queue");
      const queue = await api(harness.app, "GET", "/moderation/queue", { token: operator.token });
      const queueBody = (await bodyOf(queue)) as { cases: { caseId: string; state: string }[] };
      expectResponse(queueOp, queue, queueBody);
      const queued = queueBody.cases.find((c) => c.state === "queued");
      expect(queued).toBeDefined();

      const decideOp = operation("POST", "/moderation/cases/{caseId}/decision");
      const civilian = await signIn(harness, "maya-sub");
      const refused = await api(harness.app, "POST", `/moderation/cases/${queued?.caseId}/decision`, {
        token: civilian.token,
        body: exampleRequest("decideCase"),
      });
      const refusedBody = await bodyOf(refused);
      expectResponse(decideOp, refused, refusedBody);
      expect(refused.status).toBe(403);

      const decided = await api(harness.app, "POST", `/moderation/cases/${queued?.caseId}/decision`, {
        token: operator.token,
        body: exampleRequest("decideCase"),
      });
      expectResponse(decideOp, decided, await bodyOf(decided));
    });

    test("createPublication returns 503 when the screening packages are not loaded", async () => {
      const degraded = await buildHarness(store, { screeningPackagesLoaded: false });
      const session = await signIn(degraded, "degraded-sub");
      const op = operation("POST", "/publications");
      const response = await api(degraded.app, "POST", "/publications", {
        token: session.token,
        body: { ...exampleRequest("createPublication"), operationId: crypto.randomUUID() },
      });
      const parsed = await bodyOf(response);
      expectResponse(op, response, parsed);
      expect(response.status).toBe(503);
    });

    test("authRefresh rotates the session (200)", async () => {
      const session = await signIn(harness, "refresh-sub");
      const op = operation("POST", "/auth/refresh");
      const response = await api(harness.app, "POST", "/auth/refresh", {
        body: { ...exampleRequest("authRefresh"), refreshToken: session.refreshToken },
      });
      expectResponse(op, response, await bodyOf(response));
    });

    test("revokeSession revokes the current session (204)", async () => {
      const session = await signIn(harness, "revoke-sub");
      const op = operation("DELETE", "/session");
      const response = await api(harness.app, "DELETE", "/session", { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("deleteAccount deletes the account (202)", async () => {
      const session = await signIn(harness, "doomed-sub");
      const op = operation("DELETE", "/account");
      const response = await api(harness.app, "DELETE", "/account", { token: session.token });
      expectResponse(op, response, await bodyOf(response));
    });

    test("coverage: every operation is exercised and every declared status is hit (except the flagged NOT_EXERCISABLE list)", () => {
      const holes: string[] = [];
      for (const op of artifacts.operations) {
        const covered = coverage.get(op.operationId);
        if (covered === undefined || covered.size === 0) {
          holes.push(`${op.operationId}: not exercised at all`);
          continue;
        }
        const missing = Object.keys(op.responses)
          .map(Number)
          .filter((status) => !covered.has(status) && !(NOT_EXERCISABLE.get(op.operationId) ?? []).includes(status));
        if (missing.length > 0) {
          holes.push(`${op.operationId}: declared statuses never driven: ${missing.join(", ")}`);
        }
      }
      expect(holes, "contract coverage holes").toEqual([]);
    });

    test("gap coverage: every KNOWN_CONTRACT_GAPS entry keeps its driving scenario", () => {
      const listed = KNOWN_CONTRACT_GAPS.filter((gap) => gap.kind === "status").map(
        (gap) => `${gap.method} ${gap.path} ${gap.status}`,
      );
      const missing = listed.filter((d) => !gapCoverage.has(d));
      expect(missing, "listed status gaps whose scenario stopped running").toEqual([]);
      expect(gapCoverage.size, "driven gaps are all listed").toBe(listed.length + 1); // + the card-feed route gap
    });
  });
}
