/**
 * Application assembly: wires config, the store seam, the ported services,
 * and the discovered modules into one request handler. Both the production
 * server (server.ts) and the test harness (test/api/helpers) boot through
 * this function, so tests exercise exactly the production wiring.
 */

import { SystemClock, type Clock } from "./core/time.js";
import { SessionCore } from "./core/sessionCore.js";
import { AppleVerifier } from "./core/appleVerify.js";
import { ScreeningPipeline } from "./core/screening.js";
import { MemoryStore } from "./core/store/memory.js";
import { openFirestoreStore } from "./core/store/firestore.js";
import type { DocumentStore } from "./core/store/documentStore.js";
import { discoverModules, type DiscoveredModule, type ModuleContext } from "./core/moduleLoader.js";
import { dispatch, matchRoute } from "./core/router.js";
import type { Router } from "./core/router.js";
import { configFromEnv, operatorLookup, type CommunityConfig } from "./config.js";
import { join, dirname } from "node:path";

export interface App {
  readonly config: CommunityConfig;
  readonly store: DocumentStore;
  readonly clock: Clock;
  readonly modules: readonly DiscoveredModule[];
  readonly routes: Router;
  handle(request: Request): Promise<Response>;
}

export async function buildApp(overrides?: {
  config?: Partial<CommunityConfig>;
  store?: DocumentStore;
  clock?: Clock;
  modulesDir?: string;
  /** Test seam: the production verifier fetches Apple's JWKS over the network. */
  apple?: Pick<AppleVerifier, "verify">;
}): Promise<App> {
  const config: CommunityConfig = { ...configFromEnv(), ...overrides?.config };
  const clock = overrides?.clock ?? new SystemClock();
  const store: DocumentStore = overrides?.store ?? (config.store === "firestore" ? await openFirestoreStore(config.firestoreProjectId) : new MemoryStore());
  const sessions = new SessionCore({ store, config, clock });
  const apple = overrides?.apple ?? new AppleVerifier({ config });
  const screening = new ScreeningPipeline(config.screeningPackagesLoaded);
  const isOperator = operatorLookup(config);

  const modulesDir = overrides?.modulesDir ?? join(dirname(import.meta.dir), "src", "modules");
  const modules = await discoverModules(modulesDir);

  const ctx: ModuleContext = { config, store, clock, sessions, apple, screening, isOperator };
  const routes: Router = modules.flatMap((m) => m.definition.routes(ctx));

  const handle = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") {
      return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (!url.pathname.startsWith("/v1/") && url.pathname !== "/v1") {
      return new Response(JSON.stringify({ error: { code: "not_found", message: "not a community API path" } }), {
        status: 404,
        headers: { "content-type": "application/json" },
      });
    }
    const apiPath = url.pathname.slice(3); // strip "/v1"
    let accountId: string | null = null;
    let sessionId: string | null = null;
    const auth = request.headers.get("authorization");
    if (auth !== null && auth.startsWith("Bearer ")) {
      try {
        const verified = await sessions.verifyAccess(auth.slice(7).trim());
        accountId = verified.accountId;
        sessionId = verified.sessionId;
      } catch {
        accountId = null;
        sessionId = null;
      }
    }
    let body: unknown = undefined;
    if (request.method !== "GET" && request.method !== "DELETE") {
      const text = await request.text();
      if (text.length > 0) {
        try {
          body = JSON.parse(text);
        } catch {
          body = undefined;
        }
      }
    }
    return dispatch(routes, request.method, apiPath, url.searchParams, body, accountId, sessionId);
  };

  return { config, store, clock, modules, routes, handle };
}

/** Test/inspection helper: whether a path matches any route (used by the discovery test). */
export function hasRouteFor(app: App, method: string, path: string): boolean {
  return matchRoute(app.routes, method, path) !== null;
}
