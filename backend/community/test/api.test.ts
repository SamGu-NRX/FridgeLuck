/**
 * End-to-end tests over exactly the production wiring: buildApp with the
 * in-memory store, a stubbed Apple verifier, and a fake clock. Request-level
 * assertions against the OpenAPI routes, including the error envelope.
 */

import { describe, test, expect, beforeAll } from "bun:test";
import { buildApp, type App } from "../src/app.js";
import type { AppleIdentityTokenClaims } from "../src/core/appleVerify.js";

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
    expect(data.items[0]?.allergenTags).toEqual(["milk", "wheat"]); // contract card: candidates and freshness only; ranking stays on the phone
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

  test("dismiss leaves the publication in its current state (the author decides re-publication)", async () => {
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
    expect(states).toContain("queued"); // unchanged; only the author's corrected revision re-publishes
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
