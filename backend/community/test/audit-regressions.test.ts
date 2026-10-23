import { describe, test, expect } from "bun:test";
import { buildApp } from "../src/app.js";
import { validateRecipeRef } from "../src/core/validate.js";
import * as screening from "../src/core/screening.js";
import { AppleVerifier } from "../src/core/appleVerify.js";

const apple = { verify: async (token: string, nonce: string) => ({ appleSub: token.slice(9), nonce, email: null }) };
const recipe = {
  title: "Lemon pasta", description: null, servings: 2, timeMinutes: 15,
  ingredientLines: [{ name: "milk", quantity: 1, unit: "cup", preparation: null, fdcId: null }],
  steps: [{ text: "Cook until hot", timerMinutes: null }], equipment: [], dietaryTags: ["vegan"],
};
const body = (over: Record<string, unknown> = {}) => ({
  operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "r-1", revision: 1 },
  content: recipe, declaration: { ownRights: true, noPersonalData: true }, ...over,
});
async function signIn(app: Awaited<ReturnType<typeof buildApp>>, attest = true) {
  const response = await app.handle(new Request("https://api.test/v1/auth/apple", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: `stub-jwt-${crypto.randomUUID()}.x.y`, nonce: crypto.randomUUID(), ...(attest ? { attest18Plus: { birthYear: 1990 } } : {}) }),
  }));
  return (await response.json()) as { accessToken: string };
}
const auth = (token: string, body: unknown): RequestInit => ({ method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) });

