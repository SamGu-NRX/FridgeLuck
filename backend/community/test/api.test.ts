/**
 * End-to-end tests over exactly the production wiring: buildApp with the
 * in-memory store, a stubbed Apple verifier, and a fake clock. Request-level
 * assertions against the OpenAPI routes, including the error envelope.
 */

import { describe, test, expect, beforeAll } from "bun:test";
import { buildApp, type App } from "../src/app.js";
import type { AppleIdentityTokenClaims } from "../src/core/appleVerify.js";
import { AppleVerifier } from "../src/core/appleVerify.js";
import { generateKeyPairSync, createHash, sign as rsaSign } from "node:crypto";
import { MemoryStore } from "../src/core/store/memory.js";
import type { DocumentStore, StoreCollection, StoreTransaction } from "../src/core/store/documentStore.js";
import { errorResponse } from "../src/core/router.js";
import { configFromEnv } from "../src/config.js";

/** Maps a stub identity token to an Apple sub; anything unknown is refused. */
const stubApple = {
  verify: async (identityToken: string, nonce: string, _nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("rejected by Apple");
    }
    return { appleSub: identityToken.slice(9), nonce, email: "nobody@privaterelay.appleid.com" };
  },
};

const cleanRecipe = {
  title: "Lemon pasta for two",
  description: "A bright weeknight dinner.",
  servings: 2,
  timeMinutes: 15,
  ingredientLines: [
    { name: "milk", quantity: 200, unit: "ml" },
    { name: "flour", quantity: 250, unit: "g" },
  ],
  steps: [{ text: "Boil the pasta, then cook everything together for ten minutes.", timerMinutes: 10 }],
  equipment: ["pan"],
  dietaryTags: ["vegetarian"],
};

const publicationBody = (over: Record<string, unknown> = {}) => ({
  operationId: crypto.randomUUID(),
  recipeRef: { source: "user", id: "r-1", revision: 1 },
  content: cleanRecipe,
  declaration: { ownRights: true, noPersonalData: true },
  ...over,
});

async function signUp(app: App, sub: string): Promise<{ accessToken: string; refreshToken: string; accountId: string }> {
  const response = await app.handle(
    new Request("https://api.test/v1/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ identityToken: `stub-jwt-${sub}`, nonce: crypto.randomUUID() }),
    }),
  );
  expect(response.status).toBe(200);
  const data = (await response.json()) as { accessToken: string; refreshToken: string; account: { accountId: string } };
  return { accessToken: data.accessToken, refreshToken: data.refreshToken, accountId: data.account.accountId };
}

const authed = (token: string, init: RequestInit = {}): RequestInit => ({
  ...init,
  headers: { ...(init.headers as Record<string, string> | undefined), authorization: `Bearer ${token}` },
});

