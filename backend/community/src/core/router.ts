/**
 * The route table and request plumbing. Deliberately tiny: Bun.serve's fetch
 * handles HTTP; this adds path params, an auth context, and the error
 * envelope from contracts/error.schema.json — nothing more.
 */

import { isCommunityError, CommunityError } from "./errors.js";
import type { ErrorView } from "./contract.js";

export interface RequestContext {
  readonly params: Readonly<Record<string, string>>;
  readonly query: Readonly<URLSearchParams>;
  readonly body: unknown;
  /** Account id when a valid `Authorization: Bearer <fla1.>` was presented; null otherwise. */
  readonly accountId: string | null;
  /** Session id behind the presented token (DELETE /session revokes it); null unauthenticated. */
  readonly sessionId: string | null;
}

export interface RouteDefinition {
  readonly method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  /** Pattern with `:name` segments, e.g. "/publications/:publicationId". */
  readonly pattern: string;
  handler(ctx: RequestContext): Promise<ResponseLike>;
}

/** Minimal response shape so handlers stay testable without the socket. */
export interface ResponseLike {
  readonly status: number;
  readonly json?: unknown;
  readonly headers?: Readonly<Record<string, string>>;
}

export type Router = readonly RouteDefinition[];

export function json(status: number, body: unknown, headers?: Readonly<Record<string, string>>): ResponseLike {
  return { status, json: body, headers };
}

export function noContent(): ResponseLike {
  return { status: 204 };
}

export function errorResponse(error: unknown): { status: number; body: ErrorView } {
  if (isCommunityError(error)) {
    return {
      status: error.status,
      body: {
        error: {
          code: error.code,
          message: error.message,
          ...(error.reason !== null ? { reason: error.reason } : {}),
        },
      },
    };
  }
  const message = error instanceof Error ? error.message : "unexpected error";
  return { status: 500, body: { error: { code: "internal", message } } };
}

export function matchRoute(
  routes: Router,
  method: string,
  path: string,
): { readonly route: RouteDefinition; readonly params: Record<string, string> } | null {
  const pathSegments = path.split("/").filter((s) => s.length > 0);
  for (const route of routes) {
    if (route.method !== method) {
      continue;
    }
    const patternSegments = route.pattern.split("/").filter((s) => s.length > 0);
    if (patternSegments.length !== pathSegments.length) {
      continue;
    }
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < patternSegments.length; i += 1) {
      const pattern = patternSegments[i];
      const actual = pathSegments[i];
      if (pattern === undefined || actual === undefined) {
        ok = false;
        break;
      }
      if (pattern.startsWith(":")) {
        params[pattern.slice(1)] = decodeURIComponent(actual);
      } else if (pattern !== actual) {
        ok = false;
        break;
      }
    }
    if (ok) {
      return { route, params };
    }
  }
  return null;
}

/** Turns a handler outcome (or a thrown CommunityError) into a fetch Response. */
export async function dispatch(
  routes: Router,
  method: string,
  path: string,
  query: URLSearchParams,
  body: unknown,
  accountId: string | null,
  sessionId: string | null = null,
): Promise<Response> {
  try {
    const match = matchRoute(routes, method, path);
    if (match === null) {
      throw new CommunityError(404, "not_found", `no route for ${method} ${path}`);
    }
    const result = await match.route.handler({
      params: match.params,
      query,
      body,
      accountId,
      sessionId,
    });
    const headers = new Headers(result.headers);
    if (result.json !== undefined) {
      headers.set("content-type", "application/json");
      return new Response(JSON.stringify(result.json), { status: result.status, headers });
    }
    return new Response(null, { status: result.status, headers });
  } catch (error) {
    const mapped = errorResponse(error);
    return new Response(JSON.stringify(mapped.body), {
      status: mapped.status,
      headers: { "content-type": "application/json" },
    });
  }
}
