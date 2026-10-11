/**
 * Speech-budget fixtures — the coach's turnBudget {maxUnpromptedTurns: 2,
 * minGapTurns: 2}: a third unprompted interjection dies of budget, adjacent
 * unprompted turns die of min-gap, and actions scripted onto suppressed
 * turns reattach to the next kept turn.
 */

import type { CoachCase } from "./types.js";
import { call, coachScript, turn } from "./world.js";

/** coach-008 — two unprompted interjections used, the third is budget-exhausted. */
export const budgetExhausted: CoachCase = {
  name: "coach-008-budget-exhausted",
  focus: "after two kept unprompted turns, a third cleanly-gapped interjection is suppressed as budget-exhausted",
  script: coachScript({
    sessionId: "coach-008",
    turns: [
      turn(0, "assistant", "use-soon: the spinach — oldest bag in the pantry, step 4 wilts it in.", {
        toolCalls: [call("c-pantry", "getPantrySummary")]
      }),
      turn(1, "user", "ok", { audioSeconds: 0.3 }),
      turn(2, "assistant", "noted."),
      turn(3, "assistant", "safety: chicken needs 74 °C at the thickest piece before you move on.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken" })]
      }),
      turn(4, "user", "on it", { audioSeconds: 0.4 }),
      turn(5, "assistant", "thermometer's in the top drawer."),
      turn(6, "assistant", "use-soon: also, the butter's quantity is a mystery—")
    ]
  }),
  expect: {
    suppressed: [{ turn: 6, because: "budget-exhausted" }],
    keptTurns: [0, 1, 2, 3, 4, 5],
    toolStatus: [
      { id: "c-pantry", status: "ok" },
      { id: "c-fs", status: "ok" }
    ],
    donenessTemps: [74],
    usageTurns: 6
  }
};

/** coach-009 — adjacent unprompted turns violate the min gap; a user exchange re-arms it. */
export const minGapPacing: CoachCase = {
  name: "coach-009-min-gap",
  focus: "an unprompted turn right after another is suppressed for min-gap; one user exchange later, the coach may interject again",
  script: coachScript({
    sessionId: "coach-009",
    turns: [
      turn(0, "assistant", "safety: chicken needs 74 °C at the thickest piece — thermometer, not colour.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken" })]
      }),
      turn(1, "assistant", "use-soon: and the spinach wants step 4—"),
      turn(2, "user", "ok, thanks", { audioSeconds: 0.5 }),
      turn(3, "assistant", "you're set."),
      turn(4, "assistant", "substitution: the lime is short — ask me for a lemon swap when you want it.")
    ]
  }),
  expect: {
    suppressed: [{ turn: 1, because: "min-gap" }],
    keptTurns: [0, 2, 3, 4],
    toolStatus: [{ id: "c-fs", status: "ok" }],
    donenessTemps: [74],
    usageTurns: 4
  }
};

/** coach-010 — actions on suppressed turns remap to the next kept turn. */
export const suppressedActionRemap: CoachCase = {
  name: "coach-010-suppressed-action-remap",
  focus: "a kill and a clock advance scripted onto suppressed turns reattach to the next kept turn, nothing drops",
  script: coachScript({
    sessionId: "coach-010",
    turns: [
      turn(0, "assistant", "safety: chicken — 74 °C at the thickest piece.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken" })]
      }),
      turn(1, "assistant", "use-soon: the spinach—"),
      turn(2, "assistant", "and the butter's quantity is a mystery—"),
      turn(3, "user", "ok ok", { audioSeconds: 0.5 }),
      turn(4, "assistant", "quiet now — ask me anything.")
    ],
    userActions: [
      { afterTurn: 1, action: { kind: "kill" } },
      { afterTurn: 2, action: { kind: "advanceMinutes", minutes: 2 } }
    ]
  }),
  expect: {
    suppressed: [
      { turn: 1, because: "min-gap" },
      { turn: 2, because: "min-gap" }
    ],
    keptTurns: [0, 3, 4],
    toolStatus: [{ id: "c-fs", status: "ok" }],
    donenessTemps: [74],
    usageTurns: 3,
    remappedActions: [
      { from: 1, to: 3 },
      { from: 2, to: 3 }
    ],
    droppedActions: 0
  }
};
