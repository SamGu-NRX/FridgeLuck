/**
 * Scripted sessions for the offline LeChef suite (SPEC §7): a fake model that
 * replays scripted turns (utterance + tool calls), a script type, and the
 * session matrix builders.
 *
 * The suite covers the five jobs (timer-management, pantry-inventory,
 * dinner-planning, live-guidance, substitution-adaptation) across thirteen
 * situations each (baseline, offline, mic-denied, live-disconnect,
 * app-kill-relaunch, empty-kitchen, allergen-conflict, partial-data,
 * expired-proposal, stale-revision, voice-authorized-timer, duplicate-call,
 * unknown-product) — 65 sessions total, all deterministic (ManualClock).
 */

import type {
  CameraObservation,
  CookSessionSnapshot,
  Eater,
  PantryLine,
  ProposalTool,
  RecipeContext
} from "../types.js";

// ---------------------------------------------------------------------------
// Fake model
// ---------------------------------------------------------------------------

export interface ScriptedCall {
  readonly name: string;
  readonly args?: Record<string, unknown>;
}

export interface ModelTurn {
  readonly userText: string;
  /** What the assistant says this turn — the scorer lints this text. */
  readonly utterance?: string;
  readonly calls?: readonly ScriptedCall[];
}

/** The fake model: deterministic scripted turns, call ids validated by the runner. */
export class FakeModel {
  constructor(private readonly turns: readonly ModelTurn[]) {}

  turn(index: number): ModelTurn {
    if (index >= this.turns.length) throw new Error(`FakeModel: no scripted turn ${index}`);
    return this.turns[index];
  }

  get turnCount(): number {
    return this.turns.length;
  }
}

// ---------------------------------------------------------------------------
// Fixtures and scripts
// ---------------------------------------------------------------------------

export type SuiteAction =
  | { readonly kind: "approveAll" }
  | { readonly kind: "rejectAll" }
  | { readonly kind: "advanceMinutes"; readonly minutes: number }
  | { readonly kind: "deviceEvent"; readonly command: ProposalTool; readonly source: "voice" | "touch"; readonly detail?: string }
  | { readonly kind: "bumpRevision" }
  | { readonly kind: "killAndRelaunch" };

export interface SuiteFixture {
  readonly items: readonly PantryLine[];
  readonly eaters?: readonly Eater[];
  readonly recipes?: readonly RecipeContext[];
  readonly recipeId?: string;
  readonly sessionState?: CookSessionSnapshot["state"];
  readonly currentStepIndex?: number;
  readonly cameraMode?: "push-to-look" | "continuous";
  readonly cameraScript?: () => CameraObservation;
  /** Reviewed ingredient names for swap substitutes not present in the pantry. */
  readonly substituteNames?: ReadonlyMap<number, string>;
}

export interface SuiteScript {
  readonly id: string;
  readonly job: "timer-management" | "pantry-inventory" | "dinner-planning" | "live-guidance" | "substitution-adaptation";
  readonly situation: string;
  readonly fixture: SuiteFixture;
  readonly turns: readonly ModelTurn[];
  readonly actions?: readonly { readonly afterTurn: number; readonly action: SuiteAction }[];
}

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

const pantryLine = (
  ingredientId: string,
  name: string,
  state: PantryLine["state"],
  quantity: PantryLine["quantity"] = { kind: "unknown" },
  extra: Partial<PantryLine> = {}
): PantryLine => ({ ingredientId, name, state, quantity, source: "scan", ...extra });

export const BASE_PANTRY: readonly PantryLine[] = [
  pantryLine("chicken-breast", "chicken breast", "sufficient", { kind: "known", value: 600, unit: "g" }),
  pantryLine("soy-sauce", "soy sauce", "sufficient", { kind: "known", value: 250, unit: "ml" }),
  pantryLine("butter", "butter", "short", { kind: "known", value: 20, unit: "g" }, { shortBy: 30 }),
  pantryLine("lemon", "lemon", "quantity-unknown"),
  pantryLine("salt", "salt", "assumed-staple")
];

export const ALLERGEN_PANTRY: readonly PantryLine[] = [
  pantryLine("soy-sauce", "soy sauce", "sufficient", { kind: "known", value: 250, unit: "ml" }),
  pantryLine("tahini", "tahini", "sufficient", { kind: "known", value: 120, unit: "g" }),
  pantryLine("chicken-breast", "chicken breast", "sufficient", { kind: "known", value: 600, unit: "g" })
];

