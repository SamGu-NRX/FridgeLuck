import { Type, type GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type {
  ReverseScanRankRequest,
  ReverseScanRankResponse
} from "../types/contracts.js";

function toInlineImagePart(photoBase64JPEG?: string) {
  if (!photoBase64JPEG) return [];
  return [
    {
      inlineData: {
        mimeType: "image/jpeg",
        data: photoBase64JPEG
      }
    }
  ];
}

export async function rankReverseScanCandidates(
  ai: GoogleGenAI,
  config: AppConfig,
  request: ReverseScanRankRequest
): Promise<ReverseScanRankResponse> {
  const detectionSummary = request.detections
    .slice(0, 20)
    .map((detection) => `${detection.label}:${Math.round(detection.confidence * 100)}`)
    .join(", ");

  const candidateSummary = request.candidates
    .slice(0, 12)
    .map(
      (candidate) =>
        `id=${candidate.recipeId}, title=${candidate.title}, local_conf=${candidate.localConfidence.toFixed(3)}, missing_required=${candidate.missingRequiredCount}`
    )
    .join("\n");

  const response = await ai.models.generateContent({
    model: config.rankingModel,
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              "Rank recipe candidates for reverse meal scan. Favor lower missing_required and stronger alignment with detections."
          },
          {
            text: `detections: ${detectionSummary}`
          },
          {
            text: `candidates:\n${candidateSummary}`
          },
          ...toInlineImagePart(request.photoBase64JPEG)
        ]
      }
    ],
    config: {
      responseMimeType: "application/json",
      responseSchema: {
        type: Type.OBJECT,
        properties: {
          rankings: {
            type: Type.ARRAY,
            items: {
              type: Type.OBJECT,
              properties: {
                recipeId: { type: Type.INTEGER },
                confidenceScore: { type: Type.NUMBER },
                reason: { type: Type.STRING }
              },
              required: ["recipeId", "confidenceScore", "reason"]
            }
          }
        },
        required: ["rankings"]
      }
    }
  });

  const parsed = JSON.parse(response.text ?? "{}") as Partial<ReverseScanRankResponse>;

  const rankings = (parsed.rankings ?? []).map((ranking) => ({
    recipeId: ranking.recipeId,
    confidenceScore: Math.max(0, Math.min(1, ranking.confidenceScore)),
    reason: ranking.reason
  }));

  return { rankings };
}
