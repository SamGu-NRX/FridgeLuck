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
