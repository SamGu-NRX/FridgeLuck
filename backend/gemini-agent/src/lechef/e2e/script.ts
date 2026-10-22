/**
 * The scripted cook session the LeChef end-to-end walk drives over a real
 * WebSocket (backend ⇄ apps/ios/Tools/lechef-e2e).
 *
 * The fake model is the suite's own scripted model vocabulary
 * (src/lechef/suite/scripts.ts): deterministic turns of user text + tool
 * calls. The walk's Swift client sends each turn's user text as
 * `client_content`; the boot's fake live session answers with the turn's tool
 * calls, exactly the function-call surface the gateway already dispatches.
 *
 * Scenario: Ana (wheat allergy) is cooking a five-step recipe and is on step
 * 2. The model proposes a timer (approved, applied), proposes a butter → soy
 * sauce swap (the recheck hard-blocks: soy sauce carries wheat → rejected
 * receipt carrying the unsupported recheck), proposes a butter -> olive oil
 * swap instead (the recheck screens clean -> executed receipt carrying the
 * verified recheck), then proposes a step advance AFTER the cook
 * has finished the recipe on the device — the proposal was built against the
 * stale snapshot (step 2, cooking) and the phone refuses it.
 */

import type { ModelTurn } from "../suite/scripts.js";

/** The user texts the walk sends, in order — the fake model keys turns on them. */
export const TURN_TIMER = "start a three minute timer for the noodles";
export const TURN_SWAP = "I am out of butter — what can I use instead?";
export const TURN_SWAP_OK = "olive oil instead of butter then";
export const TURN_STALE_STEP = "move to the next step";

export const cookSessionTurns: readonly ModelTurn[] = [
  {
    userText: TURN_TIMER,
    utterance: "Proposing a three minute timer for the noodles.",
    calls: [
      {
        name: "proposeTimerStart",
        args: {
          durationMinutes: 3,
          label: "noodles",
          rationale: "step 2 tosses the noodles; a 3 minute timer covers it",
        },
      },
    ],
  },
  {
    userText: TURN_SWAP,
    utterance: "Checking the reviewed table and rechecking every eater's restrictions.",
    calls: [
      { name: "lookupSubstitution", args: { ingredient: "butter" } },
      {
        name: "proposeSwap",
        args: {
          originalIngredientId: 2,
          substituteIngredientId: 9001,
          role: "fat",
          rationale: "butter is short; the substitute covers the fat role",
        },
      },
    ],
  },
  {
    userText: TURN_SWAP_OK,
    utterance: "Checking the reviewed table and rechecking every eater's restrictions.",
    calls: [
      { name: "lookupSubstitution", args: { ingredient: "butter" } },
      {
        name: "proposeSwap",
        args: {
          originalIngredientId: 2,
          substituteIngredientId: 9002,
          role: "fat",
          rationale: "butter is short; olive oil covers the fat role",
        },
      },
    ],
  },
  {
    userText: TURN_STALE_STEP,
    utterance: "Proposing the next step.",
    calls: [
      { name: "getStepContext", args: {} },
      {
        name: "proposeStepAdvance",
        args: { stepIndex: 3, rationale: "the cook sounds ready for the next step" },
      },
    ],
  },
];

/** The bounded snapshot the walk uploads once per session (SPEC §9.6). */
export const boundedSnapshotPayload = {
  revision: 7,
  pantrySnapshot: {
    revision: 7,
    items: [
      {
        ingredientId: "chicken-breast",
        name: "chicken breast",
        state: "sufficient",
        source: "scan",
        quantity: { kind: "known", value: 600, unit: "g" },
      },
      {
        ingredientId: "butter",
        name: "butter",
        state: "short",
        source: "scan",
        quantity: { kind: "known", value: 20, unit: "g" },
        shortBy: 30,
      },
    ],
  },
  cookSession: {
    state: "cooking",
    currentStepIndex: 2,
    eaters: [{ name: "Ana", restrictions: ["wheat_gluten"] }],
    activeTimers: [],
    cameraMode: "push-to-look",
  },
  recipes: [],
};