export const WHEAT_ALLERGY_EATER: Eater = { name: "Ana", restrictions: ["wheat-free"] };
export const SESAME_ALLERGY_EATER: Eater = { name: "Ben", restrictions: ["sesame-free"] };

const step = (index: number, text: string, timerMinutes?: number, safetyCheckTarget?: string) => ({
  index,
  text,
  ...(timerMinutes !== undefined ? { timerMinutes } : {}),
  ...(safetyCheckTarget !== undefined ? { safetyCheckTarget } : {})
});

export const CHICKEN_STIRFRY: RecipeContext = {
  id: "chicken-stirfry",
  revision: 3,
  title: "Chicken stir-fry",
  servings: 2,
  ingredientBill: [
    { ingredientId: "chicken-breast", name: "chicken breast", quantity: { kind: "known", value: 500, unit: "g" } },
    { ingredientId: "soy-sauce", name: "soy sauce", quantity: { kind: "known", value: 60, unit: "ml" } },
    { ingredientId: "butter", name: "butter", quantity: { kind: "known", value: 50, unit: "g" } },
    { ingredientId: "lemon", name: "lemon", quantity: { kind: "unknown" }, optional: true }
  ],
  steps: [
    step(0, "Slice the chicken into strips."),
    step(1, "Sear the chicken in a hot pan until the internal temperature reaches a safe level.", 6, "chicken breast"),
    step(2, "Add soy sauce and toss.", 2)
  ]
};

export const TAHINI_NOODLES: RecipeContext = {
  id: "tahini-noodles",
  revision: 1,
  title: "Tahini noodles",
  servings: 2,
  ingredientBill: [
    { ingredientId: "tahini", name: "tahini", quantity: { kind: "known", value: 80, unit: "g" } },
    { ingredientId: "soy-sauce", name: "soy sauce", quantity: { kind: "known", value: 45, unit: "ml" } }
  ],
  steps: [step(0, "Whisk the sauce."), step(1, "Toss with noodles.")]
};

export const BASE_RECIPES: readonly RecipeContext[] = [CHICKEN_STIRFRY, TAHINI_NOODLES];

/** Honest camera: describes what a picture can show, names what it cannot assess. */
export const honestCamera = (): CameraObservation => ({
  observed: ["a pan on the burner with browning chicken strips", "steam rising"],
  cannotAssess: ["internal doneness — a camera cannot assess it"],
  framesSent: 1,
  clipSeconds: 0
});

/** A verdict-shaped camera payload — the reads path must refuse to relay it (SPEC 3.1). */
export const verdictCamera = (): CameraObservation => ({
  observed: ["the chicken looks cooked through and safe to eat"],
  cannotAssess: [],
  framesSent: 1,
  clipSeconds: 0
});

// ---------------------------------------------------------------------------
// The session matrix — 5 jobs × 13 situations = 65 sessions
// ---------------------------------------------------------------------------

const SITUATIONS = [
  "baseline",
  "offline",
  "mic-denied",
  "live-disconnect",
  "app-kill-relaunch",
  "empty-kitchen",
  "allergen-conflict",
  "partial-data",
  "expired-proposal",
  "stale-revision",
  "voice-authorized-timer",
  "duplicate-call",
  "unknown-product"
] as const;

type Job = SuiteScript["job"];

/** The turn after which a job's last proposal lands (for TTL expiry timing). */
const EXPIRY_TURN: Record<Job, number> = {
  "timer-management": 0,
  "pantry-inventory": 2,
  "dinner-planning": 1,
  "live-guidance": 3,
  "substitution-adaptation": 1
};

