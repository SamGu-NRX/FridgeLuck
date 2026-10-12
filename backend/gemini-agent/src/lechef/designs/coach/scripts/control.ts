/**
 * The prompted-only control — every assistant turn answers a user turn, so
 * nothing is proactive: zero suppression, zero denials. It is the
 * equivalence baseline for the permissive design variant (see the design's
 * equivalence tests) and the reference for what the coach adds.
 */

import type { CoachCase } from "./types.js";
import { call, coachScript, turn } from "./world.js";

export const promptedOnlyControl: CoachCase = {
  name: "coach-011-prompted-only-control",
  focus: "an all-prompted session: reads, proposals, approvals and a camera look all pass untouched",
  script: coachScript({
    sessionId: "coach-011",
    turns: [
      turn(0, "user", "what's step 3?", { audioSeconds: 1.0 }),
      turn(1, "assistant", "step 3: stir-fry the chicken until done.", {
        toolCalls: [call("c-step", "getStepContext")]
      }),
      turn(2, "user", "is it done yet?", { audioSeconds: 0.9 }),
      turn(3, "assistant", "check it reads 74 °C at the thickest piece — thermometer, not colour.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken", question: "is it done" })]
      }),
      turn(4, "user", "advance the step", { audioSeconds: 0.8 }),
      turn(5, "assistant", "proposing the advance — confirm it on the phone.", {
        toolCalls: [call("c-adv", "proposeStepAdvance", { stepIndex: 3 })]
      }),
      turn(6, "user", "and start a two-minute timer", { audioSeconds: 1.0 }),
      turn(7, "assistant", "two minutes, proposed.", {
        toolCalls: [call("c-tmr", "proposeTimerStart", { label: "spinach wilt", minutes: 2, userInitiated: true })]
      }),
      turn(8, "user", "show me the pan", { audioSeconds: 0.6 }),
      turn(9, "assistant", "looking — browning on the chicken; the camera can't assess internal temperature.", {
        toolCalls: [call("c-cam", "requestCameraLook")]
      })
    ],
    userActions: [{ afterTurn: 5, action: { kind: "approve", callId: "c-adv" } }]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    toolStatus: [
      { id: "c-step", status: "ok" },
      { id: "c-fs", status: "ok" },
      { id: "c-adv", status: "ok" },
      { id: "c-tmr", status: "ok" },
      { id: "c-cam", status: "ok" }
    ],
    proposals: [
      { tool: "proposeStepAdvance", requiredApproval: "explicit", state: "executed" },
      { tool: "proposeTimerStart", requiredApproval: "device-auto", state: "executed" }
    ],
    receiptStates: ["executed", "executed"],
    timerLabels: ["spinach wilt"],
    cameraLooks: 1,
    framesSent: 2,
    donenessTemps: [74],
    usageTurns: 10
  }
};