describe("health and routing", () => {
  test("answers GET /healthz", async () => {
    const app = await buildApp({ apple: stubApple });
    const response = await app.handle(new Request("https://api.test/healthz"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  test("unknown paths 404 with the contract envelope", async () => {
    const app = await buildApp({ apple: stubApple });
    const response = await app.handle(new Request("https://api.test/v1/nothing"));
    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("not_found");
    expect(typeof body.error.message).toBe("string");
  });
});

describe("identity (SPEC §6.1–6.2)", () => {
  test("sign in issues fla1./flr1. tokens and a contract account view", async () => {
    const app = await buildApp({ apple: stubApple });
    const response = await app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: "stub-jwt-sub-A", nonce: crypto.randomUUID(), attest18Plus: { birthYear: 1990 } }),
      }),
    );
    expect(response.status).toBe(200);
    const data = (await response.json()) as {
      accessToken: string;
      refreshToken: string;
      account: { accountId: string; displayName: string; isAdult: boolean; canVoteAt: string | null; moderationOperator: boolean };
    };
    expect(data.accessToken.startsWith("fla1.")).toBe(true);
    expect(data.refreshToken.startsWith("flr1.")).toBe(true);
    expect(data.account.isAdult).toBe(true);
    expect(data.account.canVoteAt).not.toBeNull(); // fresh account: 24 h away
    expect(data.account.moderationOperator).toBe(false);
  });

  test("a reused nonce is refused", async () => {
    const app = await buildApp({ apple: stubApple });
    const nonce = crypto.randomUUID();
    const body = JSON.stringify({ identityToken: "stub-jwt-sub-reuse", nonce });
    const first = await app.handle(new Request("https://api.test/v1/auth/apple", { method: "POST", headers: { "content-type": "application/json" }, body }));
    expect(first.status).toBe(200);
    const second = await app.handle(new Request("https://api.test/v1/auth/apple", { method: "POST", headers: { "content-type": "application/json" }, body }));
    expect(second.status).toBe(401);
  });

  test("a rejected Apple token 401s", async () => {
    const app = await buildApp({ apple: stubApple });
    const response = await app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: "not-a-stub-token", nonce: crypto.randomUUID() }),
      }),
    );
    expect(response.status).toBe(401);
  });

  test("the same Apple sub signs back into the same account and honors first-write-wins attestation", async () => {
    const app = await buildApp({ apple: stubApple });
    const first = await signUp(app, "sub-returning");
    const second = await signUp(app, "sub-returning");
    expect(second.accountId).toBe(first.accountId);
    const me = await app.handle(new Request("https://api.test/v1/me", { headers: { authorization: `Bearer ${second.accessToken}` } }));
    expect(((await me.json()) as { isAdult: boolean })["isAdult"]).toBe(false); // first sign-in had no attestation; a later one never overwrites
  });

  test("refresh rotation works once and replays revoke the family", async () => {
    const app = await buildApp({ apple: stubApple });
    const first = await signUp(app, "sub-refresh");
    const rotate = await app.handle(
      new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: first.refreshToken }) }),
    );
    expect(rotate.status).toBe(200);
    const rotated = (await rotate.json()) as { refreshToken: string };
    const replay = await app.handle(
      new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: first.refreshToken }) }),
    );
    expect(replay.status).toBe(401);
    const after = await app.handle(
      new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: rotated.refreshToken }) }),
    );
    expect(after.status).toBe(401); // family revoked
  });

  test("GET /me without a token 401s; PATCH /me updates the display name", async () => {
    const app = await buildApp({ apple: stubApple });
    const anon = await app.handle(new Request("https://api.test/v1/me"));
    expect(anon.status).toBe(401);
    const user = await signUp(app, "sub-profile");
    const patch = await app.handle(new Request("https://api.test/v1/me", { method: "PATCH", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ displayName: "Sam" }) }) }));
    expect(patch.status).toBe(200);
    expect(((await patch.json()) as { displayName: string }).displayName).toBe("Sam");
  });

  test("DELETE /session revokes exactly the presented session", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-session");
    const revoke = await app.handle(new Request("https://api.test/v1/session", { method: "DELETE", ...authed(user.accessToken) }));
    expect(revoke.status).toBe(204);
    const after = await app.handle(new Request("https://api.test/v1/me", { headers: { authorization: `Bearer ${user.accessToken}` } }));
    expect(after.status).toBe(401);
  });

  test("account deletion blocks sign-in and refresh immediately", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-delete");
    const del = await app.handle(new Request("https://api.test/v1/account", { method: "DELETE", ...authed(user.accessToken) }));
    expect(del.status).toBe(202);
    const refresh = await app.handle(
      new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: user.refreshToken }) }),
    );
    expect(refresh.status).toBe(401);
    const resign = await app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: "stub-jwt-sub-delete", nonce: crypto.randomUUID() }),
      }),
    );
    expect(resign.status).toBe(401);
  });
});