/** Per-job base turns: a short scripted conversation exercising the job's tools. */
function baseTurns(job: Job, situation: string): ModelTurn[] {
  const rationale = (why: string): Record<string, unknown> => ({ rationale: why });
  switch (job) {
    case "timer-management":
      return [
        {
          userText: "start a two minute timer for the sear",
          utterance: "Proposing a two minute timer for the sear.",
          calls: [
            {
              name: "proposeTimerStart",
              args: {
                durationMinutes: 2,
                label: "sear",
                ...rationale("step 1 sears for 6 minutes; a 2 minute check-in timer"),
                ...(situation === "voice-authorized-timer"
                  ? { userInitiationEventId: "evt-proposeTimerStart-voice" } // cites the voice command recorded on the device
                  : {})
              }
            }
          ]
        },
        { userText: "how much time is left?", utterance: "The timer is running on the device.", calls: [{ name: "getStepContext" }] }
      ];
    case "pantry-inventory":
      return [
        { userText: "what do I have for stir-fry?", utterance: "Here is your pantry for this recipe.", calls: [{ name: "getPantry" }, { name: "getPlan" }] },
        {
          userText: "the lemon is actually two lemons",
          utterance: "Proposing that correction to your pantry.",
          calls: [{ name: "proposeInventoryCorrection", args: { ingredientId: 3, correction: "two lemons", ...rationale("user stated the lemon count") } }]
        },
        { userText: "and save a note that I used butter", utterance: "The note is saved on your device.", calls: [{ name: "proposeSaveNote", args: { noteSavedMarker: true, prompt: "used butter", ...rationale("user asked to save a note") } }] }
      ];
    case "dinner-planning":
      return [
        { userText: "plan three dinners this week", utterance: "Here is how three dinners fit your kitchen.", calls: [{ name: "getPantry" }, { name: "getPlan" }] },
        {
          userText: "swap butter for olive oil in the stir-fry",
          utterance: "Proposing that swap with an allergen recheck.",
          calls: [{ name: "proposeSwap", args: { originalIngredientId: 2, substituteIngredientId: 9001, role: "fat", ...rationale("butter is short; olive oil covers the fat role") } }]
        }
      ];
    case "live-guidance":
      return [
        { userText: "where am I in the recipe?", utterance: "You are on the sear step.", calls: [{ name: "getStepContext" }] },
        { userText: "take a look at the pan", utterance: "Here is what the camera can and cannot tell us.", calls: [{ name: "cameraLook" }] },
        { userText: "is the chicken done?", utterance: "Doneness is a thermometer check, not a look: the reviewed source says chicken breast is safe at 165 °F with a rest — check the thickest piece.", calls: [{ name: "checkFoodSafety", args: { product: "chicken breast" } }] },
        { userText: "I plated it", utterance: "Proposing to log the meal.", calls: [{ name: "proposeMealLog", args: { recipe: { source: "catalog", id: "chicken-stirfry", revision: 3 }, ...rationale("user says they plated the dish") } }] }
      ];
    case "substitution-adaptation":
      return [
        { userText: "I am out of butter — what can I use?", utterance: "Here is the reviewed substitution.", calls: [{ name: "lookupSubstitution", args: { ingredient: "butter" } }] },
        {
          userText: "scale it to four servings",
          utterance: "Proposing the scaling.",
          calls: [{ name: "proposeAdaptation", args: { servings: 4, change: "double the stir-fry", ...rationale("user asked for four servings") } }]
        }
      ];
  }
}

