import { Type, type Tool } from "@google/genai";

/**
 * System prompt + tool declarations for the live session.
 *
 * SPEC §8.3: the tool surface is the four legacy read tools plus the 15
 * registered LeChef tools (six reads, nine proposal tools). The old
 * `mutate_inventory` declaration is gone — the backend never writes to the
 * phone's truth; it proposes, the phone executes on approval.
 */

export const SYSTEM_PROMPT = `
You are LeChef, FridgeLuck's cooking companion, powered by Gemini Live.

## Role
Coach the cook through the current recipe step, keep the pantry view honest, and answer freshness or food-safety questions with grounded evidence. The phone is authoritative: you READ bounded snapshots and PROPOSE typed actions — you never execute anything yourself.

## The five jobs
Plan, substitute, coach, adapt, remember. Keep every answer in the job the cook is in: one step, one timer, one swap at a time.

## Confidence Policy (MANDATORY — never violate these rules)

1. You MUST NOT claim "exact macros" or "exact calories" unless the confidence_assessment returned by the tool has mode="exact" and deterministicReady=true.
2. If mode="review_required", present results as "estimated" and ask the user to confirm ingredient amounts before finalising.
3. If mode="estimate_only", never state specific gram amounts or macro totals. Use phrases like "roughly", "approximately", or "this looks like it could be".
4. Never present exact macro or gram numbers that the tools did not compute server-side.

## Proposal rules (MANDATORY)

- propose* tools SUBMIT a proposal to the phone; they never execute anything. The phone approves, executes, and returns a receipt. Claim success ONLY when the receipt you received has state="executed".
- The phone decides approval. requiredApproval in a result is an audit annotation, never permission.
- A meal log (proposeMealLog) is ALWAYS explicit: a voice transcript alone never authorizes it, and you must never treat spoken words as approval.
- Every proposal needs a short rationale (one sentence, under 280 characters) saying why you propose it.
- Timer proposals may cite userInitiationEventId ONLY when the phone's session snapshot actually contains that device event — never invent an event id.
- Never propose a share or a publish — they are not proposable.
- Camera looks (cameraLook) describe what a picture can show and name what they cannot assess. They are structurally incapable of a safety verdict: NEVER give a doneness or safety verdict from a camera look — direct the cook to checkFoodSafety's thermometer test instead.

## Tool Usage Rules

- Use getStepContext first while cooking: the current step, its timer and doneness target, live timers.
- Use getPantry for the bounded pantry view; use getPlan for dinner candidates ranked by honest fit.
- Use checkFoodSafety for doneness and shelf-life questions — it returns a checkable thermometer test from a named source, or an explicit unknown. Unknown products stay unknown; never guess a temperature.
- Use lookupSubstitution for swaps; label beyond-table answers as "not from the reviewed table", and never offer a suggestion the allergen recheck blocked.
- Use get_recipe_context, assess_live_scene, get_restock_plan, and ground_food_safety for the older chat surfaces (recipe context, grounded scene assessment, restock, external food-safety evidence).
- Use the propose* tools to act: timers, step advance, inventory corrections, meal logs, notes, plans, swaps, adaptations.

## Persona
Be warm, practical, and concise. You are a kitchen-side cooking companion, not a nutritionist. Prefer short, actionable next steps: one step, one timer, one swap at a time.
`.trim();

const READ_ONLY_OBJECT: { type: typeof Type.OBJECT; properties: {}; required: [] } = {
  type: Type.OBJECT,
  properties: {},
  required: []
};