describe("publications (SPEC §2)", () => {
  test("a clean recipe publishes directly; the replayed operationId returns the original response", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-publish");
    const body = publicationBody();
    const first = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }) }),
    );
    expect(first.status).toBe(201);
    const view = (await first.json()) as { publicationId: string; state: string; content: { title: string }; authorDisplayName: string };
    expect(view.state).toBe("published");
    expect(view.content.title).toBe(cleanRecipe.title);
    expect(view.authorDisplayName).toBe("Cook");
    const replay = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }) }),
    );
    expect(replay.status).toBe(201);
    expect(((await replay.json()) as { publicationId: string }).publicationId).toBe(view.publicationId);
  });

  test("missing declarations 400 with declarations_missing", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-nodecl");
    const response = await app.handle(
      new Request("https://api.test/v1/publications", {
        method: "POST",
        ...authed(user.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify(publicationBody({ declaration: { ownRights: true, noPersonalData: false } })),
        }),
      }),
    );
    expect(response.status).toBe(422); // contract: declarations_missing rides the publish 422
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("declarations_missing");
  });

  test("a blocked recipe goes straight to the human queue and never reaches Explore", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-blocked");
    const body = publicationBody({
      content: { ...cleanRecipe, description: "Questions? Email alice@example.com and I will reply." },
    });
    const response = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }) }),
    );
    expect(response.status).toBe(201);
    const view = (await response.json()) as { state: string };
    expect(view.state).toBe("queued");
    const feed = await app.handle(new Request("https://api.test/v1/explore/feed"));
    expect(((await feed.json()) as { items: unknown[] }).items).toHaveLength(0);
  });

  test("a raw-protein recipe with no cooking step is blocked by the fail-closed lint", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-lint");
    const body = publicationBody({
      content: { ...cleanRecipe, ingredientLines: [{ name: "chicken", quantity: 300, unit: "g" }], steps: [{ text: "Season the chicken and plate it.", timerMinutes: null }] },
    });
    const response = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }) }),
    );
    expect(((await response.json()) as { state: string }).state).toBe("queued");
  });

  test("an unloaded screening gate fails closed with 503", async () => {
    const app = await buildApp({ apple: stubApple, config: { screeningPackagesLoaded: false } });
    const user = await signUp(app, "sub-503");
    const response = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    expect(response.status).toBe(503);
  });

  test("the daily publish limit returns 429 and the idempotent replay still succeeds", async () => {
    const app = await buildApp({ apple: stubApple, config: { ...{ } } });
    const user = await signUp(app, "sub-ratelimit");
    let last: Response | null = null;
    for (let i = 0; i < 21; i += 1) {
      last = await app.handle(
        new Request("https://api.test/v1/publications", {
          method: "POST",
          ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody({ recipeRef: { source: "user", id: `r-${i}`, revision: 1 } })) }),
        }),
      );
    }
    expect(last?.status).toBe(429);
    // 21st call had a fresh operationId, so the 20 publishes before it each count.
  });

  test("mine lists your states, the reader route only resolves published, withdrawal is idempotent", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-mine");
    const published = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const { publicationId } = (await published.json()) as { publicationId: string };
    const mine = await app.handle(new Request("https://api.test/v1/publications/mine", { headers: { authorization: `Bearer ${user.accessToken}` } }));
    const mineBody = (await mine.json()) as { publications: { publicationId: string; state: string }[] };
    expect(mineBody.publications.map((p) => p.publicationId)).toContain(publicationId);

    const read = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`));
    expect(read.status).toBe(200);

    const withdraw = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`, { method: "DELETE", ...authed(user.accessToken) }));
    expect(withdraw.status).toBe(204);
    const again = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`, { method: "DELETE", ...authed(user.accessToken) }));
    expect(again.status).toBe(204);
    const reader = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`));
    expect(reader.status).toBe(404);
  });

  test("you cannot withdraw someone else's publication", async () => {
    const app = await buildApp({ apple: stubApple });
    const author = await signUp(app, "sub-owner");
    const stranger = await signUp(app, "sub-stranger");
    const created = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(author.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const { publicationId } = (await created.json()) as { publicationId: string };
    const response = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`, { method: "DELETE", ...authed(stranger.accessToken) }));
    expect(response.status).toBe(404);
  });
});

describe("explore (SPEC §3)", () => {
  test("the feed serves candidate cards with a null cook count below the floor of 10", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-explore");
    await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const feed = await app.handle(new Request("https://api.test/v1/explore/feed"));
    expect(feed.status).toBe(200);
    const data = (await feed.json()) as {
      items: { recipeRef: { id: string }; title: string; authorDisplayName: string; cookedBy: string | null; timeMinutes: number | null; allergenTags: string[]; publishedAt: string }[];
      fetchedAt: string;
    };
    expect(data.items).toHaveLength(1);
    expect(data.items[0]?.title).toBe(cleanRecipe.title);
    expect(data.items[0]?.cookedBy).toBeNull();
    // fail-closed (burst14): the reviewed canon certainly carries milk and
    // wheat, and a line it cannot fully adjudicate also adds unknown-contents.
    expect(data.items[0]?.allergenTags).toEqual(["milk", "unknown-contents", "wheat"]); // contract card: candidates and freshness only; ranking stays on the phone
    const counts = await app.handle(new Request("https://api.test/v1/explore/cook-counts"));
    const countsBody = (await counts.json()) as { counts: { cookedBy: string | null }[] };
    expect(countsBody.counts[0]?.cookedBy).toBeNull();
  });
});

describe("moderation (SPEC §6.5–6.6)", () => {
  test("a report hides the published recipe immediately and queues a case; more reports append", async () => {
    const app = await buildApp({ apple: stubApple });
    const author = await signUp(app, "sub-reported");
    const reporter = await signUp(app, "sub-reporter");
    const created = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(author.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const { publicationId } = (await created.json()) as { publicationId: string };

    const report = await app.handle(
      new Request("https://api.test/v1/reports", {
        method: "POST",
        ...authed(reporter.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ targetType: "recipe", targetId: publicationId, reason: "food_safety", detail: "undercooked" }),
        }),
      }),
    );
    expect(report.status).toBe(202);
    const read = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`));
    expect(read.status).toBe(404); // hidden while queued

    const second = await signUp(app, "sub-reporter-2");
    await app.handle(
      new Request("https://api.test/v1/reports", {
        method: "POST",
        ...authed(second.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ targetType: "recipe", targetId: publicationId, reason: "spam" }),
        }),
      }),
    );

    // Operator access is allowlist-gated.
    const anonQueue = await app.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${reporter.accessToken}` } }));
    expect(anonQueue.status).toBe(403);

    const operatorApp = await buildApp({ apple: stubApple, config: { operatorAccountIds: ["sub-op"] } });
    void operatorApp;
    // Allowlist is by account id, which only exists after sign-in; build a
    // second app over the SAME store to grant operator status post-hoc.
    const operatorUser = await signUp(app, "sub-op");
    const opApp = await buildApp({ apple: stubApple, store: (app as unknown as { store: import("../src/core/store/documentStore.js").DocumentStore })["store"], config: { operatorAccountIds: [operatorUser.accountId] } });
    // A non-operator account still sees 403 on the operator app too.
    const denied = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${reporter.accessToken}` } }));
    expect(denied.status).toBe(403);
    const queue = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${operatorUser.accessToken}` } }));
    expect(queue.status).toBe(200);
    const cases = (await queue.json()) as { cases: { caseId: string; targetId: string; reports: { reason: string }[]; state: string; screening: unknown[]; declaration: { ownRights: boolean } }[] };
    expect(cases.cases).toHaveLength(1);
    const item = cases.cases[0];
    expect(item?.targetId).toBe(publicationId);
    expect(item?.reports.map((r) => r.reason)).toEqual(["food_safety", "spam"]);
    expect(item?.declaration.ownRights).toBe(true);
    expect(Array.isArray(item?.screening)).toBe(true);
  });

  test("a decision resolves a case exactly once and its effect follows the action", async () => {
    const app = await buildApp({ apple: stubApple });
    const author = await signUp(app, "sub-decide-author");
    const reporter = await signUp(app, "sub-decide-reporter");
    const created = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(author.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const { publicationId } = (await created.json()) as { publicationId: string };
    await app.handle(
      new Request("https://api.test/v1/reports", {
        method: "POST",
        ...authed(reporter.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ targetType: "recipe", targetId: publicationId, reason: "other" }) }),
      }),
    );
    const operatorUser = await signUp(app, "sub-decide-op");
    const opApp = await buildApp({ apple: stubApple, store: (app as unknown as { store: import("../src/core/store/documentStore.js").DocumentStore })["store"], config: { operatorAccountIds: [operatorUser.accountId] } });
    const queue = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${operatorUser.accessToken}` } }));
    const { cases } = (await queue.json()) as { cases: { caseId: string }[] };
    const caseId = cases[0]?.caseId as string;
    expect(caseId).toMatch(/^cse_/);

    const remove = await opApp.handle(
      new Request(`https://api.test/v1/moderation/cases/${caseId}/decision`, {
        method: "POST",
        ...authed(operatorUser.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "remove" }) }),
      }),
    );
    expect(remove.status).toBe(200);
    expect(((await remove.json()) as { state: string }).state).toBe("resolved");
    const authorView = await app.handle(new Request("https://api.test/v1/publications/mine", { headers: { authorization: `Bearer ${author.accessToken}` } }));
    const states = ((await authorView.json()) as { publications: { state: string }[] }).publications.map((p) => p.state);
    expect(states).toContain("rejected"); // remove is terminal
    const twice = await opApp.handle(
      new Request(`https://api.test/v1/moderation/cases/${caseId}/decision`, {
        method: "POST",
        ...authed(operatorUser.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "dismiss" }) }),
      }),
    );
    expect(twice.status).toBe(409);
  });

  test("dismiss returns report-hidden content to published (SPEC §6.6: dismiss → content returns)", async () => {
    const app = await buildApp({ apple: stubApple });
    const author = await signUp(app, "sub-dismiss-author");
    const reporter = await signUp(app, "sub-dismiss-reporter");
    const created = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(author.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    const { publicationId } = (await created.json()) as { publicationId: string };
    await app.handle(
      new Request("https://api.test/v1/reports", {
        method: "POST",
        ...authed(reporter.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ targetType: "recipe", targetId: publicationId, reason: "harassment" }) }),
      }),
    );
    const operatorUser = await signUp(app, "sub-dismiss-op");
    const opApp = await buildApp({ apple: stubApple, store: (app as unknown as { store: import("../src/core/store/documentStore.js").DocumentStore })["store"], config: { operatorAccountIds: [operatorUser.accountId] } });
    const queue = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${operatorUser.accessToken}` } }));
    const { cases } = (await queue.json()) as { cases: { caseId: string }[] };
    const decide = await opApp.handle(
      new Request(`https://api.test/v1/moderation/cases/${cases[0]?.caseId}/decision`, {
        method: "POST",
        ...authed(operatorUser.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "dismiss" }) }),
      }),
    );
    expect(decide.status).toBe(200);
    const authorView = await app.handle(new Request("https://api.test/v1/publications/mine", { headers: { authorization: `Bearer ${author.accessToken}` } }));
    const states = ((await authorView.json()) as { publications: { state: string }[] }).publications.map((p) => p.state);
    expect(states).toContain("published"); // the false report is undone: content returns
    const reader = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`));
    expect(reader.status).toBe(200); // resolves on the reader route again
  });

  test("dismiss of a screening-blocked case leaves the publication queued (the author decides re-publication)", async () => {
    const app = await buildApp({ apple: stubApple });
    const author = await signUp(app, "sub-screen-dismiss");
    const blocked = await app.handle(
      new Request("https://api.test/v1/publications", {
        method: "POST",
        ...authed(author.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify(publicationBody({ content: { ...cleanRecipe, ingredientLines: [{ name: "chicken breast", quantity: 300, unit: "g" }], steps: [{ text: "season the chicken on both sides.", timerMinutes: null }] } })),
        }),
      }),
    );
    expect(blocked.status).toBe(201);
    expect(((await blocked.json()) as { state: string }).state).toBe("queued");
    const operatorUser = await signUp(app, "sub-screen-op");
    const opApp = await buildApp({ apple: stubApple, store: (app as unknown as { store: import("../src/core/store/documentStore.js").DocumentStore })["store"], config: { operatorAccountIds: [operatorUser.accountId] } });
    const queue = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${operatorUser.accessToken}` } }));
    const { cases } = (await queue.json()) as { cases: { caseId: string }[] };
    const decide = await opApp.handle(
      new Request(`https://api.test/v1/moderation/cases/${cases[0]?.caseId}/decision`, {
        method: "POST",
        ...authed(operatorUser.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "dismiss" }) }),
      }),
    );
    expect(decide.status).toBe(200);
    const authorView = await app.handle(new Request("https://api.test/v1/publications/mine", { headers: { authorization: `Bearer ${author.accessToken}` } }));
    // Screening-blocked content is never re-published by dismissal; only the
    // author's corrected revision re-publishes (SPEC §2.3/§6.6).
    expect(((await authorView.json()) as { publications: { state: string }[] }).publications.map((p) => p.state)).toContain("queued");
  });

  test("reports are limited to 10 per account per day", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-report-limit");
    let last: Response | null = null;
    for (let i = 0; i < 11; i += 1) {
      last = await app.handle(
        new Request("https://api.test/v1/reports", {
          method: "POST",
          ...authed(user.accessToken, {
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ targetType: "recipe", targetId: "pub_0000000000000000000000000000", reason: "other" }),
          }),
        }),
      );
    }
    expect(last?.status).toBe(429);
  });
});

