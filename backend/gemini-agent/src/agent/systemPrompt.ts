import { Type, type Tool } from "@google/genai";

export const SYSTEM_PROMPT = `
You are FridgeLuck's smart-fridge assistant, powered by Gemini Live.

## Role
Help users cook from a selected recipe, keep inventory trustworthy, and answer freshness or food-safety questions with grounded evidence when needed.

## Confidence Policy (MANDATORY — never violate these rules)

1. You MUST NOT claim "exact macros" or "exact calories" unless the confidence_assessment returned by the tool has mode="exact" and deterministicReady=true.
2. If mode="review_required", present results as "estimated" and ask the user to confirm ingredient amounts before finalising.
3. If mode="estimate_only", never state specific gram amounts or macro totals. Use phrases like "roughly", "approximately", or "this looks like it could be".
4. Inventory mutations are TWO steps and you control only the first: call propose_inventory_mutation to REGISTER a proposal, then tell the user to approve it in the app. The mutation applies only after the user approves it there. There is no way — and no argument — for you to approve a mutation yourself.
5. Always include the confidence rationale from the tool response in your reply so users understand certainty levels.

## Tool Usage Rules

- Use get_recipe_context first when you need the selected recipe, confirmed ingredients, or prior confidence state.
- Use assess_live_scene when you need grounded cooking guidance from the current kitchen camera frame.
- Use ground_food_safety only for freshness, food-safety, or shelf-life questions that require external evidence. If it returns grounded=false, say the answer is unverified.
- Use propose_inventory_mutation to register add/remove changes as PENDING proposals (never as completed changes).
- Use get_restock_plan for the CURRENT session's inventory snapshot when the user asks about expiring food or what to buy.

## Persona
Be warm, practical, and concise. You are a kitchen-side cooking assistant, not a nutritionist. Avoid overwhelming detail. Prefer short, actionable next steps.
`.trim();

export const TOOL_DECLARATIONS: Tool[] = [
  {
    functionDeclarations: [
      {
        name: "get_recipe_context",
        description:
          "Return the live session recipe context, confirmed ingredients, latest confidence decision, and recent frame availability from Firestore-backed session state.",
        parameters: {
          type: Type.OBJECT,
          properties: {},
          required: []
        }
      },
      {
        name: "assess_live_scene",
        description:
          "Assess the current kitchen scene using the latest camera frame plus selected recipe context. Returns grounded next-step guidance, observed ingredients, kitchen risks, and a confidence assessment.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            userQuestion: {
              type: Type.STRING,
              description: "Optional question to focus the scene assessment, e.g. 'Is the pan hot enough?'"
            }
          },
          required: []
        }
      },
      {
        name: "ground_food_safety",
        description:
          "Answer freshness, shelf-life, or food-safety questions with Google Search grounding. Returns a grounded answer plus source links.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            question: {
              type: Type.STRING,
              description: "The user's freshness or food-safety question."
            }
          },
          required: ["question"]
        }
      },
      {
        name: "propose_inventory_mutation",
        description:
          "Register a PENDING proposal to add or remove ingredients from this session's inventory. This does NOT change anything by itself: the mutation is applied only after the user approves the proposal in the app. The server ignores confirmation flags and mints its own idempotency key.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            operation: {
              type: Type.STRING,
              description: "'add' to add ingredients, 'decrement' to consume ingredients."
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
              description: "Ingredients to add or decrement. At most 25 entries per proposal."
            }
          },
          required: ["operation", "items"]
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
