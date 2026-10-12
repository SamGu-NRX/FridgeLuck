/**
 * Blocker 2 (PR #104 review): the publish-side safety gate must enforce the
 * CANONICAL rulebook's per-class cooking-temperature minimums
 * (overhaul/food-safety-canon, data/food-safety/rules.json), never a looser
 * local copy. Four arms:
 *
 *   (i)   the loaded floors ARE the canonical values — pinned here so
 *         future drift fails this suite — with checkable provenance
 *         (source branch, data file, commit, and sha256 of both the source
 *         file and the copied minimums+keywords blob);
 *   (ii)  a stated doneness temperature below the canonical class minimum
 *         fails the lint, including content the pre-canonical copy let
 *         through (the old local canon carried no numeric floors at all,
 *         so "at the old minimum" meant any stated number passed);
 *   (iii) if the canonical numbers are unavailable, unparsable, malformed
 *         or drifted at load time, the gate fails closed — requiredStages
 *         is null, no pass is ever issued from a local fallback;
 *   (iv)  the refusal holds end to end on the real publish path.
 *
 * Boundary stated honestly (ii): this is a text lint over free text —
 * genuinely raw preparations (tartare, cured fish) fail into human review
 * rather than publish silently.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
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
import { stubBlockDirectory } from "../../community/shared/testing/stubs.js";
import { createFoodSafetyGate, foodSafetyLintStage } from "../../community/foodSafety/gate.js";
import {
  FOOD_SAFETY_CANON_SCHEMA,
  loadFoodSafetyCatalog,
  sha256Hex,
  stableCookingTempString,
  type FoodSafetyClass,
  type FoodSafetyRulebook,
  type MinCookingTempRule,
} from "../../community/foodSafety/catalog.js";
import type { ScreenablePublication, ScreeningVerdict } from "../../community/shared/contracts.js";
import { FOOD_SAFETY_FIXTURE_DIR, fixtureFoodSafetyGate } from "./foodSafetyGate.js";

/**
 * The canonical class minimums, transcribed from overhaul/food-safety-canon
 * data/food-safety/rules.json (rs_alignment.minimums_f) at commit
 * a092c9a4aa8a5fbb7e62e88da26a1a3dce3970b7 — the USDA FSIS chart the
 * rulebook cites. Hardcoded here so a loosened local copy fails this suite
 * even if its recorded provenance hash is re-blessed.
 */
const CANONICAL_MINIMUMS_F: Record<FoodSafetyClass, number> = {
  meat_poultry: 165,
  meat_ground: 160,
  meat_whole_cut_pork: 145,
  meat_whole_cut_red: 145,
  flesh_fish: 145,
  flesh_shellfish: 145,
  egg: 160,
  leftovers: 165,
};

const FIXTURE_FACTS = `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`;

