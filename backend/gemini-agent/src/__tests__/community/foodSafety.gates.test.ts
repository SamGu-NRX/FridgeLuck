/**
 * The mandatory food-safety publish gates (PR #104 review blocker 1; SPEC
 * 3.1/3.5 — "Rights, safety lint and allergen tagging apply to user recipes
 * exactly as to the catalog").
 *
 * Three arms, all proven over the real HTTP surface against the Firestore
 * emulator:
 *   (i)   publishing is REFUSED while the canon/ingredient-facts packages
 *         are not loaded — error envelope, nothing persisted, nothing
 *         enters moderation (fail closed);
 *   (ii)  publishing is blocked when the canonical-rulebook lint fails or
 *         an allergen claim is unsupported by the derived tags — the
 *         publication is enqueued for human review, never visible;
 *   (iii) a clean publication is allowed and its compound-allergen tags
 *         (soy sauce carries wheat) are persisted and returned in
 *         author, public, and feed responses.
 *
 * The loader's fail-closed variants (absent, empty, unparsable, off-schema
 * data) are pinned at unit level; the gate opens only on valid data.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { stubBlockDirectory, stubModerationQueue } from "../../community/shared/testing/stubs.js";
import { createFoodSafetyGate } from "../../community/foodSafety/gate.js";
import { FOOD_SAFETY_CANON_SCHEMA, INGREDIENT_FACTS_SCHEMA, loadFoodSafetyCatalog, resolveFoodSafetyCatalogPaths, sha256Hex, stableIngredientFactsString } from "../../community/foodSafety/catalog.js";
import { FOOD_SAFETY_FIXTURE_DIR, closedFoodSafetyGate, fixtureFoodSafetyGate } from "./foodSafetyGate.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let blocks: ReturnType<typeof stubBlockDirectory>;
let openUrl: string;
let closedUrl: string;
let emptyCanonUrl: string;
let servers: Server[] = [];
let nonceCounter = 0;

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

interface AppleClaims {
  sub: string;
  nonce: string;
}

function mintAppleToken(claims: AppleClaims): string {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
  const payload = b64url(JSON.stringify({ iss: APPLE_ISSUER, aud: SERVICES_ID, exp: now + 600, iat: now, ...claims }));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), privateKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

async function signInAs(url: string, sub: string): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `gate-nonce-${String(nonceCounter).padStart(4, "0")}`;
  const res = await fetch(`${url}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: mintAppleToken({ sub, nonce }), nonce, attested18Plus: true }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
}

function publishBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: { recipeId: "recipes/test-gate-rice", recipeRevision: "rev-000001" },
    recipe: {
      title: "Weeknight tomato rice",
      summary: "A simple tomato rice for two.",
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp tahini"],
      steps: ["Cook the rice.", "Fry the tomatoes, stir in the tahini, fold through the rice."],
    },
    tags: ["quick"],
    campus: "gate-test",
    note: null,
    declarations: { ownRights: true, noPersonalData: true, sourceRights: { textRedistribution: "permitted", attributionRequired: false } },
    ...overrides,
  };
}

async function publish(url: string, tokens: TokenPair, body: Record<string, unknown>): Promise<Response> {
  return fetch(`${url}/v1/community/publications`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${tokens.accessToken}` },
    body: JSON.stringify(body),
  });
}

interface PublicationJson {
  publicationId: string;
  status: string;
  allergenTags: readonly string[];
  screeningFailures: ReadonlyArray<{ stage: string; reasons: readonly string[] }>;
}

interface FeedJson {
  campus: string;
  items: ReadonlyArray<{ publicationId: string; title: string; allergenTags: readonly string[] }>;
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

function startApp(deps: CommunityDeps): Promise<string> {
  const app = express();
  app.use(express.json());
  app.use(createCommunityRouter(deps, { identity: createIdentityRoutes, explore: createExploreRoutes }));
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  return new Promise<string>((resolve) => {
    server.once("listening", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        throw new Error("test server did not bind");
      }
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

beforeAll(async () => {
  jwksServer = Bun.serve({
    port: 0,
    fetch: () => Response.json({ keys: [publicJwk] }),
  });
  harness = await makeHarness({
    appleIssuer: APPLE_ISSUER,
    appleServicesId: SERVICES_ID,
    appleJwksUrl: `http://127.0.0.1:${jwksServer.port}/auth/keys`,
  });
  blocks = stubBlockDirectory();
  const moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const base = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks,
    moderation,
  };
  // A gate that loaded valid data but with an EMPTY canon file — still closed.
  const emptyDir = mkdtempSync(join(tmpdir(), "fl-empty-canon-"));
  writeFileSync(join(emptyDir, "canon.json"), "", "utf8");
  const emptyCanonGate = createFoodSafetyGate({
    canonPath: join(emptyDir, "canon.json"),
    factsPath: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`,
  });
  openUrl = await startApp({ ...base, screeningStages: [], foodSafetyGate: fixtureFoodSafetyGate() });
  closedUrl = await startApp({ ...base, screeningStages: [], foodSafetyGate: closedFoodSafetyGate(), moderation: stubModerationQueue() });
  emptyCanonUrl = await startApp({ ...base, screeningStages: [], foodSafetyGate: emptyCanonGate, moderation: stubModerationQueue() });
});

afterAll(async () => {
  for (const server of servers) {
    server.close();
  }
  jwksServer.stop(true);
  await harness.close();
});

describe("the publish gate is fail closed while canon/facts are not loaded", () => {
  test("publishing on a closed gate returns the unavailable error envelope", async () => {
    const alice = await signInAs(closedUrl, "gate-closed-alice");
    const res = await publish(closedUrl, alice, publishBody());
    expect(res.status).toBe(503);
    const body = (await json(res)) as { code: string; error: string };
    expect(body.code).toBe("unavailable");
    expect(body.error).toContain("food-safety gate is closed");
  });

  test("the same refusal on an empty canon file", async () => {
    const alice = await signInAs(emptyCanonUrl, "gate-empty-alice");
    const res = await publish(emptyCanonUrl, alice, publishBody());
    expect(res.status).toBe(503);
    expect(((await json(res)) as { code: string }).code).toBe("unavailable");
  });

  test("a refused publish persists nothing and enters nothing into moderation", async () => {
    const alice = await signInAs(closedUrl, "gate-closed-alice");
    await publish(closedUrl, alice, publishBody());
    await publish(closedUrl, alice, publishBody({ source: { recipeId: "recipes/test-gate-soup", recipeRevision: "rev-000002" } }));
    const mine = await fetch(`${closedUrl}/v1/community/publications/mine`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(mine.status).toBe(200);
    expect(((await json(mine)) as { items: unknown[] }).items).toHaveLength(0);
    const stored = await harness.store.publications.get();
    expect(stored.size).toBe(0);
  });
});

describe("the mandatory lint and allergen-claim checks block unsound recipes", () => {
  test("a doneness claim without thermometer evidence fails the lint into the queue, hidden", async () => {
    const alice = await signInAs(openUrl, "gate-lint-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-chicken", recipeRevision: "rev-000003" },
      recipe: {
        title: "Skillet chicken",
        summary: "Weeknight chicken.",
        ingredientLines: ["400 g chicken thigh"],
        steps: ["Cook the chicken until it is no longer pink."],
      },
      campus: "gate-lint",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");
    expect(created.screeningFailures.map((f) => f.stage)).toContain("food-safety-lint");
    expect(created.screeningFailures.some((f) => f.reasons.some((r) => r.includes("doneness")))).toBe(true);

    const bob = await signInAs(openUrl, "gate-lint-bob");
    const feed = (await json(await fetch(`${openUrl}/v1/community/explore/gate-lint`, { headers: { authorization: `Bearer ${bob.accessToken}` } }))) as unknown as FeedJson;
    expect(feed.items).toHaveLength(0);
  });

  test("a supported doneness claim passes the lint", async () => {
    const alice = await signInAs(openUrl, "gate-lint-ok-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-chicken-ok", recipeRevision: "rev-000004" },
      recipe: {
        title: "Skillet chicken, checked",
        summary: "Weeknight chicken with a thermometer check.",
        ingredientLines: ["400 g chicken thigh"],
        steps: ["Cook the chicken until it is no longer pink.", "Confirm 74°C at the thickest point with a thermometer."],
      },
      campus: "gate-lint-ok",
    }));
    expect(res.status).toBe(201);
    expect(((await json(res)) as unknown as PublicationJson).status).toBe("published");
  });

  test("an unsupported allergen-free claim fails the compound-allergen stage", async () => {
    const alice = await signInAs(openUrl, "gate-claim-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-claim", recipeRevision: "rev-000005" },
      recipe: {
        title: "Noodle stir fry",
        summary: "Totally gluten free and delicious.",
        ingredientLines: ["200 g rice noodles", "2 tbsp soy sauce"],
        steps: ["Fry everything together."],
      },
      campus: "gate-claim",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");
    expect(created.screeningFailures.map((f) => f.stage)).toContain("compound-allergens");
    expect(created.screeningFailures.some((f) => f.reasons.some((r) => r.includes("wheat-gluten")))).toBe(true);
  });

  test("an unknown ingredient fails the compound-allergen stage into the queue, hidden — never silently allowed", async () => {
    const alice = await signInAs(openUrl, "gate-unknown-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-unknown", recipeRevision: "rev-000008" },
      recipe: {
        title: "Mystery powder drink",
        summary: "An exotic blend.",
        ingredientLines: ["200 g rice", "1 cup flurb"],
        steps: ["Blend and drink."],
      },
      campus: "gate-unknown",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    // Unknown composition is not allowed: the publication queues with the
    // uncovered line cited (blocker 3).
    expect(created.status).toBe("queued");
    expect(created.screeningFailures.map((f) => f.stage)).toContain("compound-allergens");
    expect(created.screeningFailures.some((f) => f.reasons.some((r) => r.includes("1 cup flurb") && r.includes("unknown")))).toBe(true);

    const bob = await signInAs(openUrl, "gate-unknown-bob");
    const feed = (await json(await fetch(`${openUrl}/v1/community/explore/gate-unknown`, { headers: { authorization: `Bearer ${bob.accessToken}` } }))) as unknown as FeedJson;
    expect(feed.items).toHaveLength(0);
  });
});

describe("a clean publication passes with compound-allergen tags persisted and returned", () => {
  test("soy sauce contributes its compound allergens (soy AND wheat) end to end", async () => {
    const alice = await signInAs(openUrl, "gate-clean-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-clean", recipeRevision: "rev-000006" },
      recipe: {
        title: "Sesame soy rice",
        summary: "A simple rice bowl.",
        ingredientLines: ["200 g rice", "2 tbsp soy sauce", "1 tbsp tahini"],
        steps: ["Cook the rice, then fry with the soy sauce; stir the tahini through off the heat."],
      },
      campus: "gate-clean",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");
    expect(created.screeningFailures).toHaveLength(0);
    expect(created.allergenTags).toEqual(["allergen-sesame", "allergen-soy", "allergen-wheat-gluten"]);

    // Persisted: the author's own view returns the same evaluation.
    const mine = await fetch(`${openUrl}/v1/community/publications/${created.publicationId}`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(mine.status).toBe(200);
    expect(((await json(mine)) as unknown as PublicationJson).allergenTags).toEqual(["allergen-sesame", "allergen-soy", "allergen-wheat-gluten"]);

    // Persisted: another reader's public view and the Explore feed return
    // the stored tags, not a recomputation.
    const bob = await signInAs(openUrl, "gate-clean-bob");
    const direct = await fetch(`${openUrl}/v1/community/publications/${created.publicationId}`, {
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(direct.status).toBe(200);
    expect(((await json(direct)) as unknown as PublicationJson).allergenTags).toEqual(["allergen-sesame", "allergen-soy", "allergen-wheat-gluten"]);

    const feed = (await json(await fetch(`${openUrl}/v1/community/explore/gate-clean`, { headers: { authorization: `Bearer ${bob.accessToken}` } }))) as unknown as FeedJson;
    expect(feed.items).toHaveLength(1);
    expect(feed.items[0]?.allergenTags).toEqual(["allergen-sesame", "allergen-soy", "allergen-wheat-gluten"]);
  });

  test("an allergen-free recipe publishes with no tags", async () => {
    const alice = await signInAs(openUrl, "gate-plain-alice");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/test-gate-plain", recipeRevision: "rev-000007" },
      recipe: { title: "Cucumber salad", summary: null, ingredientLines: ["1 cucumber"], steps: ["Slice and dress."], },
      campus: "gate-plain",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");
    expect(created.allergenTags).toEqual([]);
  });
});

describe("the loader fails closed on every kind of bad data", () => {
  const validFacts = `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`;
  const validCanon = `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`;

  function loaderCase(canon: string | null, facts: string | null): ReturnType<typeof loadFoodSafetyCatalog> {
    return loadFoodSafetyCatalog({ canon: canon ?? "", facts: facts ?? "" });
  }

  /** A provenance block over the given entries whose blob hash verifies at load. */
  function provenanceFor(entries: Array<{ id: string; match: string[]; allergens: string[] }>) {
    return {
      sourceBranch: "test fixture (authored in this repository)",
      sourceFile: "src/__tests__/community/fixtures/food-safety/ingredient-facts.json",
      sourceCommit: "fixture",
      sourceFileHash: `sha256:${"0".repeat(64)}`,
      copiedBlobHash: `sha256:${sha256Hex(stableIngredientFactsString(entries))}`,
      extracted: "minimal test facts",
    };
  }

  test("valid packages open the catalog", () => {
    const catalog = loaderCase(validCanon, validFacts);
    expect(catalog.loaded).toBe(true);
  });

  test("absent files are not loaded, with a stated reason", () => {
    const closed = loaderCase("/nonexistent/canon.json", validFacts);
    expect(closed.loaded).toBe(false);
    if (!closed.loaded) {
      expect(closed.reason).toContain("canon not loaded");
    }
  });

  test("empty and unparsable files are not loaded", () => {
    const dir = mkdtempSync(join(tmpdir(), "fl-bad-canon-"));
    writeFileSync(join(dir, "empty.json"), "", "utf8");
    writeFileSync(join(dir, "torn.json"), "{ not json", "utf8");
    expect(loaderCase(join(dir, "empty.json"), validFacts).loaded).toBe(false);
    const torn = loaderCase(join(dir, "torn.json"), validFacts);
    expect(torn.loaded).toBe(false);
    if (!torn.loaded) {
      expect(torn.reason).toContain("not parsable");
    }
    rmSync(dir, { recursive: true, force: true });
  });

  test("off-schema or empty rules/facts documents are not loaded", () => {
    const dir = mkdtempSync(join(tmpdir(), "fl-schema-canon-"));
    const canonPath = join(dir, "canon.json");
    const factsPath = join(dir, "facts.json");
    const entries = [{ id: "tahini", match: ["tahini"], allergens: ["sesame"] }];
    writeFileSync(factsPath, JSON.stringify({ schema: INGREDIENT_FACTS_SCHEMA, source: "x", allergens: ["sesame"], ingredients: entries, provenance: provenanceFor(entries) }), "utf8");
    writeFileSync(canonPath, JSON.stringify({ schema: "some/other@v9", source: "x", rules: [{ kind: "forbidden-terms", id: "r", terms: ["x"], message: "y" }] }), "utf8");
    expect(loaderCase(canonPath, factsPath).loaded).toBe(false);
    writeFileSync(canonPath, JSON.stringify({ schema: FOOD_SAFETY_CANON_SCHEMA, source: "x", rules: [] }), "utf8");
    expect(loaderCase(canonPath, factsPath).loaded).toBe(false);
    writeFileSync(canonPath, JSON.stringify({ schema: FOOD_SAFETY_CANON_SCHEMA, source: "x", rules: [{ kind: "claim-requires-evidence", id: "r", triggers: ["t"], requireAny: ["([unclosed"], message: "y" }] }), "utf8");
    const badRegex = loaderCase(canonPath, factsPath);
    expect(badRegex.loaded).toBe(false);
    if (!badRegex.loaded) {
      expect(badRegex.reason).toContain("invalid regular expression");
    }
    // A rulebook allergen reference outside the facts vocabulary is bad data.
    writeFileSync(canonPath, JSON.stringify({ schema: FOOD_SAFETY_CANON_SCHEMA, source: "x", rules: [{ kind: "allergen-claim", id: "r", claims: [{ phrases: ["gluten free"], allergen: "wheat-gluten" }], message: "y" }] }), "utf8");
    expect(loaderCase(canonPath, factsPath).loaded).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test("path resolution honours explicit env vars and the data-root convention", () => {
    const paths = resolveFoodSafetyCatalogPaths({ env: { FOOD_SAFETY_CANON_PATH: "/a/canon.json", FOOD_SAFETY_FACTS_PATH: "/b/facts.json" }, cwd: "/nowhere" });
    expect(paths.canon).toBe("/a/canon.json");
    expect(paths.facts).toBe("/b/facts.json");
    const rooted = resolveFoodSafetyCatalogPaths({ env: {}, dataRoot: "/srv/fl" });
    expect(rooted.canon).toBe("/srv/fl/data/food-safety/canon.json");
    expect(rooted.facts).toBe("/srv/fl/data/food-safety/ingredient-facts.json");
    // The default location walks up from the working directory to the nearest
    // ancestor holding a data/ directory (the repo root when run from
    // backend/gemini-agent with the packages landed at data/food-safety).
    const dir = mkdtempSync(join(tmpdir(), "fl-data-root-"));
    try {
      mkdirSync(join(dir, "data"), { recursive: true });
      const deep = join(dir, "deep", "deeper");
      mkdirSync(deep, { recursive: true });
      const walked = resolveFoodSafetyCatalogPaths({ env: {}, cwd: deep });
      expect(walked.canon).toBe(join(dir, "data", "food-safety", "canon.json"));
      expect(walked.facts).toBe(join(dir, "data", "food-safety", "ingredient-facts.json"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
