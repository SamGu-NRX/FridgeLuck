// ─── Inventory ───────────────────────────────────────────────────────────────

export interface InventoryItem {
  ingredientId?: number;
  ingredientName: string;
  /** Quantity in grams */
  quantityGrams: number;
  /** ISO 8601 date string, e.g. "2026-03-12" */
  expiresAt?: string;
  confidenceScore?: number;
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

export interface NotificationPlanRule {
  kind: "use_soon_alerts";
  enabled: boolean;
  hour: number;
  minute: number;
  pushToken?: string;
}

export interface NotificationOpportunityPayload {
  ingredientIds: number[];
  ingredientNames: string[];
  expiresAt: string[];
}

export interface NotificationOpportunity {
  id: string;
  kind: "use_soon_digest";
  title: string;
  body: string;
  scheduledAt: string;
  payload: NotificationOpportunityPayload;
}

export interface NotificationPlanRequest {
  installationId: string;
  timezone: string;
  locale: string;
  generatedAt: string;
  rules: NotificationPlanRule[];
  inventorySnapshot: InventoryItem[];
}

export interface NotificationPlanResponse {
  generatedAt: string;
  opportunities: NotificationOpportunity[];
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
  /**
   * Dietary restrictions enforced by the ingredient-facts conformance
   * screen, not just the prompt: an ingredient that conflicts with a
   * restriction, or whose composition cannot be verified against the active
   * restrictions, fails closed (the recipe is rejected, never served).
   */
  dietaryRestrictions?: string[];
  /**
   * Ingredients the recipe must not use. Matched case-insensitively on word
   * boundaries with simple plural forms (e.g. "egg" also matches "eggs",
   * but never "eggplant"). Exclusions override staple allowances and
   * supplied foods.
   */
  avoidIngredients?: string[];
  scanConfidenceScore?: number;
  photoBase64JPEG?: string;
}

export interface RecipeGenerationResponse {
  title: string;
  timeMinutes: number;
  servings: number;
  instructions: string;
  estimatedCaloriesPerServing: number;
  /**
   * Model-asserted list of ingredients the recipe uses, including staples.
   * This is a model assertion, NOT independent evidence of grounding: the
   * service additionally screens title/instructions text with a limited
   * recognized-food check, but no lexical screen is an allergy-safety or
   * complete grounding guarantee.
   */
  ingredientsUsed: string[];
}

/**
 * Public rejection reasons for the recipe ingredient-policy screen.
 * Frozen shared error contract (packet023), extended per the PR #94
 * ingredient-facts fix list (issue comment 6115055871) with the two
 * restriction-conformance outcomes: `violates_dietary_restriction` and
 * `unverified_ingredient_facts` (fail closed: unknown composition is never
 * allowed through), and per the PR #94 safety-lint review finding with the
 * two cooking-advice safety outcomes: `violates_food_safety` and
 * `unverified_advice_safety` (fail closed: advice that cannot be classified
 * safe against the canonical rulebook is never served).
 */
export type RecipeRejectionReason =
  | "uses_avoided_ingredient"
  | "uses_unlisted_ingredient"
  | "violates_dietary_restriction"
  | "unverified_ingredient_facts"
  | "violates_food_safety"
  | "unverified_advice_safety";

/**
 * Static, public-safe rejection messages, keyed exhaustively by reason so a
 * new union member fails to compile until its message exists. Messages never
 * contain generated text, request contents or photos, or provider messages.
 */
const REJECTION_MESSAGES: Record<RecipeRejectionReason, string> = {
  uses_avoided_ingredient:
    "Recipe rejected: the recipe uses an ingredient that must be avoided.",
  uses_unlisted_ingredient:
    "Recipe rejected: the recipe uses an ingredient that was not supplied or allowed.",
  violates_dietary_restriction:
    "Recipe rejected: an ingredient conflicts with the household's dietary restrictions.",
  unverified_ingredient_facts:
    "Recipe rejected: an ingredient could not be verified against known ingredient facts.",
  violates_food_safety:
    "Recipe rejected: the cooking advice conflicts with the food-safety rulebook.",
  unverified_advice_safety:
    "Recipe rejected: cooking-advice safety could not be verified."
};

/**
 * Frozen shared error contract (packet023, extended per the PR #94
 * ingredient-facts fix list):
 * - `status` is 422; the API layer maps it to the HTTP status code.
 * - `reason` is the only machine-readable detail: one of the
 *   RecipeRejectionReason union members.
 * - `message` is static and public-safe. It never contains generated text,
 *   request contents or photos, or provider messages.
 */
export class RecipeRejectedError extends Error {
  readonly status = 422;
  readonly reason: RecipeRejectionReason;

  constructor(reason: RecipeRejectionReason) {
    super(REJECTION_MESSAGES[reason]);
    this.name = "RecipeRejectedError";
    this.reason = reason;
  }
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