function fixtureCatalog() {
  return loadFoodSafetyCatalog({ canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`, facts: FIXTURE_FACTS });
}

function numericRule(): MinCookingTempRule {
  const catalog = fixtureCatalog();
  if (!catalog.loaded) {
    throw new Error(`fixture canon did not load: ${catalog.reason}`);
  }
  const rule = catalog.rulebook.rules.find((r): r is MinCookingTempRule => r.kind === "min-cooking-temp");
  if (rule === undefined) {
    throw new Error("fixture canon carries no min-cooking-temp rule");
  }
  return rule;
}

/** The rulebook as the pre-canonical local copy was: no numeric floors. */
function legacyRulebook(): FoodSafetyRulebook {
  const catalog = fixtureCatalog();
  if (!catalog.loaded) {
    throw new Error(`fixture canon did not load: ${catalog.reason}`);
  }
  return {
    schema: catalog.rulebook.schema,
    source: catalog.rulebook.source,
    rules: catalog.rulebook.rules.filter((rule) => rule.kind !== "min-cooking-temp"),
  };
}

async function lintVerdict(rulebook: FoodSafetyRulebook, publication: ScreenablePublication): Promise<ScreeningVerdict> {
  return foodSafetyLintStage(rulebook).run(publication);
}

function publication(fields: { title?: string; summary?: string | null; ingredientLines?: readonly string[]; steps: readonly string[] }): ScreenablePublication {
  return {
    title: fields.title ?? "Tomato rice",
    summary: fields.summary ?? null,
    ingredientLines: fields.ingredientLines ?? ["200 g rice", "2 tomatoes"],
    steps: fields.steps,
  };
}

/**
 * A canon file carrying every fixture rule except the numeric one, plus
 * `variantRule` (a JSON round-trip so deliberately-malformed shapes stay
 * honest) when `includeRule` is set. Returns the temp path.
 */
function variantCanonPath(transform: (rule: Record<string, unknown>) => void, includeRule: boolean): string {
  const rule = numericRule();
  const json = JSON.parse(JSON.stringify(rule)) as Record<string, unknown>;
  transform(json);
  const catalog = fixtureCatalog();
  if (!catalog.loaded) {
    throw new Error(`fixture canon did not load: ${catalog.reason}`);
  }
  const others = catalog.rulebook.rules.filter((entry) => entry.kind !== "min-cooking-temp");
  const rules = includeRule ? [...others, json] : others;
  const dir = mkdtempSync(join(tmpdir(), "fl-min-temp-"));
  writeFileSync(join(dir, "canon.json"), JSON.stringify({ schema: FOOD_SAFETY_CANON_SCHEMA, source: "blocker-2 variant", rules }), "utf8");
  return join(dir, "canon.json");
}

describe("the loaded cooking-temperature floors are the canonical rulebook's data", () => {
  test("the loaded per-class minimums equal the rulebook's class minimums (drift fails this suite)", () => {
    const rule = numericRule();
    expect(rule.minimumsF).toEqual(CANONICAL_MINIMUMS_F);
  });

  test("the attribution keywords keep the rulebook's critical class boundaries", () => {
    const rule = numericRule();
    // Ground poultry keeps the 165°F poultry minimum and must never fall
    // into the 160°F ground-meat class via its "mince" (rulebook:
    // ground-poultry-165's rs_note); "fresh ham" stays pork while bare
    // "ham" (reheated) is the 165°F leftovers class.
    expect(rule.classKeywords.meat_poultry).toContain("ground turkey");
    expect(rule.classKeywords.meat_poultry).toContain("turkey mince");
    expect(rule.classKeywords.meat_ground).toContain("mince");
    expect(rule.classKeywords.meat_whole_cut_pork).toContain("fresh ham");
    expect(rule.classKeywords.leftovers).toContain("ham");
  });

  test("the copied floors carry checkable provenance", () => {
    const rule = numericRule();
    expect(rule.provenance.sourceBranch).toBe("overhaul/food-safety-canon");
    expect(rule.provenance.sourceFile).toBe("data/food-safety/rules.json");
    expect(rule.provenance.sourceCommit).toBe("a092c9a4aa8a5fbb7e62e88da26a1a3dce3970b7");
    expect(rule.provenance.sourceFileHash).toBe("sha256:ba31ca0c868268f4cc3488afaa90d08033a42dbf1ea31ed807b61a1f60e4b01b");
    // Checkable: the recorded blob hash is exactly the hash of the loaded data.
    expect(`sha256:${sha256Hex(stableCookingTempString(rule))}`).toBe(rule.provenance.copiedBlobHash);
  });
});

describe("the loader fails closed on canonical data that is absent, unparsable, malformed or drifted", () => {
  test("a loosened floor is a drifted copy: the catalog refuses to load it", () => {
    const canonPath = variantCanonPath((rule) => {
      rule["minimumsF"] = { ...(rule["minimumsF"] as Record<string, number>), meat_poultry: 140 };
    }, true);
    const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: FIXTURE_FACTS });
    expect(catalog.loaded).toBe(false);
    if (!catalog.loaded) {
      expect(catalog.reason).toContain("provenance hash");
    }
  });

  test("a missing class floor fails closed", () => {
    const canonPath = variantCanonPath((rule) => {
      const minimums = { ...(rule["minimumsF"] as Record<string, number>) };
      delete minimums["egg"];
      rule["minimumsF"] = minimums;
    }, true);
    const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: FIXTURE_FACTS });
    expect(catalog.loaded).toBe(false);
    if (!catalog.loaded) {
      expect(catalog.reason).toContain("exactly the canonical classes");
    }
  });

  test("an unknown class fails closed", () => {
    const canonPath = variantCanonPath((rule) => {
      rule["minimumsF"] = { ...(rule["minimumsF"] as Record<string, number>), beef: 160 };
    }, true);
    const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: FIXTURE_FACTS });
    expect(catalog.loaded).toBe(false);
    if (!catalog.loaded) {
      expect(catalog.reason).toContain("exactly the canonical classes");
    }
  });

  test("a re-blessed-looking but wrong provenance hash fails closed", () => {
    const canonPath = variantCanonPath((rule) => {
      const provenance = { ...(rule["provenance"] as Record<string, unknown>) };
      provenance["copiedBlobHash"] = `sha256:${"0".repeat(64)}`;
      rule["provenance"] = provenance;
    }, true);
    const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: FIXTURE_FACTS });
    expect(catalog.loaded).toBe(false);
  });

  test("a rulebook without the reviewed floors is not the canonical rulebook", () => {
    const canonPath = variantCanonPath(() => {}, false);
    const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: FIXTURE_FACTS });
    expect(catalog.loaded).toBe(false);
    if (!catalog.loaded) {
      expect(catalog.reason).toContain("must include a min-cooking-temp rule");
    }
  });

  test("an unparsable canonical source closes the gate — no local fallback pass", () => {
    const dir = mkdtempSync(join(tmpdir(), "fl-min-temp-torn-"));
    writeFileSync(join(dir, "canon.json"), "{ not json", "utf8");
    const gate = createFoodSafetyGate({ canonPath: join(dir, "canon.json"), factsPath: FIXTURE_FACTS });
    expect(gate.requiredStages).toBeNull();
    expect(gate.closedReason).not.toBeNull();
    rmSync(dir, { recursive: true, force: true });
  });

  test("an unavailable canonical source closes the gate — no local fallback pass", () => {
    const gate = createFoodSafetyGate({ canonPath: "/nonexistent/food-safety-canon.json", factsPath: FIXTURE_FACTS });
    expect(gate.requiredStages).toBeNull();
    expect(gate.closedReason).not.toBeNull();
  });

  test("a drifted (loosened) canonical source closes the gate — no local fallback pass", () => {
    const canonPath = variantCanonPath((rule) => {
      rule["minimumsF"] = { ...(rule["minimumsF"] as Record<string, number>), meat_poultry: 140 };
    }, true);
    const gate = createFoodSafetyGate({ canonPath, factsPath: FIXTURE_FACTS });
    expect(gate.requiredStages).toBeNull();
    expect(gate.closedReason).not.toBeNull();
  });
});

describe("the lint refuses stated temperatures below the canonical class minimums", () => {
  test("a chicken recipe stating 145°F fails the lint; the pre-canonical copy passed the same publication", async () => {
    const body = publication({
      title: "Skillet chicken",
      ingredientLines: ["400 g chicken thigh"],
      steps: ["Cook the chicken to 145°F, measured with a thermometer."],
    });
    const verdict = await lintVerdict(fixtureRulebook(), body);
    expect(verdict.outcome).toBe("fail");
    if (verdict.outcome === "fail") {
      expect(verdict.reasons.some((reason) => reason.includes("meat_poultry minimum of 165°F"))).toBe(true);
    }
    // The old local copy — no numeric floors — passed the very same text.
    const legacy = await lintVerdict(legacyRulebook(), body);
    expect(legacy.outcome).toBe("pass");
  });

  test("chicken at 160°F — accepted by the pre-canonical copy, refused now (honest tightening)", async () => {
    const body = publication({
      title: "Skillet chicken",
      ingredientLines: ["400 g chicken thigh"],
      steps: ["Cook the chicken until it reaches 160°F, measured with a thermometer."],
    });
    const legacy = await lintVerdict(legacyRulebook(), body);
    expect(legacy.outcome).toBe("pass");
    const verdict = await lintVerdict(fixtureRulebook(), body);
    expect(verdict.outcome).toBe("fail");
    if (verdict.outcome === "fail") {
      expect(verdict.reasons.some((reason) => reason.includes("meat_poultry minimum of 165°F"))).toBe(true);
    }
  });

  test("ground meat below 160°F fails; steak and pork chop at their 145°F minimum pass", async () => {
    const undercooked = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Weeknight burgers", ingredientLines: ["400 g ground beef"], steps: ["Brown the burgers to 155°F with a thermometer."] }),
    );
    expect(undercooked.outcome).toBe("fail");
    if (undercooked.outcome === "fail") {
      expect(undercooked.reasons.some((reason) => reason.includes("meat_ground minimum of 160°F"))).toBe(true);
    }
    for (const [title, line, step] of [
      ["Flank steak", "300 g beef steak", "Cook the steak to 145°F, measured with a thermometer, then rest it 3 minutes."],
      ["Pork chops", "2 pork chops", "Cook the pork chop to 145°F with a thermometer, then rest 3 minutes."],
    ] as const) {
      const atMinimum = await lintVerdict(fixtureRulebook(), publication({ title, ingredientLines: [line], steps: [step] }));
      expect(atMinimum.outcome).toBe("pass");
    }
  });

  test("ground poultry keeps the 165°F poultry minimum, not the 160°F ground-meat one", async () => {
    const verdict = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Turkey burgers", ingredientLines: ["400 g turkey mince"], steps: ["Cook the turkey mince to 160°F, measured with a thermometer."] }),
    );
    expect(verdict.outcome).toBe("fail");
    if (verdict.outcome === "fail") {
      expect(verdict.reasons.some((reason) => reason.includes("meat_poultry minimum of 165°F"))).toBe(true);
      expect(verdict.reasons.some((reason) => reason.includes("meat_ground"))).toBe(false);
    }
  });

  test("a mixed sentence must reach every named class's minimum", async () => {
    const safe = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Surf and turf", ingredientLines: ["1 steak", "1 chicken thigh"], steps: ["Cook the chicken to 165°F and the steak to 145°F, both with a thermometer."] }),
    );
    expect(safe.outcome).toBe("pass");
    const unsafe = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Surf and turf", ingredientLines: ["1 steak", "1 chicken thigh"], steps: ["Cook the chicken and the steak to 145°F, both with a thermometer."] }),
    );
    expect(unsafe.outcome).toBe("fail");
  });

  test("an oven setting is not a doneness claim; cooling guidance is not a doneness claim", async () => {
    const oven = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Lasagne", ingredientLines: ["9 lasagne sheets"], steps: ["Preheat the oven to 425°F, then bake the lasagne until bubbling; confirm 74°C inside with a thermometer."] }),
    );
    expect(oven.outcome).toBe("pass");
    const cooling = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Rice salad", ingredientLines: ["200 g rice"], steps: ["Chill the rice to 40°F before storing."] }),
    );
    expect(cooling.outcome).toBe("pass");
  });

  test("a stated temperature with no attributable food must still reach the lowest reviewed minimum", async () => {
    const unsafe = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Mushroom loaf", ingredientLines: ["400 g mushrooms"], steps: ["Cook until it reaches 130°F, measured with a thermometer."] }),
    );
    expect(unsafe.outcome).toBe("fail");
    if (unsafe.outcome === "fail") {
      expect(unsafe.reasons.some((reason) => reason.includes("lowest reviewed class minimum of 145°F"))).toBe(true);
    }
    const safe = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Mushroom loaf", ingredientLines: ["400 g mushrooms"], steps: ["Cook until it reaches 150°F, measured with a thermometer."] }),
    );
    expect(safe.outcome).toBe("pass");
  });

  test("a bare step temperature falls back to the classes named elsewhere in the publication", async () => {
    const verdict = await lintVerdict(
      fixtureRulebook(),
      publication({ title: "Chicken tikka masala", ingredientLines: ["400 g chicken thigh", "200 ml cream"], steps: ["Simmer until it reaches 150°F, measured with a thermometer."] }),
    );
    expect(verdict.outcome).toBe("fail");
    if (verdict.outcome === "fail") {
      expect(verdict.reasons.some((reason) => reason.includes("meat_poultry minimum of 165°F"))).toBe(true);
    }
  });
});

function fixtureRulebook(): FoodSafetyRulebook {
  const catalog = fixtureCatalog();
  if (!catalog.loaded) {
    throw new Error(`fixture canon did not load: ${catalog.reason}`);
  }
  return catalog.rulebook;
}

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let openUrl: string;
const servers: Server[] = [];
let nonceCounter = 0;

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

function mintAppleToken(claims: { sub: string; nonce: string }): string {
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
  const nonce = `min-temp-nonce-${String(nonceCounter).padStart(4, "0")}`;
  const res = await fetch(`${url}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: mintAppleToken({ sub, nonce }), nonce, attested18Plus: true }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
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
  screeningFailures: ReadonlyArray<{ stage: string; reasons: readonly string[] }>;
}

interface FeedJson {
  campus: string;
  items: ReadonlyArray<{ publicationId: string }>;
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
  const blocks = stubBlockDirectory();
  const moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const app = express();
  app.use(express.json());
  app.use(
    createCommunityRouter(
      { store: harness.store, clock: harness.clock, config: harness.config, blocks, moderation, screeningStages: [], foodSafetyGate: fixtureFoodSafetyGate() },
      { identity: createIdentityRoutes, explore: createExploreRoutes },
    ),
  );
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  openUrl = await new Promise<string>((resolve) => {
    server.once("listening", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        throw new Error("test server did not bind");
      }
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
});

afterAll(async () => {
  for (const server of servers) {
    server.close();
  }
  jwksServer.stop(true);
  await harness.close();
});

describe("the canonical minimums hold end to end on the publish path", () => {
  test("a chicken recipe stating 145°F is queued for review, hidden from the feed", async () => {
    const alice = await signInAs(openUrl, "min-temp-alice");
    const res = await publish(openUrl, alice, {
      source: { recipeId: "recipes/test-min-temp-low", recipeRevision: "rev-000001" },
      recipe: {
        title: "Skillet chicken",
        summary: "Weeknight chicken.",
        ingredientLines: ["400 g chicken thigh"],
        steps: ["Cook the chicken to 145°F, measured with a thermometer."],
      },
      campus: "min-temp-low",
      note: null,
      declarations: { ownRights: true, noPersonalData: true, sourceRights: { textRedistribution: "permitted", attributionRequired: false } },
    });
    expect(res.status).toBe(201);
    const created = (await res.json()) as unknown as PublicationJson;
    expect(created.status).toBe("queued");
    expect(created.screeningFailures.map((failure) => failure.stage)).toContain("food-safety-lint");
    expect(created.screeningFailures.some((failure) => failure.reasons.some((reason) => reason.includes("meat_poultry minimum of 165°F")))).toBe(true);

    const bob = await signInAs(openUrl, "min-temp-bob");
    const feed = (await (await fetch(`${openUrl}/v1/community/explore/min-temp-low`, { headers: { authorization: `Bearer ${bob.accessToken}` } })).json()) as unknown as FeedJson;
    expect(feed.items).toHaveLength(0);
  });

  test("the same recipe at the canonical 165°F/74°C minimum publishes", async () => {
    const alice = await signInAs(openUrl, "min-temp-ok-alice");
    const res = await publish(openUrl, alice, {
      source: { recipeId: "recipes/test-min-temp-ok", recipeRevision: "rev-000002" },
      recipe: {
        title: "Skillet chicken, checked",
        summary: "Weeknight chicken with a thermometer check.",
        ingredientLines: ["400 g chicken thigh"],
        steps: ["Cook the chicken until it is no longer pink.", "Confirm 74°C at the thickest point with a thermometer."],
      },
      campus: "min-temp-ok",
      note: null,
      declarations: { ownRights: true, noPersonalData: true, sourceRights: { textRedistribution: "permitted", attributionRequired: false } },
    });
    expect(res.status).toBe(201);
    expect(((await res.json()) as unknown as PublicationJson).status).toBe("published");
  });
});
