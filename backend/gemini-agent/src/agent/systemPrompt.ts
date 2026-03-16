import { Type, type Tool } from "@google/genai";

// ─── System Prompt ────────────────────────────────────────────────────────────

export const SYSTEM_PROMPT = `
You are FridgeLuck's smart-fridge assistant, powered by Gemini Live.

## Role
Help users scan their fridge/pantry, identify ingredients, generate recipes, track inventory, and plan restocking — all with ingredient-level accuracy.

## Confidence Policy (MANDATORY — never violate these rules)

1. You MUST NOT claim "exact macros" or "exact calories" unless the confidence_assessment returned by the tool has mode="exact" and deterministicReady=true.
2. If mode="review_required", present results as "estimated" and ask the user to confirm ingredient amounts before finalising.
3. If mode="estimate_only", never state specific gram amounts or macro totals. Use phrases like "roughly", "approximately", or "this looks like it could be".
4. Inventory mutations (add/remove items) are FORBIDDEN until the user explicitly confirms the final ingredient list.
5. Always include the confidence rationale from the tool response in your reply so users understand certainty levels.

## Tool Usage Rules

- Use scan_fridge when the user shows you a fridge or pantry.
- Use reverse_scan_meal when the user shows you a cooked dish or plated meal.
- Use generate_recipe when the user wants recipe suggestions from available ingredients.
- Use mutate_inventory only AFTER the user has confirmed the ingredient list.
- Use get_restock_plan when the user asks about expiring food or what to buy.

## Persona
Be warm, practical, and concise. You are a cooking assistant, not a nutritionist. Avoid overwhelming detail. Use bullet lists for ingredient confirmations.
`.trim();

// ─── Tool Declarations ────────────────────────────────────────────────────────

export const TOOL_DECLARATIONS: Tool[] = [
  {
    functionDeclarations: [
      {
        name: "scan_fridge",
        description:
          "Analyse a fridge or pantry photo to identify available ingredients with confidence scores. Returns detected ingredients and a confidence assessment.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            photoBase64JPEG: {
              type: Type.STRING,
              description: "Base64-encoded JPEG image of the fridge or pantry."
            },
            existingInventoryNames: {
              type: Type.ARRAY,
              items: { type: Type.STRING },
              description: "Optional list of ingredient names already in the user's inventory ledger for cross-reference."
            }
          },
          required: ["photoBase64JPEG"]
        }
      },
      {
        name: "reverse_scan_meal",
        description:
          "Analyse a photo of a cooked or plated meal to identify the recipe match and infer ingredients with portion estimates. Returns ranked recipe candidates and confidence assessment.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            photoBase64JPEG: {
              type: Type.STRING,
              description: "Base64-encoded JPEG image of the meal."
            },
            mealDescription: {
              type: Type.STRING,
              description: "Optional short description of the meal from the user."
            }
          },
          required: ["photoBase64JPEG"]
        }
      },
      {
        name: "generate_recipe",
        description:
          "Generate a recipe using the user's available ingredients. Returns a structured recipe with time, servings, and estimated calories.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            ingredientNames: {
              type: Type.ARRAY,
              items: { type: Type.STRING },
              description: "List of ingredient names available."
            },
            dietaryRestrictions: {
              type: Type.ARRAY,
              items: { type: Type.STRING },
              description: "Optional dietary restrictions, e.g. ['gluten-free', 'dairy-free']."
            },
            scanConfidenceScore: {
              type: Type.NUMBER,
              description: "Overall confidence score from the preceding scan (0–1)."
            },
            photoBase64JPEG: {
              type: Type.STRING,
              description: "Optional photo to visually ground the recipe suggestion."
            }
          },
          required: ["ingredientNames"]
        }
      },
      {
        name: "mutate_inventory",
        description:
          "Add or remove ingredients from the user's inventory ledger. Only call this AFTER the user has explicitly confirmed the ingredient list. Requires an idempotency key.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            operation: {
              type: Type.STRING,
              description: "'add' to add ingredients (e.g. after scan), 'decrement' to consume (e.g. after cooking)."
            },
            idempotencyKey: {
              type: Type.STRING,
              description: "Stable unique key for this mutation. Use a UUID or session+timestamp."
            },
            items: {
              type: Type.ARRAY,
              items: {
                type: Type.OBJECT,
                properties: {
                  ingredientName: { type: Type.STRING },
                  quantityGrams: { type: Type.NUMBER },
                  expiresAt: { type: Type.STRING, description: "ISO 8601 date string, e.g. '2026-03-15'" },
                  source: { type: Type.STRING, description: "'scan' | 'manual' | 'restock'" }
                },
                required: ["ingredientName", "quantityGrams"]
              },
              description: "Ingredients to add or decrement."
            }
          },
          required: ["operation", "idempotencyKey", "items"]
        }
      },
      {
        name: "get_restock_plan",
        description:
          "Analyse the current inventory to identify items expiring soon and ingredients that need restocking. Returns use-soon alerts and a restock list.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            thresholdDays: {
              type: Type.NUMBER,
              description: "Days remaining before expiry that counts as 'use soon'. Defaults to 3."
            },
            restockBelowGrams: {
              type: Type.NUMBER,
              description: "Grams below which an ingredient should be restocked. Defaults to 50."
            }
          },
          required: []
        }
      }
    ]
  }
];
