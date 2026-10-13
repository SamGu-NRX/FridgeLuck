import "dotenv/config";

export type SessionStoreMode = "auto" | "memory" | "firestore";

export interface AppConfig {
  port: number;
  useVertexAi: boolean;
  projectId?: string;
  location?: string;
  apiKey?: string;
  /**
   * True when model credentials are complete for the chosen mode. When
   * false the server boots into a degraded, fail-safe mode: paid-model
   * routes and the live gateway answer with stable unavailable codes while
   * free routes and webhooks keep working.
   */
  genaiConfigured: boolean;
  recipeModel: string;
  rankingModel: string;
  liveModel: string;
  /** Days remaining before expiry that triggers a "use soon" alert (default: 3) */
  restockThresholdDays: number;
  /** Seconds before an idempotency key expires and the same key can re-apply (default: 3600) */
  idempotencyTtlSeconds: number;
  /**
   * Lifetime of a pending inventory-mutation proposal, in seconds
   * (default: 300). Unapproved proposals expire; the model may re-propose.
   */
  mutationProposalTtlSeconds: number;
  /**
   * Maximum concurrent live gateway sessions (default: 20). Connections
   * beyond the cap are refused with close code 1013.
   */
  maxLiveSessions: number;
  /**
   * Maximum lifetime of one live gateway connection, in seconds
   * (default: 3600). The server closes the session when the cap is reached.
   */
  maxSessionSeconds: number;
  /**
   * Per-connection budget of client envelopes per minute on the live
   * gateway (default: 300). Cost containment for realtime audio/video
   * forwarding — not authentication.
   */
  liveClientMessagesPerMinute: number;
  /** Firestore emulator host, e.g. "localhost:8080" — if set, SDK uses emulator */
  firestoreEmulator?: string;
  /** How live session state is persisted. */
  sessionStoreMode: SessionStoreMode;
  /** Firestore collection for live-session documents. */
  firestoreCollection: string;
  /** Whether Google Search grounding can be used for food-safety/freshness questions. */
  groundingEnabled: boolean;
  /** Grams below which an inventory item is added to the restock list (default: 50) */
  restockBelowGrams: number;
}

const DEPRECATED_LIVE_MODELS = new Set([
  "gemini-live-2.5-flash-preview",
  "gemini-2.0-flash-live-001"
]);

function asBool(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value.toLowerCase() === "true";
}

function asSessionStoreMode(value: string | undefined): SessionStoreMode {
  switch (value?.toLowerCase()) {
    case "memory":
      return "memory";
    case "firestore":
      return "firestore";
    default:
      return "auto";
  }
}

/** Echoes an offending env value in error text, capped so a stray large value cannot bloat logs. */
function describeEnvValue(value: string): string {
  const capped = value.length > 60 ? `${value.slice(0, 57)}...` : value;
  return JSON.stringify(capped);
}

/**
 * Validates that a numeric env var is neither empty/whitespace-only nor
 * non-numeric or non-finite, then returns the parsed value. Range and
 * integrality checks stay with the named wrappers below.
 */
function requireFiniteEnvNumber(name: string, requirement: string, value: string): number {
  const trimmed = value.trim();
  if (trimmed === "") {
    throw new Error(
      `${name} must be ${requirement}, but its value is empty or whitespace-only.`
    );
  }
  const parsed = Number(trimmed);
  if (Number.isNaN(parsed)) {
    throw new Error(
      `${name} must be ${requirement}, but ${describeEnvValue(value)} is not a number.`
    );
  }
  if (!Number.isFinite(parsed)) {
    throw new Error(
      `${name} must be ${requirement}, but ${describeEnvValue(value)} is not finite.`
    );
  }
  return parsed;
}

/** PORT: integer 1..65535 (unset -> 8080). */
function parsePortEnv(value: string | undefined): number {
  if (value === undefined) return 8080;
  const requirement = "an integer between 1 and 65535";
  const parsed = requireFiniteEnvNumber("PORT", requirement, value);
  if (!Number.isInteger(parsed)) {
    throw new Error(
      `PORT must be ${requirement}, but ${describeEnvValue(value)} is not an integer.`
    );
  }
  if (parsed < 1 || parsed > 65535) {
    throw new Error(
      `PORT must be ${requirement}, but ${describeEnvValue(value)} is out of range.`
    );
  }
  return parsed;
}

/** Positive safe integer (no arbitrary upper cap). */
function parsePositiveSafeIntegerEnv(
  name: string,
  value: string | undefined,
  fallback: number
): number {
  if (value === undefined) return fallback;
  const requirement = "a positive safe integer";
  const parsed = requireFiniteEnvNumber(name, requirement, value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new Error(
      `${name} must be ${requirement}, but ${describeEnvValue(value)} is not a positive safe integer.`
    );
  }
  return parsed;
}

