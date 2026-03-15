import type { ConfidenceAssessResponse } from "../types/contracts.js";

function sanitizeText(text: string, assessment?: ConfidenceAssessResponse): string {
  if (!assessment || assessment.deterministicReady || assessment.mode === "exact") {
    return text;
  }

  let next = text.replace(/\bexact\b/gi, "estimated");
  next = next.replace(/\bexactly\b/gi, "approximately");

  const hasNutritionClaim = /\b(calories?|macros?|grams?|kcal)\b/i.test(next);
  const hasEstimateFraming = /\b(estimate|estimated|approximately|roughly)\b/i.test(next);

  if (hasNutritionClaim && !hasEstimateFraming) {
    next = `Estimate only: ${next}`;
  }

  const note =
    assessment.mode === "review_required"
      ? "Confidence note: review ingredient amounts before treating nutrition as final."
      : "Confidence note: exact nutrition and exact gram claims stay locked until more evidence is confirmed.";

  return next.includes("Confidence note:") ? next : `${next}\n\n${note}`;
}

export function guardLiveResponse<T extends Record<string, unknown>>(
  message: T,
  assessment?: ConfidenceAssessResponse
): T {
  if (!assessment || assessment.mode === "exact") return message;

  const clone = structuredClone(message);
  const parts = (
    clone.serverContent as
      | { modelTurn?: { parts?: Array<{ text?: string }> } }
      | undefined
  )?.modelTurn?.parts;

  if (!parts) return clone;

  for (const part of parts) {
    if (part.text) {
      part.text = sanitizeText(part.text, assessment);
    }
  }

  return clone;
}
