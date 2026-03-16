import "dotenv/config";

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
  /** Grams below which an inventory item is added to the restock list (default: 50) */
  restockBelowGrams: number;
}

function asBool(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value.toLowerCase() === "true";
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
    liveModel: process.env.GEMINI_LIVE_MODEL ?? "gemini-live-2.5-flash-preview",
    restockThresholdDays: Number(process.env.RESTOCK_THRESHOLD_DAYS ?? "3"),
    idempotencyTtlSeconds: Number(process.env.IDEMPOTENCY_TTL_SECONDS ?? "3600"),
    restockBelowGrams: Number(process.env.RESTOCK_BELOW_GRAMS ?? "50"),
    firestoreEmulator: process.env.FIRESTORE_EMULATOR_HOST
  };

  if (useVertexAi) {
    if (!config.projectId || !config.location) {
      throw new Error("Vertex AI mode requires GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION.");
    }
  } else if (!config.apiKey) {
    throw new Error("Developer API mode requires GEMINI_API_KEY.");
  }

  return config;
}
