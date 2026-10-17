/**
 * The account boundary: every community route that touches user data runs
 * behind requireAccount, which is the ONLY source of the caller's identity.
 * The account id comes from the verified access token plus its live session
 * record — never from a body, query, or header the client controls.
 */
import type { RequestHandler } from "express";
import { readBearer, type CommunityContext } from "./http.js";
import { errUnauthorized } from "./errors.js";
import type { Clock } from "./time.js";
import type { SessionService } from "./sessionCore.js";

export interface RequireAccountDeps {
  readonly sessions: SessionService;
  readonly clock: Clock;
}

export function requireAccount(deps: RequireAccountDeps): RequestHandler {
  return (req, _res, next) => {
    const bearer = readBearer(req);
    if (bearer === null) {
      next(errUnauthorized("a community access token is required"));
      return;
    }
    deps.sessions
      .verifyAccess(bearer, deps.clock)
      .then((verified: { accountId: CommunityContext["accountId"]; sessionId: CommunityContext["sessionId"] }) => {
        req.community = verified;
        next();
      })
      .catch(next);
  };
}
