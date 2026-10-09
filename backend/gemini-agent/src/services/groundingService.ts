import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";

export interface GroundedAnswer {
  /**
   * The model's answer text, or null when the service could not provide
   * one at all (grounding disabled, no model client configured).
   */
  answer: string | null;
  sources: Array<{ title: string; url: string }>;
  /**
   * True only when Google Search grounding returned at least one source for
   * THIS answer. Search links are passed through verbatim; nothing here
   * verifies a source actually supports the sentence it sits next to —
   * that distinction (citation display vs. truth) is a documented boundary
   * in HARDENING.md, and `grounded: false` is how the model/client can tell
   * the user the answer is unverified.
   */
  grounded: boolean;
  unavailableReason?: "grounding_disabled" | "model_unavailable";
}

export async function answerFoodSafetyQuestion(
  ai: GoogleGenAI | null,
  config: Pick<AppConfig, "recipeModel" | "groundingEnabled">,
  question: string
): Promise<GroundedAnswer> {
  if (!config.groundingEnabled) {
    return {
      answer: null,
      sources: [],
      grounded: false,
      unavailableReason: "grounding_disabled"
    };
  }

  if (!ai) {
    return {
      answer: null,
      sources: [],
      grounded: false,
      unavailableReason: "model_unavailable"
    };
  }

  const response = await ai.models.generateContent({
    model: config.recipeModel,
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              "Answer this kitchen freshness or food-safety question conservatively. If evidence is limited, say so."
          },
          { text: question }
        ]
      }
    ],
    config: {
      tools: [{ googleSearch: {} }]
    }
  });

  const metadata = response.candidates?.[0]?.groundingMetadata;
  const sources =
    metadata?.groundingChunks
      ?.flatMap((chunk) => {
        const web = (chunk as { web?: { title?: string; uri?: string } }).web;
        if (!web?.uri) return [];
        return [{ title: web.title ?? web.uri, url: web.uri }];
      })
      .slice(0, 5) ?? [];

  return {
    answer: response.text ?? "I could not find grounded guidance for that question.",
    sources,
    grounded: sources.length > 0
  };
}