/** Finite non-negative measurement; fractions allowed (e.g. 2.5 days, 0.75 grams). */
function parseNonNegativeEnvNumber(
  name: string,
  value: string | undefined,
  fallback: number
): number {
  if (value === undefined) return fallback;
  const requirement = "a finite non-negative number";
  const parsed = requireFiniteEnvNumber(name, requirement, value);
  if (parsed < 0) {
    throw new Error(
      `${name} must be ${requirement}, but ${describeEnvValue(value)} is negative.`
    );
  }
  return parsed;
}

export function assertSupportedLiveModel(model: string): string {
  const normalized = model.trim();
  if (!normalized) {
    throw new Error("GEMINI_LIVE_MODEL must not be empty.");
  }

  if (DEPRECATED_LIVE_MODELS.has(normalized)) {
    throw new Error(
      `Live model '${normalized}' is deprecated. Use a current Gemini Live model such as 'gemini-2.5-flash-native-audio-preview-12-2025'.`
    );
  }

  return normalized;
}

export function loadConfig(): AppConfig {
  const useVertexAi = asBool(process.env.GOOGLE_GENAI_USE_VERTEXAI);
  const apiKey = process.env.GEMINI_API_KEY;
  const projectId = process.env.GOOGLE_CLOUD_PROJECT;
  const genaiConfigured = useVertexAi
    ? Boolean(projectId && (process.env.GOOGLE_CLOUD_LOCATION ?? "us-central1"))
    : Boolean(apiKey);

  const config: AppConfig = {
    port: parsePortEnv(process.env.PORT),
    useVertexAi,
    projectId,
    location: process.env.GOOGLE_CLOUD_LOCATION ?? "us-central1",
    apiKey,
    genaiConfigured,
    recipeModel: process.env.GEMINI_RECIPE_MODEL ?? "gemini-2.5-flash",
    rankingModel: process.env.GEMINI_RANKING_MODEL ?? "gemini-2.5-flash",
    liveModel: assertSupportedLiveModel(
      process.env.GEMINI_LIVE_MODEL ?? "gemini-2.5-flash-native-audio-preview-12-2025"
    ),
    restockThresholdDays: parseNonNegativeEnvNumber(
      "RESTOCK_THRESHOLD_DAYS",
      process.env.RESTOCK_THRESHOLD_DAYS,
      3
    ),
    idempotencyTtlSeconds: parsePositiveSafeIntegerEnv(
      "IDEMPOTENCY_TTL_SECONDS",
      process.env.IDEMPOTENCY_TTL_SECONDS,
      3600
    ),
    mutationProposalTtlSeconds: parsePositiveSafeIntegerEnv(
      "MUTATION_PROPOSAL_TTL_SECONDS",
      process.env.MUTATION_PROPOSAL_TTL_SECONDS,
      300
    ),
    maxLiveSessions: parsePositiveSafeIntegerEnv(
      "MAX_LIVE_SESSIONS",
      process.env.MAX_LIVE_SESSIONS,
      20
    ),
    maxSessionSeconds: parsePositiveSafeIntegerEnv(
      "MAX_SESSION_SECONDS",
      process.env.MAX_SESSION_SECONDS,
      3600
    ),
    liveClientMessagesPerMinute: parsePositiveSafeIntegerEnv(
      "LIVE_CLIENT_MESSAGES_PER_MINUTE",
      process.env.LIVE_CLIENT_MESSAGES_PER_MINUTE,
      300
    ),
    restockBelowGrams: parseNonNegativeEnvNumber(
      "RESTOCK_BELOW_GRAMS",
      process.env.RESTOCK_BELOW_GRAMS,
      50
    ),
    firestoreEmulator: process.env.FIRESTORE_EMULATOR_HOST,
    sessionStoreMode: asSessionStoreMode(process.env.LIVE_SESSION_STORE_MODE),
    firestoreCollection: process.env.FIRESTORE_COLLECTION ?? "liveSessions",
    groundingEnabled: asBool(process.env.GROUNDING_ENABLED ?? "true")
  };

  if (useVertexAi) {
    if (!config.projectId || !config.location) {
      throw new Error("Vertex AI mode requires GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION.");
    }
  }
  // Developer API mode with no GEMINI_API_KEY no longer throws: the server
  // boots unconfigured (genaiConfigured=false) and every model-dependent
  // surface answers with a stable unavailable code. Failing SAFE here beats
  // failing the whole container — a prototype without keys keeps its free
  // routes, webhooks, and health checks.

  if (config.sessionStoreMode === "firestore" && !config.projectId && !config.firestoreEmulator) {
    throw new Error(
      "Firestore session store requires GOOGLE_CLOUD_PROJECT or FIRESTORE_EMULATOR_HOST."
    );
  }

  return config;
}
