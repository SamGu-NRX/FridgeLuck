// ─── Inventory ───────────────────────────────────────────────────────────────

export interface InventoryItem {
  ingredientName: string;
  /** Quantity in grams */
  quantityGrams: number;
  /** ISO 8601 date string, e.g. "2026-03-12" */
  expiresAt?: string;
  /** Source of the item: scan, manual, or restock */
  source?: "scan" | "manual" | "restock";
}

export interface InventoryMutationRequest {
  /** Stable idempotency key; duplicate keys within TTL are no-ops */
  idempotencyKey: string;
  items: InventoryItem[];
  note?: string;
}

export interface InventoryMutationResponse {
  /** Whether the mutation was applied (false = idempotency no-op) */
  committed: boolean;
  snapshot: InventoryItem[];
}

// ─── Restock / Automation ────────────────────────────────────────────────────

export interface RestockPlanRequest {
  inventorySnapshot: InventoryItem[];
  /** Days remaining before expiry that counts as "use soon" */
  thresholdDays: number;
  /** Grams below which an item is considered depleted / restock needed */
  restockBelowGrams?: number;
}

export interface UseSoonAlert {
  ingredientName: string;
  expiresAt: string;
  daysRemaining: number;
}

export interface RestockPlanResponse {
  useSoonAlerts: UseSoonAlert[];
  restockList: string[];
  generatedAt: string;
}

// ─── Observability ───────────────────────────────────────────────────────────

export interface ToolCallTrace {
  traceId: string;
  toolName: string;
  sessionId?: string;
  durationMs: number;
  success: boolean;
  errorMessage?: string;
  confidenceMode?: ConfidenceMode;
  confidenceScore?: number;
  timestamp: string;
  args?: Record<string, unknown>;
}

// ─── Recipe ──────────────────────────────────────────────────────────────────

export interface RecipeGenerationRequest {
  ingredientNames: string[];
  dietaryRestrictions?: string[];
  scanConfidenceScore?: number;
  photoBase64JPEG?: string;
}

export interface RecipeGenerationResponse {
  title: string;
  timeMinutes: number;
  servings: number;
  instructions: string;
  estimatedCaloriesPerServing: number;
}

export interface ReverseScanDetection {
  label: string;
  confidence: number;
}

export interface ReverseScanCandidate {
  recipeId: number;
  title: string;
  localConfidence: number;
  missingRequiredCount: number;
}

export interface ReverseScanRankRequest {
  detections: ReverseScanDetection[];
  candidates: ReverseScanCandidate[];
  photoBase64JPEG?: string;
}

export interface ReverseScanRankItem {
  recipeId: number;
  confidenceScore: number;
  reason: string;
}

export interface ReverseScanRankResponse {
  rankings: ReverseScanRankItem[];
}

export interface ConfidenceSignalInput {
  key: string;
  rawScore: number;
  weight?: number;
  reason?: string;
}

export interface ConfidenceAssessRequest {
  signals: ConfidenceSignalInput[];
  hardFailReasons?: string[];
}

export type ConfidenceMode = "exact" | "review_required" | "estimate_only";

export interface ConfidenceSignalAssessment {
  key: string;
  rawScore: number;
  adjustedScore: number;
  trustMean: number;
  trustUncertainty: number;
  weight: number;
  reason: string;
}

export interface ConfidenceAssessResponse {
  mode: ConfidenceMode;
  overallScore: number;
  deterministicReady: boolean;
  reasons: string[];
  signals: ConfidenceSignalAssessment[];
}

export interface ConfidenceOutcomeRequest {
  assessment: ConfidenceAssessResponse;
  outcomeReward: number;
  contextKey?: string;
  note?: string;
}
