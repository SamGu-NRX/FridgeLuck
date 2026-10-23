/**
 * Round-trip harness: boots exactly the production wiring (src/app.ts) over a
 * swappable store — MemoryStore for the unit tier, the Firestore adapter
 * against the emulator for the integration tier — with a stubbed Apple
 * verifier and a movable clock so lifecycle states (24 h vote age, entry and
 * voting windows) are reachable deterministically.
 */

import { buildApp, type App } from "../../src/app.js";
import type { Clock } from "../../src/core/time.js";
import type { AppleIdentityTokenClaims } from "../../src/core/appleVerify.js";
import { exampleRequest } from "./requests.js";

/** Deterministic suite origin so UTC-day rate-limit keys and lifecycle windows are stable. */
export const BASE_MS = Date.parse("2026-10-15T16:00:00Z");

export class FakeClock implements Clock {
  private ms: number = BASE_MS;
  now(): Date {
    return new Date(this.ms);
  }
  advance(hours: number): void {
    this.ms += hours * 60 * 60 * 1000;
  }
}

/** Allowlist operator account id, seeded before sign-in (pattern per common.schema.json). */
export const OPERATOR_ACCOUNT_ID = "acc_operator00000";
export const OPERATOR_APPLE_SUB = "operator-identity-sub";

/** Maps a stub identity token to an Apple sub; anything unknown is refused. */
const stubApple = {
  verify: async (identityToken: string, nonce: string, nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("rejected by Apple");
    }
    return { appleSub: identityToken.slice("stub-jwt-".length), nonce, email: "nobody@privaterelay.appleid.com" };
  },
};

export interface ContractHarness {
  readonly app: App;
  readonly clock: FakeClock;
}

export type StoreSelection = { readonly kind: "memory" } | { readonly kind: "firestore"; readonly projectId: string };

export type HarnessOptions = { readonly screeningPackagesLoaded?: boolean };

export async function buildHarness(store: StoreSelection, options: HarnessOptions = {}): Promise<ContractHarness> {
  const clock = new FakeClock();
  const app = await buildApp({
    apple: stubApple,
    clock,
    config:
      store.kind === "firestore"
        ? {
            store: "firestore",
            firestoreProjectId: store.projectId,
            operatorAccountIds: [OPERATOR_ACCOUNT_ID],
            ...(options.screeningPackagesLoaded !== undefined ? { screeningPackagesLoaded: options.screeningPackagesLoaded } : {}),
          }
        : {
            operatorAccountIds: [OPERATOR_ACCOUNT_ID],
            ...(options.screeningPackagesLoaded !== undefined ? { screeningPackagesLoaded: options.screeningPackagesLoaded } : {}),
          },
  });
  // The operator's account is seeded directly (env allowlists name a known id in
  // production); sign-in then resolves through the normal identity lookup.
  await app.store.collection("identities").doc(OPERATOR_APPLE_SUB).set({ accountId: OPERATOR_ACCOUNT_ID });
  await app.store.collection("accounts").doc(OPERATOR_ACCOUNT_ID).set({
    displayName: "Mod",
    createdAt: clock.now().toISOString(),
  });
  return { app, clock };
}

export interface Session {
  readonly token: string;
  readonly refreshToken: string;
  readonly accountId: string;
}

export function api(
  app: App,
  method: string,
  path: string,
  init: { token?: string; body?: unknown } = {},
): Promise<Response> {
  const headers: Record<string, string> = {};
  if (init.token !== undefined) {
    headers["authorization"] = `Bearer ${init.token}`;
  }
  const hasBody = init.body !== undefined && method !== "GET" && method !== "DELETE";
  if (hasBody) {
    headers["content-type"] = "application/json";
  }
  return app.handle(
    new Request(`https://api.test/v1${path}`, {
      method,
      headers,
      ...(hasBody ? { body: JSON.stringify(init.body) } : {}),
    }),
  );
}

export async function signIn(harness: ContractHarness, sub: string, opts: { attestedBirthYear?: number } = {}): Promise<Session> {
  const body = {
    ...exampleRequest("authApple"),
    identityToken: `stub-jwt-${sub}`,
    nonce: crypto.randomUUID(),
    attest18Plus: { birthYear: opts.attestedBirthYear ?? 1990 },
  };
  const response = await api(harness.app, "POST", "/auth/apple", { body });
  if (response.status !== 200) {
    throw new Error(`signIn(${sub}) failed: ${response.status} ${await response.text()}`);
  }
  const data = (await response.json()) as { accessToken: string; refreshToken: string; account: { accountId: string } };
  return { token: data.accessToken, refreshToken: data.refreshToken, accountId: data.account.accountId };
}

export async function jsonBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) {
    return undefined;
  }
  return JSON.parse(text) as unknown;
}

/** Publishes one revision for the caller and returns its publication id (201 expected). */
export async function publishRevision(
  harness: ContractHarness,
  session: Session,
  recipeRef: { source: string; id: string; revision: number },
  overrides: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const body = {
    ...exampleRequest("createPublication"),
    operationId: crypto.randomUUID(),
    recipeRef,
    ...overrides,
  };
  const response = await api(harness.app, "POST", "/publications", { token: session.token, body });
  if (response.status !== 201) {
    throw new Error(`publishRevision(${recipeRef.id}@${recipeRef.revision}) failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as Record<string, unknown>;
}

/**
 * Publication content every line of which the reviewed canon adjudicates
 * (PR #219 review). The committed contract example's lines (butter beans,
 * curry powder) are not in the reviewed canon, so since #224 they publish
 * queued — unknown-contents held from Explore pending review. Reader-view
 * flows need a published record, so they publish this content instead; the
 * example request keeps replaying verbatim in its own test.
 */
export const resolvedPublicationContent = {
  title: "Weeknight pasta for two",
  description: "A quick pantry dinner.",
  servings: 2,
  timeMinutes: 15,
  ingredientLines: [
    { name: "milk", quantity: 200, unit: "ml", preparation: null, fdcId: null },
    { name: "all-purpose flour", quantity: 250, unit: "g", preparation: null, fdcId: null },
    { name: "onion", quantity: 1, unit: "piece", preparation: "finely chopped", fdcId: null },
  ],
  steps: [{ text: "Boil, then simmer everything together for ten minutes.", timerMinutes: 10 }],
  equipment: ["pan"],
  dietaryTags: ["vegetarian"],
} as const;
