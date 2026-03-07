import { Type, type GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type {
  RecipeGenerationRequest,
  RecipeGenerationResponse
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

export async function generateRecipe(
  ai: GoogleGenAI,
  config: AppConfig,
  request: RecipeGenerationRequest
): Promise<RecipeGenerationResponse> {
  const dietaryRestrictions = request.dietaryRestrictions ?? [];
  const restrictionsText = dietaryRestrictions.length > 0 ? dietaryRestrictions.join(", ") : "none";

  const contents = [
    {
      role: "user",
      parts: [
        {
          text:
            "You are a practical smart-fridge cooking assistant. Use scanned ingredients first, be concise, and keep calories realistic."
        },
        {
          text: `ingredients_from_scan: ${request.ingredientNames.join(", ")}`
        },
        {
          text: `dietary_restrictions: ${restrictionsText}`
        },
        {
          text: `scan_confidence_score: ${request.scanConfidenceScore ?? 0.0}`
        },
        ...toInlineImagePart(request.photoBase64JPEG)
      ]
    }
  ];

  const response = await ai.models.generateContent({
    model: config.recipeModel,
    contents,
    config: {
      responseMimeType: "application/json",
      responseSchema: {
        type: Type.OBJECT,
        properties: {
          title: { type: Type.STRING },
          timeMinutes: { type: Type.INTEGER },
          servings: { type: Type.INTEGER },
          instructions: { type: Type.STRING },
          estimatedCaloriesPerServing: { type: Type.INTEGER }
        },
        required: [
          "title",
          "timeMinutes",
          "servings",
          "instructions",
          "estimatedCaloriesPerServing"
        ]
      }
    }
  });

  const parsed = JSON.parse(response.text ?? "{}") as Partial<RecipeGenerationResponse>;

  if (!parsed.title || !parsed.instructions) {
    throw new Error("Gemini response missing required recipe fields.");
  }

  return {
    title: parsed.title,
    timeMinutes: Math.max(5, parsed.timeMinutes ?? 15),
    servings: Math.max(1, parsed.servings ?? 1),
    instructions: parsed.instructions,
    estimatedCaloriesPerServing: Math.max(50, parsed.estimatedCaloriesPerServing ?? 120)
  };
}
