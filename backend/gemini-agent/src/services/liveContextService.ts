import { Type, type GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { StoredCameraFrame, StoredIngredientContext, StoredRecipeContext } from "../session/liveSessionStore.js";
import type { ConfidenceAssessResponse, ConfidenceAssessRequest } from "../types/contracts.js";
import type { ConfidenceService } from "./confidenceService.js";

export interface LiveSceneAssessment {
  currentStep: string;
  guidance: string;
  observedIngredients: string[];
  kitchenRisks: string[];
  confidence_assessment: ConfidenceAssessResponse;
}

function toInlineImagePart(frame?: StoredCameraFrame) {
  if (!frame || !frame.mimeType.startsWith("image/")) return [];
  return [
    {
      inlineData: {
        mimeType: frame.mimeType,
        data: frame.dataBase64
      }
    }
  ];
}

function ingredientCoverage(
  confirmedIngredients: StoredIngredientContext[],
  recipe?: StoredRecipeContext
): number {
  if (!recipe?.ingredients?.length) return confirmedIngredients.length > 0 ? 0.8 : 0.3;
  const recipeNames = new Set(recipe.ingredients.map((ingredient) => ingredient.name.toLowerCase()));
  const matched = confirmedIngredients.filter((ingredient) =>
    recipeNames.has(ingredient.name.toLowerCase())
  ).length;
  return Math.max(0.2, Math.min(matched / recipe.ingredients.length, 1));
}

export async function assessLiveCookingScene(
  ai: GoogleGenAI,
  config: Pick<AppConfig, "recipeModel">,
  confidenceService: ConfidenceService,
  params: {
    recipe?: StoredRecipeContext;
    confirmedIngredients: StoredIngredientContext[];
    latestCameraFrame?: StoredCameraFrame;
    userQuestion?: string;
  }
): Promise<LiveSceneAssessment> {
  const { recipe, confirmedIngredients, latestCameraFrame, userQuestion } = params;

  const hardFailReasons: string[] = [];
  if (!recipe) hardFailReasons.push("No recipe is selected in the live cooking session.");
  if (!latestCameraFrame) hardFailReasons.push("No recent kitchen camera frame is available yet.");

  const response = await ai.models.generateContent({
    model: config.recipeModel,
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              "You are assessing a live cooking scene for FridgeLuck. Be conservative and do not invent ingredients or exact measurements."
          },
          {
            text: `selected_recipe_title: ${recipe?.title ?? "none"}`
          },
          {
            text: `selected_recipe_instructions: ${recipe?.instructions ?? "none"}`
          },
          {
            text: `recipe_ingredients: ${
              recipe?.ingredients?.map((ingredient) => ingredient.name).join(", ") ?? "none"
            }`
          },
          {
            text: `confirmed_ingredients: ${
              confirmedIngredients.map((ingredient) => ingredient.name).join(", ") || "none"
            }`
          },
          {
            text: `user_question: ${userQuestion ?? "Guide the cook based on the current scene."}`
          },
          ...toInlineImagePart(latestCameraFrame)
        ]
      }
    ],
    config: {
      responseMimeType: "application/json",
      responseSchema: {
        type: Type.OBJECT,
        properties: {
          currentStep: { type: Type.STRING },
          guidance: { type: Type.STRING },
          observedIngredients: { type: Type.ARRAY, items: { type: Type.STRING } },
          kitchenRisks: { type: Type.ARRAY, items: { type: Type.STRING } },
          modelConfidence: { type: Type.NUMBER }
        },
        required: ["currentStep", "guidance", "observedIngredients", "kitchenRisks", "modelConfidence"]
      }
    }
  });

  const parsed = JSON.parse(response.text ?? "{}") as {
    currentStep?: string;
    guidance?: string;
    observedIngredients?: string[];
    kitchenRisks?: string[];
    modelConfidence?: number;
  };

  const confidenceRequest: ConfidenceAssessRequest = {
    signals: [
      {
        key: "live.recipe_context",
        rawScore: recipe ? 0.92 : 0.2,
        weight: 0.25,
        reason: "recipe context availability"
      },
      {
        key: "live.camera_frame",
        rawScore: latestCameraFrame ? 0.86 : 0.15,
        weight: 0.3,
        reason: "current kitchen camera frame"
      },
      {
        key: "live.ingredient_coverage",
        rawScore: ingredientCoverage(confirmedIngredients, recipe),
        weight: 0.2,
        reason: "confirmed ingredient coverage"
      },
      {
        key: "gemini.live_scene",
        rawScore: Math.max(0, Math.min(parsed.modelConfidence ?? 0.45, 1)),
        weight: 0.25,
        reason: "Gemini live scene assessment"
      }
    ],
    hardFailReasons
  };

  const assessment = confidenceService.assess(confidenceRequest);

  return {
    currentStep: parsed.currentStep ?? "Observe the scene",
    guidance:
      parsed.guidance ??
      "I need a clearer view before I can guide the next cooking step confidently.",
    observedIngredients: parsed.observedIngredients ?? [],
    kitchenRisks: parsed.kitchenRisks ?? [],
    confidence_assessment: assessment
  };
}
