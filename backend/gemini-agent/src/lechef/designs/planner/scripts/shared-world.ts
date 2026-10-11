/**
 * Shared deterministic world for the planner's design scripts.
 *
 * One pantry, one three-recipe catalog, one eater — every fixture replays
 * against the same bounded world so differences between runs come from the
 * design's gating, not from fixture drift. Clock starts 2026-01-05T18:05Z
 * (a weekday evening — the planner's moment).
 */

import type { PantryLine, RecipeContext } from "../../../types.js";
import type { ScriptTurn } from "../../../fakeModel.js";

export const NOW_ISO = "2026-01-05T18:05:00.000Z";

/** Use-soon first (spinach, yogurt), then stock, then the assumed staple. */
export const PANTRY: readonly PantryLine[] = [
  {
    ingredientId: "ing-spinach",
    name: "Spinach",
    quantity: { kind: "known", value: 150, unit: "g" },
    state: "sufficient",
    source: "scan",
    useSoon: true
  },
  {
    ingredientId: "ing-yogurt",
    name: "Yogurt",
    quantity: { kind: "known", value: 200, unit: "g" },
    state: "sufficient",
    source: "scan",
    useSoon: true
  },
  {
    ingredientId: "ing-eggs",
    name: "Eggs",
    quantity: { kind: "known", value: 6, unit: "piece" },
    state: "sufficient",
    source: "scan"
  },
  {
    ingredientId: "ing-rice",
    name: "Rice",
    quantity: { kind: "known", value: 500, unit: "g" },
    state: "sufficient",
    source: "receipt"
  },
  {
    ingredientId: "ing-soy",
    name: "Soy sauce",
    quantity: { kind: "unknown" },
    state: "assumed-staple",
    source: "manual"
  }
];

/** Three structured candidates: shakshuka (fit), curry (one gap), noodles (fastest). */
export const RECIPES: readonly RecipeContext[] = [
  {
    id: "r-shakshuka",
    revision: 3,
    title: "Egg shakshuka",
    servings: 2,
    ingredientBill: [
      { ingredientId: "ing-eggs", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" } },
      { ingredientId: "ing-spinach", name: "Spinach", quantity: { kind: "known", value: 100, unit: "g" } },
      { ingredientId: "ing-tomato", name: "Tomatoes", quantity: { kind: "known", value: 400, unit: "g" } },
      { ingredientId: "ing-feta", name: "Feta", quantity: { kind: "known", value: 50, unit: "g" }, optional: true }
    ],
    steps: [
      { index: 0, text: "Soften the tomatoes" },
      { index: 1, text: "Simmer the sauce", timerMinutes: 12, safetyCheckTarget: "eggs" },
      { index: 2, text: "Crack in the eggs", timerMinutes: 9 }
    ]
  },
  {
    id: "r-curry",
    revision: 2,
    title: "Butter bean curry",
    servings: 2,
    ingredientBill: [
      { ingredientId: "ing-beans", name: "Butter beans", quantity: { kind: "known", value: 400, unit: "g" } },
      { ingredientId: "ing-spinach", name: "Spinach", quantity: { kind: "known", value: 100, unit: "g" } },
      { ingredientId: "ing-rice", name: "Rice", quantity: { kind: "known", value: 200, unit: "g" } }
    ],
    steps: [
      { index: 0, text: "Fry the onions" },
      { index: 1, text: "Simmer the curry", timerMinutes: 12 },
      { index: 2, text: "Wilt the spinach" },
      { index: 3, text: "Steam the rice", timerMinutes: 8 }
    ]
  },
  {
    id: "r-noodles",
    revision: 1,
    title: "Weeknight noodles",
    servings: 1,
    ingredientBill: [
      { ingredientId: "ing-eggs", name: "Eggs", quantity: { kind: "known", value: 2, unit: "piece" } },
      { ingredientId: "ing-noodles", name: "Noodles", quantity: { kind: "known", value: 150, unit: "g" } },
      { ingredientId: "ing-soy", name: "Soy sauce", quantity: { kind: "unknown" } }
    ],
    steps: [
      { index: 0, text: "Boil the noodles", timerMinutes: 6 },
      { index: 1, text: "Scramble the eggs into the pan" }
    ]
  }
];

/** Planning sessions open with no pick yet; cook sessions point at the curry. */
export const EATERS: readonly { readonly name: string; readonly restrictions: readonly string[] }[] = [
  { name: "Sam", restrictions: [] }
];

/**
 * Fresh turn builders with a per-script counter — every fixture constructs
 * its own pair so scripts never share mutable sequencing state.
 */
export function makeTurns(): {
  userTurn: (text: string, audioSeconds?: number) => ScriptTurn;
  assistantTurn: (
    text: string,
    options?: {
      calls?: readonly { id: string; name: string; args?: Record<string, unknown>; userInitiated?: boolean }[];
      prompted?: boolean;
    }
  ) => ScriptTurn;
} {
  let next = 0;
  return {
    userTurn(text, audioSeconds = 2) {
      return { i: next++, role: "user", text, audioSeconds };
    },
    assistantTurn(text, options = {}) {
      return {
        i: next++,
        role: "assistant",
        text,
        ...(options.calls !== undefined && options.calls.length > 0
          ? {
              toolCalls: options.calls.map((c) => ({
                id: c.id,
                name: c.name,
                ...(c.args !== undefined ? { args: c.args } : {}),
                ...(c.userInitiated === true ? { userInitiated: true } : {})
              }))
            }
          : {}),
        ...(options.prompted === true ? { prompted: true } : {})
      };
    }
  };
}

/** Timer-start proposal call as the planner's opening batch makes them. */
export function timerStartCall(id: string, label: string, minutes: number, userInitiated = false) {
  return { id, name: "proposeTimerStart", args: { label, minutes, userInitiated } };
}
