/**
 * Identity module (SPEC §6.1–6.2): sign in with Apple over server-issued
 * sessions. The client generates a nonce, binds it into the Apple sign-in,
 * and exchanges the identity JWS for `fla1.`/`flr1.` tokens. The Apple `sub`
 * is the only identity; the Apple email never enters the community store.
 * The 18+ attestation is first-write-wins (SPEC §6.2).
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import { errUnauthorized, errValidation, isCommunityError } from "../../core/errors.js";
import { readObject, readString, requireAccount } from "../../core/http.js";
import { accountIdShape } from "../../core/ids.js";
import { isUuid } from "../../core/validate.js";
import { accountView } from "./views.js";
import { ACCOUNTS_COLLECTION, NONCES_COLLECTION } from "./collectionNames.js";

const IDENTITIES_COLLECTION = "identities"; // appleSub → accountId; never served anywhere

const identityModule: ModuleDefinition = {
  name: "identity",
  version: 1,
  routes: (ctx) => [
    {
      method: "POST",
      pattern: "/auth/apple",
      handler: async (req) => {
        const body = readObject(req);
        const identityToken = readString(body, "identityToken");
        if (identityToken === null || identityToken.length < 8) {
          throw errValidation("validation", "field identityToken must be the Apple identity JWS");
        }
        const nonce = readString(body, "nonce");
        if (nonce === null || !isUuid(nonce)) {
          throw errValidation("validation", "field nonce must be a client-generated UUID");
        }
        const attest = body["attest18Plus"];
        let birthYear: number | null = null;
        if (attest !== undefined && attest !== null) {
          if (typeof attest !== "object" || attest === null || Array.isArray(attest)) {
            throw errValidation("validation", "attest18Plus must be an object with birthYear");
          }
          const raw = (attest as Record<string, unknown>)["birthYear"];
          if (!Number.isInteger(raw) || (raw as number) < 1900 || (raw as number) > 2100) {
            throw errValidation("validation", "attest18Plus.birthYear must be an integer of 1900-2100");
          }
          birthYear = raw as number;
        }

        const now = ctx.clock.now();
        // The nonce is client-generated; first use wins and reuse is refused
        // (requests.schema.json: "must not have been seen before").
        const claims = await ctx.store.runTransaction(async (tx) => {
          const nonceRef = tx.collection(NONCES_COLLECTION).doc(nonce);
          const nonceSnap = await nonceRef.get();
          if (nonceSnap.data !== null) {
            throw errUnauthorized("nonce has already been used");
          }
          await nonceRef.create({ createdAt: now.toISOString(), consumed: true });
          try {
            return await ctx.apple.verify(identityToken, nonce, now.getTime());
          } catch (error) {
            if (isCommunityError(error)) {
              throw error;
            }
            // Apple refused the token (bad signature, unknown key, ...).
            throw errUnauthorized("Apple rejected the identity token");
          }
        });

        const identities = ctx.store.collection(IDENTITIES_COLLECTION);
        const accounts = ctx.store.collection(ACCOUNTS_COLLECTION);
        const identitySnap = await identities.doc(claims.appleSub).get();
        let accountId: string;
        if (identitySnap.data === null) {
          accountId = accountIdShape.newId();
          await accounts.doc(accountId).create({
            displayName: "Cook",
            createdAt: now.toISOString(),
            ...(birthYear !== null ? { attested18PlusAtIso: now.toISOString(), birthYear } : {}),
          });
          await identities.doc(claims.appleSub).create({ accountId });
        } else {
          const storedId = identitySnap.data["accountId"];
          if (typeof storedId !== "string") {
            throw errUnauthorized("stored identity is malformed");
          }
          accountId = accountIdShape.validate(storedId);
          const accountSnap = await accounts.doc(accountId).get();
          if (accountSnap.data === null) {
            throw errUnauthorized("account no longer exists");
          }
          if (typeof accountSnap.data["deletionStartedAtIso"] === "string" || typeof accountSnap.data["deletedAtIso"] === "string") {
            throw errUnauthorized("account is deleted or deletion is in progress");
          }
          if (birthYear !== null && typeof accountSnap.data["attested18PlusAtIso"] !== "string") {
            // First-write-wins (SPEC §6.2): a later attestation never overwrites.
            await accounts.doc(accountId).update({ attested18PlusAtIso: now.toISOString(), birthYear });
          }
        }

        const tokens = await ctx.sessions.issue(accountId);
        const accountData = (await accounts.doc(accountId).get()).data;
        return json(200, {
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          account: accountView(accountId, accountData, ctx.isOperator(accountId), now.getTime()),
        });
      },
    },
    {
      method: "POST",
      pattern: "/auth/refresh",
      handler: async (req) => {
        const body = readObject(req);
        const refreshToken = readString(body, "refreshToken");
        if (refreshToken === null || !refreshToken.startsWith("flr1.")) {
          throw errValidation("validation", "field refreshToken must be a flr1. refresh token");
        }
        const tokens = await ctx.sessions.rotate(refreshToken);
        const accountData = (await ctx.store.collection(ACCOUNTS_COLLECTION).doc(tokens.accountId).get()).data;
        return json(200, {
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          account: accountView(tokens.accountId, accountData, ctx.isOperator(tokens.accountId), ctx.clock.now().getTime()),
        });
      },
    },
    {
      method: "DELETE",
      pattern: "/session",
      handler: async (req) => {
        if (req.sessionId === null) {
          throw errUnauthorized("authentication required");
        }
        await ctx.sessions.revoke(req.sessionId);
        return { status: 204 };
      },
    },
    {
      method: "GET",
      pattern: "/me",
      handler: async (req) => {
        const accountId = requireAccount(req);
        const data = (await ctx.store.collection(ACCOUNTS_COLLECTION).doc(accountId).get()).data;
        if (data === null) {
          throw errUnauthorized("account no longer exists");
        }
        return json(200, accountView(accountId, data, ctx.isOperator(accountId), ctx.clock.now().getTime()));
      },
    },
    {
      method: "PATCH",
      pattern: "/me",
      handler: async (req) => {
        const accountId = requireAccount(req);
        const body = readObject(req);
        const displayName = readString(body, "displayName");
        if (displayName === null || displayName.length < 1 || displayName.length > 24) {
          throw errValidation("validation", "displayName must be a string of 1-24 characters");
        }
        await ctx.store.collection(ACCOUNTS_COLLECTION).doc(accountId).update({ displayName });
        return json(200, accountView(accountId, { displayName }, ctx.isOperator(accountId), ctx.clock.now().getTime()));
      },
    },
    {
      method: "DELETE",
      pattern: "/account",
      handler: async (req) => {
        const accountId = requireAccount(req);
        // Resumable deletion plan (SPEC §6.4): sign-ins and refreshes refuse
        // from this instant; publication/table sweeps are follow-up work.
        await ctx.sessions.blockForDeletion(accountId, ctx.clock.now().toISOString());
        return { status: 202 };
      },
    },
  ],
};

export default identityModule;
