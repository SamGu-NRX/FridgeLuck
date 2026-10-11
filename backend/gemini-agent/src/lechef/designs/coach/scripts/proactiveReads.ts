/**
 * Proactive READ fixtures — the coach's signature behavior: unprompted
 * checkFoodSafety and getPantrySummary reads pass the policy and reach the
 * layer, grounding safety and use-soon suggestions.
 */

import type { CoachCase } from "./types.js";
import { call, coachScript, turn } from "./world.js";

/** coach-001 — a proactive safety read at a safety-check step: allowed, sourced, recorded. */
export const proactiveSafetyRead: CoachCase = {
  name: "coach-001-proactive-safety-read",
  focus: "proactive checkFoodSafety/getStepContext reads pass the policy and land a sourced 74 °C doneness answer",
  script: coachScript({
    sessionId: "coach-001",
    turns: [
      turn(0, "assistant", "safety: step 3 is the chicken check — FSIS says 74 °C in the thickest piece; use the thermometer, not colour.", {
        toolCalls: [
          call("c-fs", "checkFoodSafety", { product: "chicken", question: "is it done" }),
          call("c-step", "getStepContext")
        ]
      }),
      turn(1, "user", "got it, checking now", { audioSeconds: 1.2 }),
      turn(2, "assistant", "take your time — I'll stay quiet until you ask.")
    ]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2],
    toolStatus: [
      { id: "c-fs", status: "ok" },
      { id: "c-step", status: "ok" }
    ],
    donenessTemps: [74],
    usageTurns: 3
  }
};

/** coach-002 — a proactive pantry read grounding a use-soon suggestion: allowed. */
export const proactivePantryUseSoon: CoachCase = {
  name: "coach-002-proactive-pantry-use-soon",
  focus: "a proactive getPantrySummary read grounds a use-soon suggestion in real pantry state",
  script: coachScript({
    sessionId: "coach-002",
    turns: [
      turn(0, "assistant", "use-soon: the spinach is the oldest bag in your pantry — it goes in at step 4, minutes away.", {
        toolCalls: [call("c-pantry", "getPantrySummary")]
      }),
      turn(1, "user", "fine, add it at step 4", { audioSeconds: 1.0 }),
      turn(2, "assistant", "noted — spinach at step 4.")
    ]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2],
    toolStatus: [{ id: "c-pantry", status: "ok" }],
    usageTurns: 3
  }
};
