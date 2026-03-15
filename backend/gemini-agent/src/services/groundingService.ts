import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";

export interface GroundedAnswer {
  answer: string;
  sources: Array<{ title: string; url: string }>;
}

export async function answerFoodSafetyQuestion(
  ai: GoogleGenAI,
  config: Pick<AppConfig, "recipeModel" | "groundingEnabled">,
  question: string
): Promise<GroundedAnswer> {
  if (!config.groundingEnabled) {
    throw new Error("Google grounding is disabled for this environment.");
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
    sources
  };
}
