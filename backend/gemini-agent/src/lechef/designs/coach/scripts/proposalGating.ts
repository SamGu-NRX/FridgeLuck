/**
 * Proposal-gating fixtures — proactive proposals are denied with typed
 * policy results; the same proposals pass when prompted, with the approval
 * class proposals.ts assigns (step advance always explicit, timers
 * device-auto for direct user commands).
 */

import type { CoachCase } from "./types.js";
import { COACH_DENY_REASONS } from "../design.js";
import { call, coachScript, turn } from "./world.js";

/** coach-003 — a proactive turn packing proposals and a read: proposals denied, read passes. */
export const proactiveProposalsDenied: CoachCase = {
  name: "coach-003-proactive-proposals-denied",
  focus: "proactive proposeStepAdvance/proposeTimerStart get the ask-first reason, proposeMealLog the remember-flow reason, the read passes; nothing reaches the phone",
  script: coachScript({
    sessionId: "coach-003",
    turns: [
      turn(0, "assistant", "I can advance you to step 4, start a two-minute wilt timer, and log this meal.", {
        toolCalls: [
          call("c-adv", "proposeStepAdvance", { stepIndex: 3 }),
          call("c-tmr", "proposeTimerStart", { label: "spinach wilt", minutes: 2 }),
          call("c-ml", "proposeMealLog", { recipeId: "stir-fry", revision: 3, servings: 2, sourcedFrom: "voice" }),
          call("c-pantry", "getPantrySummary")
        ]
      }),
      turn(1, "user", "sure, go ahead", { audioSeconds: 0.8 }),
      turn(2, "assistant", "I still need you to ask for those — say 'next' or 'timer 2 minutes'. Reads are the only thing I take unprompted.")
    ]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2],
    toolStatus: [
      { id: "c-adv", status: "error", policyDenied: true },
      { id: "c-tmr", status: "error", policyDenied: true },
      { id: "c-ml", status: "error", policyDenied: true },
      { id: "c-pantry", status: "ok" }
    ],
    denialReasons: {
      "c-adv": COACH_DENY_REASONS.proactiveProposal,
      "c-tmr": COACH_DENY_REASONS.proactiveProposal,
      "c-ml": COACH_DENY_REASONS.mealLog
    },
    usageTurns: 3
  }
};

/** coach-004 — prompted proposals pass: explicit step advance executes on approval, timer is device-auto. */
export const promptedProposalsApproved: CoachCase = {
  name: "coach-004-prompted-proposals-approved",
  focus: "on the user's ask, proposeStepAdvance stays explicit until approved while a userInitiated timer starts device-auto",
  script: coachScript({
    sessionId: "coach-004",
    turns: [
      turn(0, "user", "next", { audioSeconds: 0.5 }),
      turn(1, "assistant", "advancing to step 4 — confirm it on the phone.", {
        toolCalls: [call("c-adv", "proposeStepAdvance", { stepIndex: 3 })]
      }),
      turn(2, "user", "and time the wilt two minutes", { audioSeconds: 1.4 }),
      turn(3, "assistant", "two minutes, proposed.", {
        toolCalls: [call("c-tmr", "proposeTimerStart", { label: "spinach wilt", minutes: 2, userInitiated: true })]
      })
    ],
    userActions: [{ afterTurn: 1, action: { kind: "approve", callId: "c-adv" } }]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2, 3],
    toolStatus: [
      { id: "c-adv", status: "ok" },
      { id: "c-tmr", status: "ok" }
    ],
    proposals: [
      { tool: "proposeStepAdvance", requiredApproval: "explicit", state: "executed" },
      { tool: "proposeTimerStart", requiredApproval: "device-auto", state: "executed" }
    ],
    receiptStates: ["executed", "executed"],
    timerLabels: ["spinach wilt"],
    usageTurns: 4
  }
};

/** coach-005 — camera: proactive looks denied, user-requested looks pass and never carry a verdict. */
export const cameraPushToLook: CoachCase = {
  name: "coach-005-camera-push-to-look",
  focus: "a proactive requestCameraLook is denied (push-to-look); the user's 'show me' passes and records a verdict-free look",
  script: coachScript({
    sessionId: "coach-005",
    turns: [
      turn(0, "assistant", "let me just glance at the pan for you—", {
        toolCalls: [call("c-cam0", "requestCameraLook")]
      }),
      turn(1, "user", "show me the pan", { audioSeconds: 0.7 }),
      turn(2, "assistant", "looking now — browning on the chicken; the camera can't see internal temperature.", {
        toolCalls: [call("c-cam1", "requestCameraLook")]
      })
    ]
  }),
  expect: {
    suppressed: [],
    keptTurns: [0, 1, 2],
    toolStatus: [
      { id: "c-cam0", status: "error", policyDenied: true },
      { id: "c-cam1", status: "ok" }
    ],
    denialReasons: {
      "c-cam0": COACH_DENY_REASONS.proactiveCamera
    },
    cameraLooks: 1,
    framesSent: 2,
    usageTurns: 3
  }
};