/**
 * Firestore's documented transaction rule (review finding 3): all reads must
 * precede all writes, or the transaction aborts. Wrapping the in-memory store
 * with that rule makes the production adapter's ordering observable in tests.
 */
class FirestoreOrderingStore implements DocumentStore {
  private readonly inner = new MemoryStore();

  collection(id: string) {
    return this.inner.collection(id);
  }

  runTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T> {
    return this.inner.runTransaction(async (tx) => {
      let writes = 0;
      const refuse = (): never => {
        throw new Error("read after write inside a transaction (Firestore would abort)");
      };
      const strictTx: StoreTransaction = {
        collection: (id: string) => {
          const col = tx.collection(id);
          return {
            id,
            doc: (docId: string) => {
              const ref = col.doc(docId);
              return {
                get: async () => {
                  if (writes > 0) {
                    refuse();
                  }
                  return ref.get();
                },
                create: async (data) => {
                  writes += 1;
                  return ref.create(data);
                },
                set: async (data) => {
                  writes += 1;
                  return ref.set(data);
                },
                update: async (data) => {
                  writes += 1;
                  return ref.update(data);
                },
              };
            },
            where: (field: string, value: unknown) => {
              if (writes > 0) {
                refuse();
              }
              return col.where(field, value);
            },
          };
        },
      };
      return fn(strictTx);
    });
  }
}

