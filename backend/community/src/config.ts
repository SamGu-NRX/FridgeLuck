/**
 * Environment-driven config (SPEC §7.4). No secrets in code; the Apple JWKS
 * is fetched, not vendored (tests inject a local test key set instead).
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
   */
  readonly screeningPackagesLoaded: boolean;
}

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.length === 0) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
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
  return {
    port: intEnv("PORT", 8087),
    store: (process.env.COMMUNITY_STORE ?? "memory") === "firestore" ? "firestore" : "memory",
    firestoreProjectId: process.env.FIRESTORE_PROJECT_ID ?? "fridgeluck-community-dev",
    sessionSecret: process.env.COMMUNITY_SESSION_SECRET ?? "dev-only-insecure-secret",
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
