/**
 * Strict config (deployment readiness): a malformed numeric value, an unknown
 * store name, or a production boot that would lose data or skip screening
 * fails loudly with the variable named — never a silent fallback.
 */

import { afterEach, describe, expect, test } from "bun:test";
import { configFromEnv } from "../src/config.js";

const TOUCHED = [
  "NODE_ENV",
  "COMMUNITY_SESSION_SECRET",
  "COMMUNITY_STORE",
  "COMMUNITY_SCREENING_LOADED",
  "PORT",
  "COMMUNITY_ACCESS_TTL_MINUTES",
  "COMMUNITY_REFRESH_TTL_DAYS",
  "FIRESTORE_PROJECT_ID",
  "COMMUNITY_BASE_URL",
  "APPLE_BUNDLE_ID",
];

const saved = new Map<string, string | undefined>();

function setEnv(values: Record<string, string | undefined>): void {
  for (const name of TOUCHED) {
    if (!saved.has(name)) saved.set(name, process.env[name]);
    if (values[name] === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = values[name];
    }
  }
}

afterEach(() => {
  for (const [name, value] of saved) {
    if (value === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = value;
    }
  }
  saved.clear();
});

function productionEnv(): Record<string, string> {
  return {
    NODE_ENV: "production",
    COMMUNITY_SESSION_SECRET: "test-secret",
    COMMUNITY_STORE: "firestore",
    FIRESTORE_PROJECT_ID: "prod-project",
    COMMUNITY_BASE_URL: "https://community.example.com",
    APPLE_BUNDLE_ID: "dev.example.app",
  };
}

describe("strict config", () => {
  test("development defaults still boot the memory store", () => {
    setEnv({});
    const config = configFromEnv();
    expect(config.store).toBe("memory");
    expect(config.screeningPackagesLoaded).toBe(true);
  });

  test("an unknown COMMUNITY_STORE value is an error naming the variable", () => {
    setEnv({ COMMUNITY_STORE: "postgres" });
    expect(() => configFromEnv()).toThrow(/COMMUNITY_STORE/);
  });

  test("a non-numeric PORT is an error naming the variable", () => {
    setEnv({ PORT: "eighty-eighty-seven" });
    expect(() => configFromEnv()).toThrow(/PORT/);
  });

  test("a non-numeric TTL is an error naming the variable", () => {
    setEnv({ COMMUNITY_ACCESS_TTL_MINUTES: "soon" });
    expect(() => configFromEnv()).toThrow(/COMMUNITY_ACCESS_TTL_MINUTES/);
  });

  test("COMMUNITY_STORE=firestore parses", () => {
    setEnv({ COMMUNITY_STORE: "firestore" });
    expect(configFromEnv().store).toBe("firestore");
  });

  test("production refuses the memory store", () => {
    setEnv({ ...productionEnv(), COMMUNITY_STORE: "memory" });
    expect(() => configFromEnv()).toThrow(/COMMUNITY_STORE|memory/);
  });

  test("production requires FIRESTORE_PROJECT_ID", () => {
    setEnv({ ...productionEnv(), FIRESTORE_PROJECT_ID: undefined });
    expect(() => configFromEnv()).toThrow(/FIRESTORE_PROJECT_ID/);
  });

  test("production requires COMMUNITY_BASE_URL", () => {
    setEnv({ ...productionEnv(), COMMUNITY_BASE_URL: undefined });
    expect(() => configFromEnv()).toThrow(/COMMUNITY_BASE_URL/);
  });

  test("production requires APPLE_BUNDLE_ID", () => {
    setEnv({ ...productionEnv(), APPLE_BUNDLE_ID: undefined });
    expect(() => configFromEnv()).toThrow(/APPLE_BUNDLE_ID/);
  });

  test("production refuses to skip screening", () => {
    setEnv({ ...productionEnv(), COMMUNITY_SCREENING_LOADED: "false" });
    expect(() => configFromEnv()).toThrow(/COMMUNITY_SCREENING_LOADED/);
  });

  test("a fully set production boot keeps the configured values", () => {
    setEnv(productionEnv());
    const config = configFromEnv();
    expect(config.store).toBe("firestore");
    expect(config.firestoreProjectId).toBe("prod-project");
    expect(config.communityBaseUrl).toBe("https://community.example.com");
    expect(config.appleBundleId).toBe("dev.example.app");
    expect(config.screeningPackagesLoaded).toBe(true);
  });
});
