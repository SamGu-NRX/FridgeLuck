import "dotenv/config";

export type SessionStoreMode = "auto" | "memory" | "firestore";

export interface AppConfig {
  port: number;
  useVertexAi: boolean;
  projectId?: string;
  location?: string;
  apiKey?: string;
  recipeModel: string;
  rankingModel: string;
  liveModel: string;
  /** Days remaining before expiry that triggers a "use soon" alert (default: 3) */
  restockThresholdDays: number;
  /** Seconds before an idempotency key expires and the same key can re-apply (default: 3600) */
  idempotencyTtlSeconds: number;
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
  const port = Number(process.env.PORT ?? "8080");

  const config: AppConfig = {
    port,
    useVertexAi,
    projectId: process.env.GOOGLE_CLOUD_PROJECT,
    location: process.env.GOOGLE_CLOUD_LOCATION ?? "us-central1",
    apiKey: process.env.GEMINI_API_KEY,
    recipeModel: process.env.GEMINI_RECIPE_MODEL ?? "gemini-2.5-flash",
    rankingModel: process.env.GEMINI_RANKING_MODEL ?? "gemini-2.5-flash",
    liveModel: assertSupportedLiveModel(
      process.env.GEMINI_LIVE_MODEL ?? "gemini-2.5-flash-native-audio-preview-12-2025"
    ),
    restockThresholdDays: Number(process.env.RESTOCK_THRESHOLD_DAYS ?? "3"),
    idempotencyTtlSeconds: Number(process.env.IDEMPOTENCY_TTL_SECONDS ?? "3600"),
    restockBelowGrams: Number(process.env.RESTOCK_BELOW_GRAMS ?? "50"),
    firestoreEmulator: process.env.FIRESTORE_EMULATOR_HOST,
    sessionStoreMode: asSessionStoreMode(process.env.LIVE_SESSION_STORE_MODE),
    firestoreCollection: process.env.FIRESTORE_COLLECTION ?? "liveSessions",
    groundingEnabled: asBool(process.env.GROUNDING_ENABLED ?? "true")
  };

  if (useVertexAi) {
    if (!config.projectId || !config.location) {
      throw new Error("Vertex AI mode requires GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION.");
    }
  } else if (!config.apiKey) {
    throw new Error("Developer API mode requires GEMINI_API_KEY.");
  }

  if (config.sessionStoreMode === "firestore" && !config.projectId && !config.firestoreEmulator) {
    throw new Error(
      "Firestore session store requires GOOGLE_CLOUD_PROJECT or FIRESTORE_EMULATOR_HOST."
    );
  }

  return config;
}