/**
 * Makes the orphan-account race deterministic (review finding 2): the first two
 * reads of an `identities` doc block until both concurrent sign-ins have read,
 * so both see "missing" — exactly the interleaving the reviewer described.
 * The gate applies only to non-transactional reads: after the fix the identity
 * lookup moves inside the bootstrap transaction, so the gate never engages.
 */
class GatedRaceStore implements DocumentStore {
  private readonly inner = new MemoryStore();
  private identityReads = 0;
  private releaseReads: (() => void) | null = null;
  private readonly bothRead = new Promise<void>((resolve) => {
    this.releaseReads = resolve;
  });

  private wrapCollection(col: StoreCollection): StoreCollection {
    const self = this;
    return {
      id: col.id,
      doc(id: string) {
        const ref = col.doc(id);
        return {
          async get() {
            if (col.id === "identities" && self.identityReads < 2) {
              self.identityReads += 1;
              if (self.identityReads === 2) {
                self.releaseReads?.();
              }
              await self.bothRead;
            }
            return ref.get();
          },
          create: (data) => ref.create(data),
          set: (data) => ref.set(data),
          update: (data) => ref.update(data),
        };
      },
      where(field: string, value: unknown) {
        return col.where(field, value);
      },
    };
  }

  collection(id: string): StoreCollection {
    return this.wrapCollection(this.inner.collection(id));
  }

  runTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T> {
    // Transactions pass through unwrapped: the fix under test performs its
    // identity read inside the transaction, where the store mutex already
    // serializes concurrent sign-ins.
    return this.inner.runTransaction(fn);
  }
}

describe("review round 2 (PR #160 findings)", () => {
  test("concurrent first sign-ins with one Apple sub land on one account", async () => {
    const app = await buildApp({ apple: stubApple, store: new GatedRaceStore() });
    const [a, b] = await Promise.all([signUp(app, "sub-race"), signUp(app, "sub-race")]);
    expect(a.accountId).toBe(b.accountId); // before the fix this strands an orphan account
  });

  test("refresh replay revokes the family even on a read-before-write transaction store (Firestore semantics)", async () => {
    const app = await buildApp({ apple: stubApple, store: new FirestoreOrderingStore() });
    const user = await signUp(app, "sub-ordering");
    const rotate = (token: string) =>
      app.handle(new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: token }) }));
    const first = await rotate(user.refreshToken);
    expect(first.status).toBe(200);
    const second = await rotate(((await first.json()) as { refreshToken: string }).refreshToken);
    expect(second.status).toBe(200);
    // Replaying the FIRST token — two generations old (review finding 3) — must
    // revoke the family without tripping Firestore's read-after-write abort.
    const replay = await rotate(user.refreshToken);
    expect(replay.status).toBe(401);
    expect(((await replay.json()) as { error: { code: string } }).error.code).toBe("unauthorized");
  });

  test("personal-data screening scans equipment and dietaryTags", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-pd-eq");
    for (const content of [
      { ...cleanRecipe, equipment: ["message chef@example.com"] },
      { ...cleanRecipe, dietaryTags: ["contact me at 555-0100"] },
    ]) {
      const res = await app.handle(
        new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody({ content })) }) }),
      );
      expect(res.status).toBe(201);
      expect(((await res.json()) as { state: string }).state).toBe("queued"); // blocked, never Explore
    }
  });

  test("equipment and dietaryTags are capped to the contract limits", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-caps");
    const tooMany = await app.handle(
      new Request("https://api.test/v1/publications", {
        method: "POST",
        ...authed(user.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify(publicationBody({ content: { ...cleanRecipe, equipment: Array.from({ length: 17 }, (_v, i) => `tool${i}`) } })),
        }),
      }),
    );
    expect(tooMany.status).toBe(422);
    const tooLong = await app.handle(
      new Request("https://api.test/v1/publications", {
        method: "POST",
        ...authed(user.accessToken, {
          headers: { "content-type": "application/json" },
          body: JSON.stringify(publicationBody({ content: { ...cleanRecipe, dietaryTags: ["x".repeat(25)] } })),
        }),
      }),
    );
    expect(tooLong.status).toBe(422);
  });

  test("concurrent publishes sharing one operationId create exactly one publication", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-oprace");
    const body = JSON.stringify(publicationBody());
    const [r1, r2] = await Promise.all([
      app.handle(new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body }) })),
      app.handle(new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body }) })),
    ]);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);
    const v1 = (await r1.json()) as { publicationId: string };
    const v2 = (await r2.json()) as { publicationId: string };
    expect(v1.publicationId).toBe(v2.publicationId);
    const mine = await app.handle(new Request("https://api.test/v1/publications/mine", { headers: { authorization: `Bearer ${user.accessToken}` } }));
    expect(((await mine.json()) as { publications: unknown[] }).publications).toHaveLength(1);
  });

  test("an invalid publish does not burn the daily quota", async () => {
    const app = await buildApp({ apple: stubApple });
    const user = await signUp(app, "sub-quota");
    for (let i = 0; i < 20; i += 1) {
      const bad = await app.handle(
        new Request("https://api.test/v1/publications", {
          method: "POST",
          ...authed(user.accessToken, {
            headers: { "content-type": "application/json" },
            body: JSON.stringify(publicationBody({ declaration: { ownRights: false, noPersonalData: false } })),
          }),
        }),
      );
      expect(bad.status).toBe(422);
    }
    const good = await app.handle(
      new Request("https://api.test/v1/publications", { method: "POST", ...authed(user.accessToken, { headers: { "content-type": "application/json" }, body: JSON.stringify(publicationBody()) }) }),
    );
    expect(good.status).toBe(201); // before the fix this is 429: the 422s burned the day's slots
  });

  test("an unreachable Apple key directory 503s instead of 401", async () => {
    const verifier = new AppleVerifier({
      config: { appleIssuer: "https://appleid.apple.com", appleBundleId: "dev.fridgeluck.app", appleJwksUrl: "https://appleid.apple.com/auth/keys" },
      fetchJwks: async () => {
        throw new Error("connection refused");
      },
    });
    const app = await buildApp({ apple: verifier });
    const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "k1" })).toString("base64url");
    const response = await app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: `${header}.${Buffer.from("{}").toString("base64url")}.c2ln`, nonce: crypto.randomUUID() }),
      }),
    );
    expect(response.status).toBe(503);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("unavailable");
  });

  test("malformed percent-encoding 404s instead of 500", async () => {
    const app = await buildApp({ apple: stubApple });
    const response = await app.handle(new Request("https://api.test/v1/publications/%zz"));
    expect(response.status).toBe(404);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("not_found");
  });

  test("unexpected errors return a fixed 500 message", () => {
    const mapped = errorResponse(new Error("leaked internal detail"));
    expect(mapped.status).toBe(500);
    expect(mapped.body.error.message).toBe("internal server error");
  });

  test("production refuses to boot without an explicit session secret", () => {
    const prevEnv = process.env.NODE_ENV;
    const prevSecret = process.env.COMMUNITY_SESSION_SECRET;
    try {
      process.env.NODE_ENV = "production";
      delete process.env.COMMUNITY_SESSION_SECRET;
      expect(() => configFromEnv()).toThrow(/COMMUNITY_SESSION_SECRET/);
      process.env.COMMUNITY_SESSION_SECRET = "explicit-secret";
      // Strict config (burst14): production also refuses the memory store and
      // unset deployment variables, so boot it on a complete safe config.
      process.env.COMMUNITY_STORE = "firestore";
      process.env.FIRESTORE_PROJECT_ID = "ci-project";
      process.env.COMMUNITY_BASE_URL = "https://community.example.com";
      process.env.APPLE_BUNDLE_ID = "dev.example.app";
      expect(() => configFromEnv()).not.toThrow();
    } finally {
      if (prevEnv === undefined) {
        delete process.env.NODE_ENV;
      } else {
        process.env.NODE_ENV = prevEnv;
      }
      if (prevSecret === undefined) {
        delete process.env.COMMUNITY_SESSION_SECRET;
      } else {
        process.env.COMMUNITY_SESSION_SECRET = prevSecret;
      }
      delete process.env.COMMUNITY_STORE;
      delete process.env.FIRESTORE_PROJECT_ID;
      delete process.env.COMMUNITY_BASE_URL;
      delete process.env.APPLE_BUNDLE_ID;
    }
  });
});

