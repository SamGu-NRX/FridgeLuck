/**
 * Shared deterministic world for the coach fixture scripts: one cook session
 * (chicken stir-fry, step 3 = the safety-critical stir-fry), a pantry with a
 * use-soon item, a short item, and an unknown-quantity item, one eater with
 * a wheat restriction, and a canned push-to-look camera. Every script starts
 * from this world so expectations stay comparable across scripts.
 */

import type { EpochSeconds, PantryLine, RecipeContext } from "../../../types.js";
import type {
  LeChefJob,
  ScriptFixture,
  ScriptToolCall,
  ScriptTurn,
  SessionScript,
  ScriptUserAction
} from "../../../fakeModel.js";

/** Brand a plain epoch-seconds number for the pantry's expiresAt field. */
function epochSec(n: number): EpochSeconds {
  return n as EpochSeconds;
}

export const WORLD_NOW_ISO = "2026-01-15T17:30:00Z";

/** Deterministic pantry: chicken (sufficient), spinach (use-soon), soy (staple), lime (short), butter (unknown). */
export const WORLD_PANTRY: readonly PantryLine[] = [
  {
    ingredientId: "ing-chicken",
    name: "chicken breast",
    quantity: { kind: "known", value: 2, unit: "count" },
    state: "sufficient",
    source: "scan"
  },
  {
    ingredientId: "ing-spinach",
    name: "spinach",
    quantity: { kind: "known", value: 1, unit: "bag" },
    state: "sufficient",
    source: "scan",
    useSoon: true,
    expiresAt: epochSec(1768646400)
  },
  {
    ingredientId: "ing-lemon",
    name: "lemon",
    quantity: { kind: "known", value: 2, unit: "count" },
    state: "sufficient",
    source: "scan"
  },
  {
    ingredientId: "ing-soy",
    name: "soy sauce",
    quantity: { kind: "known", value: 300, unit: "ml" },
    state: "sufficient",
    source: "manual"
  },
  {
    ingredientId: "ing-lime",
    name: "lime",
    quantity: { kind: "known", value: 1, unit: "count" },
    state: "short",
    shortBy: 1,
    source: "scan"
  },
  {
    ingredientId: "ing-butter",
    name: "butter",
    quantity: { kind: "unknown" },
    state: "quantity-unknown",
    source: "manual"
  }
];

/** The cook-session recipe: four steps, step 2 (0-based) is the safety check. */
export const WORLD_RECIPE: RecipeContext = {
  id: "stir-fry",
  revision: 3,
  title: "Chicken stir-fry",
  servings: 2,
  ingredientBill: [
    { ingredientId: "ing-chicken", name: "chicken breast", quantity: { kind: "known", value: 2, unit: "count" } },
    { ingredientId: "ing-spinach", name: "spinach", quantity: { kind: "known", value: 1, unit: "bag" } },
    { ingredientId: "ing-soy", name: "soy sauce", quantity: { kind: "known", value: 30, unit: "ml" } },
    { ingredientId: "ing-lime", name: "lime", quantity: { kind: "known", value: 1, unit: "count" } }
  ],
  steps: [
    { index: 0, text: "Slice the chicken into strips." },
    { index: 1, text: "Heat the pan and sear the chicken.", timerMinutes: 6 },
    { index: 2, text: "Stir-fry the chicken until done.", safetyCheckTarget: "chicken" },
    { index: 3, text: "Wilt the spinach in, dress with soy and lime." }
  ]
};

const WORLD_SESSION = {
  recipeId: "stir-fry",
  state: "cooking" as const,
  currentStepIndex: 2,
  eaters: [{ name: "Sam", restrictions: ["wheat"] }]
};

const WORLD_CAMERA = {
  framesPerLook: 2,
  clipSeconds: 2,
  observed: ["browning on the chicken", "steam rising"],
  cannotAssess: ["internal temperature"]
};

const WORLD_FIXTURE: ScriptFixture = {
  nowIso: WORLD_NOW_ISO,
  pantry: WORLD_PANTRY,
  session: WORLD_SESSION,
  recipes: [WORLD_RECIPE],
  camera: WORLD_CAMERA
};

export function call(id: string, name: string, args: Readonly<Record<string, unknown>> = {}): ScriptToolCall {
  return { id, name, ...(Object.keys(args).length > 0 ? { args } : {}) };
}

export function turn(
  i: number,
  role: "user" | "assistant",
  text: string,
  extra: { toolCalls?: readonly ScriptToolCall[]; audioSeconds?: number } = {}
): ScriptTurn {
  return {
    i,
    role,
    text,
    ...(extra.toolCalls !== undefined ? { toolCalls: extra.toolCalls } : {}),
    ...(extra.audioSeconds !== undefined ? { audioSeconds: extra.audioSeconds } : {})
  };
}

export interface CoachScriptInput {
  readonly sessionId: string;
  /** Defaults to "coach"; the substitution-grounded scripts use "substitute". */
  readonly job?: LeChefJob;
  readonly turns: readonly ScriptTurn[];
  readonly userActions?: readonly { readonly afterTurn: number; readonly action: ScriptUserAction }[];
}

/** Build a coach session script on the shared world. */
export function coachScript(input: CoachScriptInput): SessionScript {
  return {
    sessionId: input.sessionId,
    job: input.job ?? "coach",
    cameraMode: "push-to-look",
    design: "coach",
    turns: input.turns,
    ...(input.userActions !== undefined ? { userActions: input.userActions } : {}),
    fixture: WORLD_FIXTURE
  };
}
