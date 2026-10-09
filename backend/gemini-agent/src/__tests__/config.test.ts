import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { assertSupportedLiveModel, loadConfig } from "../config.js";

// Inert stand-in so loadConfig's provider-credential checks pass and any
// thrown error is attributable to the numeric variable under test. Not a real
// credential.
const INERT_API_KEY = "config-test-inert-key";

const NUMERIC_ENV_KEYS = [
  "PORT",
  "IDEMPOTENCY_TTL_SECONDS",
  "RESTOCK_THRESHOLD_DAYS",
  "RESTOCK_BELOW_GRAMS"
] as const;

type NumericEnvKey = (typeof NUMERIC_ENV_KEYS)[number];
type NumericConfigField =
  | "port"
  | "idempotencyTtlSeconds"
  | "restockThresholdDays"
  | "restockBelowGrams";

const configFieldFor: Record<NumericEnvKey, NumericConfigField> = {
  PORT: "port",
  IDEMPOTENCY_TTL_SECONDS: "idempotencyTtlSeconds",
  RESTOCK_THRESHOLD_DAYS: "restockThresholdDays",
  RESTOCK_BELOW_GRAMS: "restockBelowGrams"
};

// Every variable loadConfig reads, so each test case starts from a
// deterministic baseline regardless of local .env files or CI environment.
const CONFIG_ENV_KEYS = [
  ...NUMERIC_ENV_KEYS,
  "GEMINI_API_KEY",
  "GOOGLE_GENAI_USE_VERTEXAI",
  "GOOGLE_CLOUD_PROJECT",
  "GOOGLE_CLOUD_LOCATION",
  "GEMINI_RECIPE_MODEL",
  "GEMINI_RANKING_MODEL",
  "GEMINI_LIVE_MODEL",
  "FIRESTORE_EMULATOR_HOST",
  "LIVE_SESSION_STORE_MODE",
  "FIRESTORE_COLLECTION",
  "GROUNDING_ENABLED"
] as const;