export const TOOL_DECLARATIONS: Tool[] = [
  {
    functionDeclarations: [
      // ---- legacy live-session reads (chat surfaces) ----
      {
        name: "get_recipe_context",
        description:
          "Return the live session recipe context, confirmed ingredients, latest confidence decision, and whether a recent camera frame exists (never the frame itself).",
        parameters: READ_ONLY_OBJECT
      },
      {
        name: "assess_live_scene",
        description:
          "Assess the current kitchen scene using the latest camera frame from the in-memory cache plus selected recipe context. Returns grounded next-step guidance, observed ingredients, kitchen risks, and a confidence assessment. Never a doneness or safety verdict.",
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
      },

      // ---- LeChef reads (SPEC §8.3) ----
      {
        name: "getPantry",
        description:
          "The bounded pantry snapshot the phone sent for this session: ingredient lines with honest states (sufficient, short, quantity-unknown, assumed-staple, needs-reconfirming) and which lines need confirmation. Read-only.",
        parameters: READ_ONLY_OBJECT
      },
      {
        name: "getStepContext",
        description:
          "Where the cook is: the current step and its text, timer and doneness target, step count, live device timers, recent step moves, and the camera mode. Read-only.",
        parameters: READ_ONLY_OBJECT
      },
      {
        name: "getPlan",
        description:
          "Recipe candidates ranked by honest fit against the bounded pantry snapshot: fit lines count every required line; never a percentage. Read-only.",
        parameters: READ_ONLY_OBJECT
      },
      {
        name: "checkFoodSafety",
        description:
          "Doneness as a checkable thermometer test from a named reviewed source. Uncovered products return an explicit unknown — never a colour, never a time, never a guess.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            product: {
              type: Type.STRING,
              description: "The food to check, e.g. 'chicken breast'. Omit to use the current step's doneness target."
            }
          },
          required: []
        }
      },
      {
        name: "cameraLook",
        description:
          "A device-mediated camera look: the phone performs the look and returns what a picture can show and what it cannot assess. Structurally incapable of a safety verdict.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            mode: {
              type: Type.STRING,
              description: "'push-to-look' (one frame or a short clip, the default) or 'continuous'."
            }
          },
          required: []
        }
      },
      {
        name: "lookupSubstitution",
        description:
          "The reviewed substitution table answer for an ingredient, rechecked against ALL eaters' restrictions. No reviewed entry means an explicit beyond-table answer — label it as reasoning, not a reviewed swap.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            ingredient: {
              type: Type.STRING,
              description: "The ingredient to replace."
            },
            context: {
              type: Type.STRING,
              description: "Optional context, e.g. the dish or the role the ingredient plays."
            }
          },
          required: ["ingredient"]
        }
      },

      // ---- LeChef proposals (SPEC §8.3) — routed to the phone, never executed here ----
      {
        name: "proposeTimerStart",
        description:
          "Propose a new device timer. The phone creates it on approval; a proposal citing a valid phone-recorded device event may execute device-auto. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            durationMinutes: { type: Type.NUMBER, description: "Minutes (0 < m <= 180)." },
            label: { type: Type.STRING, description: "Short timer label, e.g. 'Noodles'." },
            rationale: { type: Type.STRING, description: "One sentence: why this timer now." },
            userInitiationEventId: {
              type: Type.STRING,
              description: "ONLY when the session snapshot contains that phone-recorded device event; never invented."
            }
          },
          required: ["durationMinutes", "rationale"]
        }
      },
      {
        name: "proposeTimerAdjust",
        description:
          "Propose adjusting an existing device timer. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            timerId: { type: Type.STRING, description: "The id of the timer to adjust." },
            newDurationMinutes: { type: Type.NUMBER, description: "New duration in minutes." },
            rationale: { type: Type.STRING, description: "One sentence: why adjust." },
            userInitiationEventId: {
              type: Type.STRING,
              description: "ONLY when the session snapshot contains that phone-recorded device event; never invented."
            }
          },
          required: ["timerId", "rationale"]
        }
      },
      {
        name: "proposeStepAdvance",
        description:
          "Propose moving the cook to a step. The phone executes on the user's explicit approval. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            stepIndex: { type: Type.NUMBER, description: "The step index to move to." },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["stepIndex", "rationale"]
        }
      },
      {
        name: "proposeInventoryCorrection",
        description:
          "Propose correcting one wrong pantry line (never a bulk write). Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            ingredientId: { type: Type.NUMBER, description: "The integer id of the pantry line to correct." },
            correction: { type: Type.STRING, description: "Short correction note (<= 120 chars)." },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["ingredientId", "correction", "rationale"]
        }
      },
      {
        name: "proposeMealLog",
        description:
          "Propose logging a cooked meal. ALWAYS explicit approval: a voice transcript alone never authorizes it. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            recipe: {
              type: Type.OBJECT,
              properties: {
                source: { type: Type.STRING, description: "'catalog' | 'user' | 'community' | 'generated'." },
                id: { type: Type.STRING, description: "The recipe id." },
                revision: { type: Type.NUMBER, description: "The recipe revision (integer >= 1)." }
              },
              required: ["source", "id", "revision"],
              description: "The cooked recipe's reference."
            },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["recipe", "rationale"]
        }
      },
      {
        name: "proposeSaveNote",
        description:
          "Propose the save-note confirmation. The note's text NEVER leaves the phone — this carries only a prompt and a saved marker. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            prompt: { type: Type.STRING, description: "Confirmation prompt shown on the phone." },
            noteSavedMarker: { type: Type.BOOLEAN, description: "True when the phone already saved the note locally." },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["rationale"]
        }
      },
      {
        name: "proposePlan",
        description:
          "Propose a dinner plan. The phone runs its own allocation; the model may only shape constraints. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            dinnerCount: { type: Type.NUMBER, description: "Dinners to plan (integer 1..7)." },
            constraints: {
              type: Type.ARRAY,
              items: { type: Type.STRING },
              description: "Constraints from the cook, e.g. 'nothing with coriander'."
            },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["dinnerCount", "rationale"]
        }
      },
      {
        name: "proposeSwap",
        description:
          "Propose an ingredient swap. The phone runs the allergen recheck on approval; a blocked swap never executes. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            originalIngredientId: { type: Type.NUMBER, description: "Integer id of the ingredient being swapped out." },
            substituteIngredientId: { type: Type.NUMBER, description: "Integer id of the substitute." },
            role: {
              type: Type.STRING,
              description: "One of the eleven reviewed functional roles: acid, aromatic, binder, fat, garnish, leavening, liquid, protein, sweetener, thickener, umami."
            },
            rationale: { type: Type.STRING, description: "One sentence: why, including the difference the swap makes." }
          },
          required: ["originalIngredientId", "substituteIngredientId", "role", "rationale"]
        }
      },
      {
        name: "proposeAdaptation",
        description:
          "Propose an adaptation (servings or quantity change) under the reviewed rules. Returns the phone's receipt.",
        parameters: {
          type: Type.OBJECT,
          properties: {
            servings: { type: Type.NUMBER, description: "New servings (integer 1..12), when changing servings." },
            change: { type: Type.STRING, description: "Short description of the adaptation (<= 120 chars)." },
            rationale: { type: Type.STRING, description: "One sentence: why." }
          },
          required: ["change", "rationale"]
        }
      }
    ]
  }
];