describe("backend audit regressions", () => {
  test("finding 5: publication requires an adult attestation", async () => {
    const app = await buildApp({ apple });
    const user = await signIn(app, false);
    const response = await app.handle(new Request("https://api.test/v1/publications", auth(user.accessToken, body())));
    expect(response.status).toBe(403);
  });

  test("finding 11: Apple JWKS is cached and unknown kids do not refetch immediately", async () => {
    let fetches = 0;
    const verifier = new AppleVerifier({ config: { appleIssuer: "iss", appleBundleId: "aud", appleJwksUrl: "https://apple.test/keys" }, fetchJwks: async () => { fetches += 1; return { keys: [] }; } });
    const token = `${Buffer.from(JSON.stringify({ alg: "RS256", kid: "unknown" })).toString("base64url")}.${Buffer.from("{}").toString("base64url")}.x`;
    await expect(verifier.verify(token, "nonce", Date.now())).rejects.toThrow();
    await expect(verifier.verify(token, "nonce", Date.now())).rejects.toThrow();
    expect(fetches).toBe(1);
    fetches = 0;
    const delayed = new AppleVerifier({ config: { appleIssuer: "iss", appleBundleId: "aud", appleJwksUrl: "https://apple.test/keys" }, fetchJwks: async () => { fetches += 1; await Bun.sleep(10); return { keys: [] }; } });
    await Promise.all([delayed.verify(token, "nonce", Date.now()).catch(() => undefined), delayed.verify(token, "nonce", Date.now()).catch(() => undefined)]);
    expect(fetches).toBe(1);
  });

  test("auth flood protection does not count cheap malformed requests", async () => {
    const app = await buildApp({ apple });
    for (let i = 0; i < 61; i += 1) {
      const response = await app.handle(new Request("https://api.test/v1/auth/apple", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ identityToken: "bad", nonce: crypto.randomUUID() }) }));
      expect(response.status).toBe(422);
    }
    expect((await signIn(app)).accessToken).toMatch(/^fla1\./);
  });

  test("the Apple token limiter evicts old keys instead of blocking new tokens", async () => {
    const app = await buildApp({ apple });
    for (let i = 0; i < 10_000; i += 1) {
      const response = await app.handle(new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: `attacker-${i}.x.y`, nonce: "bad" }),
      }));
      expect(response.status).toBe(422);
    }

    const victim = await app.handle(new Request("https://api.test/v1/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ identityToken: "victim-token.x.y", nonce: "bad" }),
    }));
    expect(victim.status).toBe(422);

    const tracked = "tracked-token.x.y";
    for (let i = 0; i < 60; i += 1) {
      const response = await app.handle(new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: tracked, nonce: "bad" }),
      }));
      expect(response.status).toBe(422);
    }
    const limited = await app.handle(new Request("https://api.test/v1/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ identityToken: tracked, nonce: "bad" }),
    }));
    expect(limited.status).toBe(429);
  });

  test("finding 13: invalid reports do not consume report quota", async () => {
    const app = await buildApp({ apple });
    const user = await signIn(app);
    const created = await app.handle(new Request("https://api.test/v1/publications", auth(user.accessToken, body())));
    const publicationId = ((await created.json()) as { publicationId: string }).publicationId;
    const invalid = await app.handle(new Request("https://api.test/v1/reports", auth(user.accessToken, { targetType: "recipe", targetId: "pub_0000000000000000000000000000", reason: "other" })));
    expect(invalid.status).toBe(404);
    const validStatuses: number[] = [];
    for (let i = 0; i < 10; i += 1) {
      validStatuses.push((await app.handle(new Request("https://api.test/v1/reports", auth(user.accessToken, { targetType: "recipe", targetId: publicationId, reason: "other" })))).status);
    }
    expect(validStatuses.every((status) => status === 202)).toBe(true);
    const eleventh = await app.handle(new Request("https://api.test/v1/reports", auth(user.accessToken, { targetType: "recipe", targetId: publicationId, reason: "other" })));
    expect(eleventh.status).toBe(429);
  });

  test("finding 14: table creation is rate limited", async () => {
    const app = await buildApp({ apple });
    const user = await signIn(app);
    const invalid = await app.handle(new Request("https://api.test/v1/tables", auth(user.accessToken, { name: "" })));
    expect(invalid.status).toBe(422);
    const statuses: number[] = [];
    for (let i = 0; i < 20; i += 1) statuses.push((await app.handle(new Request("https://api.test/v1/tables", auth(user.accessToken, { name: `table-${i}` })))).status);
    expect(statuses.every((status) => status === 201)).toBe(true);
    const last = await app.handle(new Request("https://api.test/v1/tables", auth(user.accessToken, { name: "table-21" })));
    expect(last.status).toBe(429);
  });

  test("finding 15: recipe references reject oversized ids and UTF-8 bodies are capped", async () => {
    expect(() => validateRecipeRef({ source: "user", id: "x".repeat(129), revision: 1 })).toThrow();
    const app = await buildApp({ apple });
    const response = await app.handle(new Request("https://api.test/v1/auth/apple", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ identityToken: "é".repeat(140000), nonce: crypto.randomUUID() }) }));
    expect(response.status).toBe(422);
  });

  test("rejects an oversized chunked body before reading the whole stream", async () => {
    const app = await buildApp({ apple });
    let pulled = 0;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += 1;
        if (pulled <= 300) controller.enqueue(new Uint8Array(1024));
        else controller.close();
      },
      cancel() {
        cancelled = true;
      },
    });
    const response = await app.handle(new Request("https://api.test/v1/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    }));
    expect(response.status).toBe(422);
    expect(pulled).toBeLessThanOrEqual(258);
    expect(cancelled).toBe(true);
  });

  test("finding 17: contradictory diet tags are removed but unknown ingredients keep tags", () => {
    expect(typeof screening.dropContradictoryDietTags).toBe("function");
    const normalized = screening.dropContradictoryDietTags?.(recipe) ?? recipe;
    expect(normalized.dietaryTags).toEqual([]);
    const unknown = screening.dropContradictoryDietTags?.({ ...recipe, ingredientLines: [{ name: "grandmas secret blend", quantity: 1, unit: "cup", preparation: null, fdcId: null }] }) ?? recipe;
    expect(unknown.dietaryTags).toEqual(["vegan"]);
  });
});