describe("nonce binding (the Apple request carries SHA-256 of the raw nonce)", () => {
  // The real verifier path: a locally generated RSA key set served from an
  // injected JWKS (the e2e boot serves the same shape over localhost), real
  // RS256 tokens minted in the test — no stub echoing the expected nonce.
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string };
  const kid = "binding-test-key";
  const verifier = new AppleVerifier({
    config: { appleIssuer: "https://appleid.apple.com", appleBundleId: "dev.fridgeluck.app", appleJwksUrl: "unused" },
    fetchJwks: async () => ({ keys: [{ kid, kty: jwk.kty, alg: "RS256", n: jwk.n, e: jwk.e }] }),
  });

  const mint = (claims: Record<string, unknown>): string => {
    const head = Buffer.from(JSON.stringify({ alg: "RS256", kid })).toString("base64url");
    const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
    const sig = rsaSign("RSA-SHA256", Buffer.from(`${head}.${body}`), privateKey).toString("base64url");
    return `${head}.${body}.${sig}`;
  };

  const claims = (nonce: string) => ({
    iss: "https://appleid.apple.com",
    aud: "dev.fridgeluck.app",
    sub: "binding-sub",
    nonce,
    email: "nobody@privaterelay.appleid.com",
    exp: Math.floor(Date.now() / 1000) + 600,
  });

  const signIn = (app: Awaited<ReturnType<typeof buildApp>>, identityToken: string, nonce: string) =>
    app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken, nonce }),
      }),
    );

  test("a token whose nonce claim is SHA-256(raw) signs in; a verbatim raw claim is refused", async () => {
    const app = await buildApp({ apple: verifier });

    // The app generates a raw nonce, binds SHA-256(raw) into the Apple request
    // (so the token carries the hash), and sends the raw nonce to the server.
    const rawNonce = crypto.randomUUID();
    const hashed = createHash("sha256").update(rawNonce).digest("hex");
    const ok = await signIn(app, mint(claims(hashed)), rawNonce);
    expect(ok.status).toBe(200);

    // The old (unbound) behavior — the token carries the raw nonce verbatim —
    // must be refused, or the binding would be decorative.
    const rawNonce2 = crypto.randomUUID();
    const refused = await signIn(app, mint(claims(rawNonce2)), rawNonce2);
    expect(refused.status).toBe(401);
  });
});
