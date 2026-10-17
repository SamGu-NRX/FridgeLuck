/**
 * Community module configuration, parsed once at the boundary from
 * environment-style input. Deliberately separate from src/config.ts: the
 * integration task owns that file; this module ships its own surface and
 * `createCommunityRouter` is mounted by a later task.
 */
import { errValidation } from "./shared/errors.js";
import { expectInt, expectString } from "./shared/parse.js";

export interface CommunityConfig {
  readonly projectId: string;
  /** e.g. "127.0.0.1:8080". Set for the Firestore emulator. */
  readonly emulatorHost: string | null;
  /** HMAC key for community access tokens. Required unless the emulator is on. */
  readonly sessionSecret: string | null;
  readonly accessTtlMinutes: number;
  readonly refreshTtlDays: number;
  /** Sign in with Apple: issuer, audience (services id) and published JWKS URL. */
  readonly appleIssuer: string;
  readonly appleServicesId: string;
  readonly appleJwksUrl: string;
  /** SPEC 6 / mock: "cooked by N" appears only above this many distinct opted-in cooks. */
  readonly minCookedCountFloor: number;
  /** Campus counts appear only above this many distinct people (review finding 10). */
  readonly minDistinctPeopleForCampusCounts: number;
  /** Tables are 2–8 (SPEC 6.4). */
  readonly tableMinSize: number;
  readonly tableMaxSize: number;
  /** Report-abuse limit: reports per reporter per rolling day. */
  readonly reportLimitPerDay: number;
}

export const COMMUNITY_DEFAULTS = {
  accessTtlMinutes: 15,
  refreshTtlDays: 30,
  appleIssuer: "https://appleid.apple.com",
  appleJwksUrl: "https://appleid.apple.com/auth/keys",
  minCookedCountFloor: 10,
  minDistinctPeopleForCampusCounts: 5,
  tableMinSize: 2,
  tableMaxSize: 8,
  reportLimitPerDay: 10,
} as const;

export function loadCommunityConfig(env: Record<string, string | undefined>): CommunityConfig {
  const emulatorHost = env["FIRESTORE_EMULATOR_HOST"] ?? null;
  const projectId = expectString(env["GOOGLE_CLOUD_PROJECT"] ?? env["COMMUNITY_PROJECT_ID"] ?? "fridgeluck-community", "project id");
  const sessionSecret = env["COMMUNITY_SESSION_SECRET"] ?? null;
  if (sessionSecret === null && emulatorHost === null) {
    throw errValidation("COMMUNITY_SESSION_SECRET is required outside the emulator");
  }
  const optionalInt = (raw: string | undefined, field: string, min: number): number | undefined => {
    if (raw === undefined) {
      return undefined;
    }
    const parsed = expectInt(Number(raw), field, { min });
    return parsed;
  };
  const accessTtlMinutes = optionalInt(env["COMMUNITY_ACCESS_TTL_MINUTES"], "access ttl", 1) ?? COMMUNITY_DEFAULTS.accessTtlMinutes;
  const refreshTtlDays = optionalInt(env["COMMUNITY_REFRESH_TTL_DAYS"], "refresh ttl", 1) ?? COMMUNITY_DEFAULTS.refreshTtlDays;
  const minCookedCountFloor = optionalInt(env["COMMUNITY_MIN_COOKED_FLOOR"], "cooked floor", 1) ?? COMMUNITY_DEFAULTS.minCookedCountFloor;
  const minDistinctPeople = optionalInt(env["COMMUNITY_MIN_CAMPUS_PEOPLE"], "campus floor", 1) ?? COMMUNITY_DEFAULTS.minDistinctPeopleForCampusCounts;
  const reportLimitPerDay = optionalInt(env["COMMUNITY_REPORT_LIMIT_PER_DAY"], "report limit", 1) ?? COMMUNITY_DEFAULTS.reportLimitPerDay;
  return {
    projectId,
    emulatorHost,
    sessionSecret,
    accessTtlMinutes,
    refreshTtlDays,
    appleIssuer: env["COMMUNITY_APPLE_ISSUER"] ?? COMMUNITY_DEFAULTS.appleIssuer,
    appleServicesId: expectString(env["COMMUNITY_APPLE_SERVICES_ID"] ?? "com.fridgeluck.app", "apple services id"),
    appleJwksUrl: env["COMMUNITY_APPLE_JWKS_URL"] ?? COMMUNITY_DEFAULTS.appleJwksUrl,
    minCookedCountFloor,
    minDistinctPeopleForCampusCounts: minDistinctPeople,
    tableMinSize: COMMUNITY_DEFAULTS.tableMinSize,
    tableMaxSize: COMMUNITY_DEFAULTS.tableMaxSize,
    reportLimitPerDay,
  };
}
