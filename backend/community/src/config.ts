/**
 * Environment-driven config (SPEC §7.4). No secrets in code; the Apple JWKS
 * is fetched, not vendored (tests inject a local test key set instead).
 *
 * Strict on purpose (deployment readiness): development defaults exist only
 * for development. A malformed numeric value fails the boot instead of
 * silently becoming the default, an unknown store name is an error rather
 * than a silent memory store, and production refuses any configuration that
 * would lose data (memory store) or skip screening — each error names the
 * variable that caused it.
 */

import { errServiceUnavailable } from "./core/errors.js";
import type { AppleVerifierConfig } from "./core/appleVerify.js";

export interface CommunityConfig extends AppleVerifierConfig {
  readonly port: number;
  readonly store: "memory" | "firestore";
  readonly firestoreProjectId: string;
  readonly sessionSecret: string;
  readonly accessTtlMinutes: number;
  readonly refreshTtlDays: number;
  /** Allowlisted operator account ids (SPEC §6.6); empty until Sam names one. */
  readonly operatorAccountIds: readonly string[];
  readonly communityBaseUrl: string;
  /**
   * Whether the food-safety lint and ingredient-facts packages are loaded.
   * When false the publish route fails closed with 503 (SPEC §2.3, PR #104).
   *
   * Readiness is measured, not configured: buildApp loads the reviewed canon
   * at startup and fails the boot loudly when it cannot (see
   * `loadIngredientFactsCanon`). COMMUNITY_SCREENING_LOADED=false stays only
   * as an explicit off-switch for tests — and is refused in production.
   */
  readonly screeningPackagesLoaded: boolean;
}

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.length === 0) {
    return fallback;
  }
  // A whole integer string only: Number.parseInt alone accepts prefixes
  // ("8087junk" -> 8087, "15days" -> 15), silently rewriting the value the
  // operator wrote (PR #219 review, Codex round).
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be a whole integer, got "${raw}"`);
  }
  return Number.parseInt(raw, 10);
}

function listEnv(name: string): readonly string[] {
  const raw = process.env[name];
  if (raw === undefined || raw.trim().length === 0) {
    return [];
  }
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function configFromEnv(): CommunityConfig {
  const production = (process.env.NODE_ENV ?? "") === "production";

  // Review finding 10: production must never boot on the development default.
  const sessionSecret = process.env.COMMUNITY_SESSION_SECRET;
  if (production && (sessionSecret === undefined || sessionSecret.length === 0)) {
    throw new Error("COMMUNITY_SESSION_SECRET must be set when NODE_ENV is production");
  }

  // A store nobody configured must not silently become "memory": an unknown
  // value used to fall through to the in-memory store, losing all data on
  // restart.
  const storeRaw = process.env.COMMUNITY_STORE;
  let store: "memory" | "firestore";
  if (storeRaw === undefined || storeRaw.length === 0) {
    store = "memory";
  } else if (storeRaw === "memory" || storeRaw === "firestore") {
    store = storeRaw;
  } else {
    throw new Error(`COMMUNITY_STORE must be "memory" or "firestore", got "${storeRaw}"`);
  }
  if (production && store === "memory") {
    throw new Error(
      'NODE_ENV=production refuses COMMUNITY_STORE=memory: in-memory data is lost on restart; set COMMUNITY_STORE=firestore',
    );
  }

  // Screening readiness is measured at startup (buildApp →
  // loadIngredientFactsCanon); the environment can only switch screening off
  // explicitly, and production never boots with it off.
  if (production && (process.env.COMMUNITY_SCREENING_LOADED ?? "true") === "false") {
    throw new Error(
      "COMMUNITY_SCREENING_LOADED=false is refused when NODE_ENV is production: community publications must be screened",
    );
  }

  if (production) {
    for (const name of ["FIRESTORE_PROJECT_ID", "COMMUNITY_BASE_URL", "APPLE_BUNDLE_ID"] as const) {
      const raw = process.env[name];
      if (raw === undefined || raw.length === 0) {
        throw new Error(`${name} must be set when NODE_ENV is production`);
      }
    }
  }

  return {
    port: intEnv("PORT", 8087),
    store,
    firestoreProjectId: process.env.FIRESTORE_PROJECT_ID ?? "fridgeluck-community-dev",
    sessionSecret: sessionSecret ?? "dev-only-insecure-secret",
    accessTtlMinutes: intEnv("COMMUNITY_ACCESS_TTL_MINUTES", 15),
    refreshTtlDays: intEnv("COMMUNITY_REFRESH_TTL_DAYS", 30),
    operatorAccountIds: listEnv("OPERATOR_ACCOUNT_IDS"),
    communityBaseUrl: process.env.COMMUNITY_BASE_URL ?? "https://community.fridgeluck.dev",
    appleIssuer: process.env.APPLE_ISSUER ?? "https://appleid.apple.com",
    appleBundleId: process.env.APPLE_BUNDLE_ID ?? "dev.fridgeluck.app",
    appleJwksUrl: process.env.APPLE_JWKS_URL ?? "https://appleid.apple.com/auth/keys",
    screeningPackagesLoaded: (process.env.COMMUNITY_SCREENING_LOADED ?? "true") !== "false",
  };
}

export function operatorLookup(config: CommunityConfig): (accountId: string) => boolean {
  const allowlist = new Set(config.operatorAccountIds);
  return (accountId: string) => allowlist.has(accountId);
}

/** Publish path guard: the food-safety gate is fail-closed. */
export function assertScreeningAvailable(config: CommunityConfig): void {
  if (!config.screeningPackagesLoaded) {
    throw errServiceUnavailable("screening packages are unloaded; nothing was published");
  }
}