function loadConfigError(): string {
  try {
    loadConfig();
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
  return "EXPECTED_LOAD_CONFIG_TO_THROW";
}

// Each case must start from a clean numeric slate so a thrown error is always
// attributable to the variable set in that iteration, not one left over from
// the previous case.
function clearNumericEnv(): void {
  for (const key of NUMERIC_ENV_KEYS) {
    delete process.env[key];
  }
}

describe("assertSupportedLiveModel", () => {
  it("accepts supported live models", () => {
    expect(assertSupportedLiveModel("gemini-2.5-flash-native-audio-preview-12-2025")).toBe(
      "gemini-2.5-flash-native-audio-preview-12-2025"
    );
  });

  it("rejects deprecated live models", () => {
    expect(() => assertSupportedLiveModel("gemini-live-2.5-flash-preview")).toThrow(
      "deprecated"
    );
  });
});

describe("loadConfig numeric env parsing", () => {
  let savedEnv: Record<string, string | undefined> = {};

  beforeEach(() => {
    savedEnv = {};
    for (const key of CONFIG_ENV_KEYS) {
      savedEnv[key] = process.env[key];
      delete process.env[key];
    }
    process.env.GEMINI_API_KEY = INERT_API_KEY;
  });

  afterEach(() => {
    for (const key of CONFIG_ENV_KEYS) {
      const previous = savedEnv[key];
      if (previous === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous;
      }
    }
  });

  it("keeps documented defaults when the numeric variables are unset", () => {
    const config = loadConfig();
    expect(config.port).toBe(8080);
    expect(config.restockThresholdDays).toBe(3);
    expect(config.idempotencyTtlSeconds).toBe(3600);
    expect(config.restockBelowGrams).toBe(50);
  });

  it("rejects empty and whitespace-only values for every numeric variable", () => {
    for (const envKey of NUMERIC_ENV_KEYS) {
      for (const value of ["", "   "]) {
        clearNumericEnv();
        process.env[envKey] = value;
        const message = loadConfigError();
        expect(message).toContain(envKey);
        expect(message).not.toContain(INERT_API_KEY);
      }
    }
  });

  it("rejects invalid numeric values per variable contract", () => {
    const cases: Array<{ envKey: NumericEnvKey; value: string; why: string }> = [
      // PORT: integer 1..65535
      { envKey: "PORT", value: "", why: "empty string (previously coerced to 0)" },
      { envKey: "PORT", value: "abc", why: "non-numeric" },
      { envKey: "PORT", value: "Infinity", why: "non-finite" },
      { envKey: "PORT", value: "1e999", why: "overflows to infinity" },
      { envKey: "PORT", value: "0", why: "below the 1..65535 range" },
      { envKey: "PORT", value: "-1", why: "negative" },
      { envKey: "PORT", value: "65536", why: "above the 1..65535 range" },
      { envKey: "PORT", value: "8080.5", why: "not an integer" },
      // IDEMPOTENCY_TTL_SECONDS: positive safe integer
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "", why: "empty string" },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "abc", why: "non-numeric" },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "-Infinity", why: "non-finite" },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "0", why: "not positive" },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "-3", why: "negative" },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "1.5", why: "not an integer" },
      {
        envKey: "IDEMPOTENCY_TTL_SECONDS",
        value: "9007199254740992",
        why: "beyond the safe integer range"
      },
      // RESTOCK_THRESHOLD_DAYS: finite non-negative (fractions allowed)
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "abc", why: "non-numeric (previously NaN)" },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "NaN", why: "non-numeric" },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "Infinity", why: "non-finite" },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "-0.5", why: "negative" },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "-3", why: "negative" },
      // RESTOCK_BELOW_GRAMS: finite non-negative (fractions allowed)
      { envKey: "RESTOCK_BELOW_GRAMS", value: "abc", why: "non-numeric" },
      { envKey: "RESTOCK_BELOW_GRAMS", value: "Infinity", why: "non-finite" },
      { envKey: "RESTOCK_BELOW_GRAMS", value: "-1", why: "negative" }
    ];

    for (const { envKey, value, why } of cases) {
      clearNumericEnv();
      process.env[envKey] = value;
      const message = loadConfigError();
      expect(message).toContain(envKey);
      expect(message).not.toContain(INERT_API_KEY);
      expect(message, `${envKey}=${JSON.stringify(value)} (${why})`).not.toContain(
        "EXPECTED_LOAD_CONFIG_TO_THROW"
      );
    }
  });

  it("accepts exact boundaries and documented shapes", () => {
    const cases: Array<{ envKey: NumericEnvKey; value: string; expected: number }> = [
      { envKey: "PORT", value: "1", expected: 1 },
      { envKey: "PORT", value: "65535", expected: 65535 },
      { envKey: "PORT", value: " 8080 ", expected: 8080 },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "1", expected: 1 },
      { envKey: "IDEMPOTENCY_TTL_SECONDS", value: "9007199254740991", expected: 9007199254740991 },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "0", expected: 0 },
      { envKey: "RESTOCK_THRESHOLD_DAYS", value: "2.5", expected: 2.5 },
      { envKey: "RESTOCK_BELOW_GRAMS", value: "0", expected: 0 },
      { envKey: "RESTOCK_BELOW_GRAMS", value: "0.75", expected: 0.75 }
    ];

    for (const { envKey, value, expected } of cases) {
      clearNumericEnv();
      process.env[envKey] = value;
      const config = loadConfig();
      expect(config[configFieldFor[envKey]], `${envKey}=${JSON.stringify(value)}`).toBe(
        expected
      );
    }
  });

  it("rejects empty PORT instead of coercing it to 0 even when other limits are valid", () => {
    clearNumericEnv();
    process.env.PORT = "";
    process.env.IDEMPOTENCY_TTL_SECONDS = "3600";
    process.env.RESTOCK_THRESHOLD_DAYS = "3";
    process.env.RESTOCK_BELOW_GRAMS = "50";
    expect(loadConfigError()).toContain("PORT");
  });
});
