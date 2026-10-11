import { Type, type GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type {
  ReverseScanRankItem,
  ReverseScanRankRequest,
  ReverseScanRankResponse
} from "../types/contracts.js";

/**
 * Candidate titles are embedded into the ranking prompt, so they are
 * sanitized to a single line of bounded length. Recipe ids are never
 * altered: they are the join key the iOS client uses to map rankings back
 * onto local candidates.
 */
const MAX_PROMPT_TITLE_LENGTH = 120;

/**
 * Provider reasons surface as UI explanations on iOS. Clip runaway output to
 * a bounded length instead of dropping an otherwise valid ranking.
 */
const MAX_REASON_LENGTH = 500;

/** Provider confidence scores must already be finite and within [0, 1]. */
const MIN_CONFIDENCE_SCORE = 0;
const MAX_CONFIDENCE_SCORE = 1;

// C0 control characters, DEL, and the Unicode line/paragraph separators.
const PROMPT_CONTROL_CHARS = /[\u0000-\u001F\u007F\u2028\u2029]/g;

function sanitizePromptTitle(title: unknown): string {
  if (typeof title !== "string") return "";
  return title
    .replace(PROMPT_CONTROL_CHARS, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_PROMPT_TITLE_LENGTH);
}

/**
 * Provider-output policy, chosen from inspected iOS caller semantics
 * (ReverseScanService.swift / GeminiCloudAgent.swift):
 *
 * - No text at all is "the provider returned nothing" and maps to an empty
 *   ranking. The iOS client's `!cloudRankings.isEmpty` guard skips cloud
 *   re-ranking for an empty list, so local candidates are retained as-is.
 * - Structurally broken output (unparseable JSON, non-object payload,
 *   missing or non-array `rankings`) is a hard failure with a clear message.
 *   The express route already converts that into a 500 `{ error }` body, and
 *   the iOS client treats any non-2xx as "cloud unavailable" and keeps the
 *   deterministic local ranking — an existing compatible failure path.
 * - Individual invalid entries (foreign or duplicate ids, missing or
 *   unbounded scores, non-string reasons) are omitted while valid siblings
 *   survive. iOS blends confidence per candidate, so partial output
 *   degrades gracefully; a duplicate id would otherwise crash the client's
 *   `Dictionary(uniqueKeysWithValues:)` construction.
 *
 * Unreturned candidates are never fabricated: no entry, no invented
 * confidence — local candidates are simply left alone.
 */
function extractProviderRankings(
  responseText: string | null | undefined
): unknown[] {
  if (responseText == null || responseText.trim() === "") {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(responseText);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Reverse-scan ranking provider returned malformed JSON: ${detail}`
    );
  }

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(
      "Reverse-scan ranking provider response must be a JSON object with a rankings array."
    );
  }

  const rankings = (parsed as { rankings?: unknown }).rankings;
  if (!Array.isArray(rankings)) {
    throw new Error(
      "Reverse-scan ranking provider response must include a rankings array."
    );
  }

  return rankings;
}

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
  const requestedRecipeIds = new Set(
    request.candidates.map((candidate) => candidate.recipeId)
  );

  const detectionSummary = request.detections
    .slice(0, 20)
    .map((detection) => `${detection.label}:${Math.round(detection.confidence * 100)}`)
    .join(", ");

  const candidateSummary = request.candidates
    .slice(0, 12)
    .map(
      (candidate) =>
        `id=${candidate.recipeId}, title=${sanitizePromptTitle(candidate.title)}, local_conf=${candidate.localConfidence.toFixed(3)}, missing_required=${candidate.missingRequiredCount}`
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

  const providerRankings = extractProviderRankings(response.text);

  const seenRecipeIds = new Set<number>();
  const rankings: ReverseScanRankItem[] = [];

  for (const entry of providerRankings) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      continue;
    }

    const { recipeId, confidenceScore, reason } = entry as {
      recipeId?: unknown;
      confidenceScore?: unknown;
      reason?: unknown;
    };

    // Only request-candidate integral ids are accepted.
    if (typeof recipeId !== "number" || !Number.isInteger(recipeId)) {
      continue;
    }
    if (!requestedRecipeIds.has(recipeId)) {
      continue;
    }

    // Only actual, finite, in-bounds scores are accepted — bad values are
    // never clamped into existence and unreturned candidates never get an
    // invented confidence.
    if (
      typeof confidenceScore !== "number" ||
      !Number.isFinite(confidenceScore)
    ) {
      continue;
    }
    if (
      confidenceScore < MIN_CONFIDENCE_SCORE ||
      confidenceScore > MAX_CONFIDENCE_SCORE
    ) {
      continue;
    }

    // Reasons must be strings; clip to the bounded length.
    if (typeof reason !== "string") {
      continue;
    }

    // Dedupe keeps the first valid occurrence per recipe id.
    if (seenRecipeIds.has(recipeId)) {
      continue;
    }

    seenRecipeIds.add(recipeId);
    rankings.push({
      recipeId,
      confidenceScore,
      reason: reason.slice(0, MAX_REASON_LENGTH)
    });
  }

  return { rankings };
}