/** Per-situation fixture + action overrides. */
function applySituation(job: Job, situation: string, fixture: SuiteFixture, turns: ModelTurn[]): { fixture: SuiteFixture; turns: ModelTurn[]; actions: { afterTurn: number; action: SuiteAction }[] } {
  const actions: { afterTurn: number; action: SuiteAction }[] = [];
  switch (situation) {
    case "baseline":
      // The touch event exists BEFORE the proposal is submitted, so the phone
      // can bind it as device-auto initiation.
      actions.push({ afterTurn: -1, action: { kind: "deviceEvent", command: "proposeTimerStart", source: "touch", detail: "start timer" } });
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      actions.push({ afterTurn: 1, action: { kind: "approveAll" } });
      break;
    case "offline":
      actions.push({ afterTurn: 0, action: { kind: "bumpRevision" } });
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "mic-denied":
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "live-disconnect":
      actions.push({ afterTurn: 1, action: { kind: "bumpRevision" } });
      actions.push({ afterTurn: 1, action: { kind: "approveAll" } });
      break;
    case "app-kill-relaunch":
      actions.push({ afterTurn: 0, action: { kind: "killAndRelaunch" } });
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "empty-kitchen":
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "allergen-conflict":
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "partial-data":
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "expired-proposal":
      // Submit, let 10 minutes pass BEFORE approving: the approval lands
      // after the 300 s TTL → expired receipt (SPEC §8.1). The advance is
      // timed per job to land AFTER that job's last proposal-producing turn.
      actions.push({ afterTurn: EXPIRY_TURN[job]!, action: { kind: "advanceMinutes", minutes: 10 } });
      actions.push({ afterTurn: EXPIRY_TURN[job]!, action: { kind: "approveAll" } });
      break;
    case "stale-revision":
      // A revision bump between submission and approval: explicit approvals
      // still resolve, but the receipt records the CURRENT revision.
      actions.push({ afterTurn: 0, action: { kind: "bumpRevision" } });
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "voice-authorized-timer":
      // A transcribed voice command recorded on the device BEFORE submission
      // authorizes the timer proposal: device-auto, no separate approval.
      actions.push({ afterTurn: -1, action: { kind: "deviceEvent", command: "proposeTimerStart", source: "voice", detail: "start a two minute timer" } });
      break;
    case "duplicate-call":
      // The model retries the same call after a reorder — results must be
      // consistent; receipts resolve at most once.
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
    case "unknown-product":
      actions.push({ afterTurn: 0, action: { kind: "approveAll" } });
      break;
  }
  if (job === "pantry-inventory" && situation !== "expired-proposal") {
    actions.push({ afterTurn: 1, action: { kind: "approveAll" } });
    actions.push({ afterTurn: 2, action: { kind: "approveAll" } });
  }
  if (job === "dinner-planning" && situation !== "expired-proposal") {
    actions.push({ afterTurn: 1, action: { kind: "approveAll" } });
  }
  if (job === "live-guidance" && situation !== "expired-proposal") {
    actions.push({ afterTurn: 3, action: { kind: "approveAll" } });
  }
  if (job === "substitution-adaptation" && situation !== "expired-proposal") {
    actions.push({ afterTurn: 1, action: { kind: "approveAll" } });
  }

  let nextFixture = fixture;
  if (situation === "empty-kitchen") nextFixture = { ...fixture, items: [] };
  if (situation === "allergen-conflict") nextFixture = { ...fixture, items: ALLERGEN_PANTRY, eaters: [WHEAT_ALLERGY_EATER, SESAME_ALLERGY_EATER] };
  if (situation === "unknown-product" && job === "live-guidance") {
    nextFixture = { ...fixture };
    turns = turns.map((t, i) =>
      i === 2
        ? { ...t, calls: [{ name: "checkFoodSafety", args: { product: "dragonfruit-rare-variant" } }], utterance: "I have no reviewed thermometer test for that product, so I cannot give a temperature." }
        : t
    );
  }
  if (situation === "duplicate-call" && job === "pantry-inventory") {
    turns = turns.map((t, i) => (i === 0 ? { ...t, calls: [{ name: "getPantry" }, { name: "getPlan" }, { name: "getPantry" }] } : t));
  }
  if (situation === "partial-data" && job === "dinner-planning") {
    nextFixture = { ...fixture, items: [...BASE_PANTRY.slice(0, 2), pantryLine("salt", "salt", "needs-reconfirming")] };
  }
  return { fixture: nextFixture, turns, actions };
}

/** The full 65-script matrix, deterministically built. */
export function buildScripts(): SuiteScript[] {
  const scripts: SuiteScript[] = [];
  const jobs: Job[] = ["timer-management", "pantry-inventory", "dinner-planning", "live-guidance", "substitution-adaptation"];
  for (const job of jobs) {
    for (const situation of SITUATIONS) {
      const turns = baseTurns(job, situation);
      const baseFixture: SuiteFixture = {
        items: [...BASE_PANTRY],
        recipes: BASE_RECIPES,
        ...(job === "dinner-planning" || job === "substitution-adaptation" ? {} : { recipeId: "chicken-stirfry" }),
        currentStepIndex: 1,
        ...(job === "dinner-planning" ? { substituteNames: new Map([[9001, "olive oil"]]) } : {}),
        cameraScript: situation === "live-disconnect" ? verdictCamera : honestCamera
      };
      const applied = applySituation(job, situation, baseFixture, turns);
      scripts.push({
        id: `${job}:${situation}`,
        job,
        situation,
        fixture: applied.fixture,
        turns: applied.turns,
        actions: applied.actions
      });
    }
  }
  return scripts;
}
