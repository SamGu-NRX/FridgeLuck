/**
 * Identity and session routes (part: identity).
 *
 * POST /v1/community/auth/apple    sign in / sign up with an Apple identity token
 * POST /v1/community/auth/refresh  rotate a refresh token
 * POST /v1/community/auth/logout   revoke the caller's session
 * GET  /v1/community/me            the caller's own profile (minimal fields)
 *
 * The 18+ eligibility attestation (SPEC 3.4) is recorded at sign-in when the
 * client sends attested18Plus:true; sharing routes check it server-side.
 */
import { Router } from "express";
import type { CommunityDeps } from "../index.js";
import type { CommunityRuntime } from "../index.js";
import { errUnauthorized, errValidation } from "../shared/errors.js";
import { expectBoolean, expectOptionalString, expectString } from "../shared/parse.js";
import { mustCommunity, route } from "../shared/http.js";
import { AppleVerifier } from "./appleVerify.js";
import { findOrCreateAccountByAppleSub } from "./accounts.js";

interface AppleSignInBody {
  readonly identityToken: string;
  readonly nonce: string;
  readonly attested18Plus: boolean;
}

function parseAppleSignInBody(raw: Record<string, unknown>): AppleSignInBody {
  return {
    identityToken: expectString(raw["identityToken"], "identityToken", { min: 16, max: 8192 }),
    nonce: expectString(raw["nonce"], "nonce", { min: 8, max: 256 }),
    attested18Plus: expectBoolean(raw["attested18Plus"] ?? false, "attested18Plus"),
  };
}

export function createIdentityRoutes(deps: CommunityDeps, runtime: CommunityRuntime): Router {
  const verifier = new AppleVerifier({ config: deps.config });
  const router = Router();

  router.post(
    "/v1/community/auth/apple",
    route(async (req, res) => {
      const raw = (req.body ?? {}) as Record<string, unknown>;
      if (typeof req.body !== "object" || req.body === null) {
        throw errValidation("a JSON body is required");
      }
      const body = parseAppleSignInBody(raw);
      const verified = await verifier.verify(body.identityToken, body.nonce, deps.clock.now().getTime());
      const account = await findOrCreateAccountByAppleSub(
        { accounts: deps.store.accounts, clock: deps.clock },
        verified.appleSub,
        verified.email,
        body.attested18Plus,
      );
      const tokens = await runtime.sessions.issue(account.accountId, deps.clock);
      res.status(200).json({
        accountId: account.accountId,
        isNewAccount: account.isNew,
        ...tokens,
      });
    }),
  );

  router.post(
    "/v1/community/auth/refresh",
    route(async (req, res) => {
      const raw = (req.body ?? {}) as Record<string, unknown>;
      if (typeof raw["refreshToken"] !== "string") {
        throw errValidation("refreshToken is required");
      }
      const tokens = await runtime.sessions.rotate(raw["refreshToken"], deps.clock);
      res.status(200).json(tokens);
    }),
  );

  router.post(
    "/v1/community/auth/logout",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      await runtime.sessions.revoke(ctx.sessionId, deps.clock);
      res.status(204).send();
    }),
  );

  router.get(
    "/v1/community/me",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const snap = await deps.store.accounts.doc(ctx.accountId).get();
      if (!snap.exists) {
        throw errUnauthorized("account record missing");
      }
      const data = snap.data() as Record<string, unknown> | undefined;
      if (data === undefined) {
        throw errUnauthorized("account record missing");
      }
      const attestedAt = typeof data["attested18PlusAt"] === "string" ? (data["attested18PlusAt"] as string) : null;
      res.status(200).json({
        accountId: ctx.accountId,
        attested18PlusAt: attestedAt,
        displayName: expectOptionalString(data["displayName"], "displayName", { max: 64 }) ?? null,
      });
    }),
  );

  return router;
}
