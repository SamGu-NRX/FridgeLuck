/**
 * The single place a CommunityError becomes an HTTP response.
 *
 * Every community route handler is wrapped with `route`: business logic throws,
 * the boundary answers. Request handlers receive `req.community` (set by
 * requireAccount) as the only source of the caller's account id — a
 * caller-supplied owner id in a body or query is ignored everywhere.
 */
import type { NextFunction, Request, RequestHandler, Response } from "express";
import { isCommunityError } from "./errors.js";
import type { AccountId, SessionId } from "./ids.js";
import { parseAccountId, parseSessionId } from "./ids.js";
import { errUnauthorized } from "./errors.js";

declare module "express-serve-static-core" {
  interface Request {
    community?: CommunityContext;
  }
}

export interface CommunityContext {
  readonly accountId: AccountId;
  readonly sessionId: SessionId;
}

export function mustCommunity(req: Request): CommunityContext {
  const ctx = req.community;
  if (!ctx) {
    // Only reachable if a route skipped requireAccount — a wiring bug, not a
    // client error.
    throw errUnauthorized("authentication is required for this route");
  }
  return ctx;
}

export type CommunityHandler = (
  req: Request,
  res: Response,
) => Promise<void>;

export function route(handler: CommunityHandler): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    handler(req, res).catch((error: unknown) => {
      if (isCommunityError(error)) {
        res.status(error.status).json({ error: error.message, code: error.code });
        return;
      }
      console.log(
        JSON.stringify({
          severity: "ERROR",
          message: "community_unhandled_error",
          detail: error instanceof Error ? error.message : String(error),
        }),
      );
      res.status(500).json({ error: "internal error", code: "internal" });
    });
  };
}

/** Reads the raw bearer token, or null. Boundary of the auth boundary. */
export function readBearer(req: Request): string | null {
  const header = req.headers.authorization;
  if (typeof header !== "string") {
    return null;
  }
  const match = /^Bearer ([A-Za-z0-9._-]+)$/.exec(header);
  return match ? (match[1] as string) : null;
}

/** Narrows an account id that arrived inside an already-verified token. */
export function verifiedAccountId(raw: string): AccountId {
  return parseAccountId.parse(raw, "verified token subject");
}
export function verifiedSessionId(raw: string): SessionId {
  return parseSessionId.parse(raw, "verified token session");
}
