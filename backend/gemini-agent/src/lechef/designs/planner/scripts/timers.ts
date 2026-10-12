/**
 * Timer fixtures — the planner proposes timers up front; the device owns them.
 *
 * plan-timers-survive-kill: an opening-batch timer is approved, the app is
 *   killed and resumed, the clock advances past the deadline — the timer
 *   keeps its absolute device deadline and fires (SPEC 4: timers survive
 *   Live-session loss).
 * plan-timer-approval-modes: a direct user command replays as
 *   userInitiated → device-auto (executes at submit); a model-proposed
 *   timer is explicit and waits for the tap. Both end executed.
 */

import type { PlannerScriptFixture } from "./expectations.js";
import { EATERS, NOW_ISO, PANTRY, RECIPES, makeTurns, timerStartCall } from "./shared-world.js";
import type { SessionScript } from "../../../fakeModel.js";

function script(overrides: {
  sessionId: string;
  job: SessionScript["job"];
  turns: SessionScript["turns"];
  userActions?: SessionScript["userActions"];
}): SessionScript {
  return {
    sessionId: overrides.sessionId,
    job: overrides.job,
    cameraMode: "push-to-look",
    design: "planner",
    turns: overrides.turns,
    ...(overrides.userActions !== undefined ? { userActions: overrides.userActions } : {}),
    fixture: {
      nowIso: NOW_ISO,
      pantry: PANTRY,
      session: { state: "planning", eaters: EATERS },
      recipes: RECIPES
    }
  };
}

export function planTimersSurviveKill(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-timers-survive-kill",
    blurb: "an opening-batch timer survives kill + resume and fires on its device-owned deadline",
    script: script({
      sessionId: "planner-timers-kill-11",
      job: "plan",
      turns: [
        assistantTurn("Plan: shakshuka — the eggs take nine minutes once they're in.", {
          calls: [
            { id: "c-candidates", name: "getRecipeCandidates", args: { goal: "weeknight dinners from stock, use-soon first" } },
            timerStartCall("c-eggs", "eggs", 9)
          ]
        }),
        userTurn("go ahead", 0.8),
        assistantTurn("Nine minutes on the eggs — tap to start it. It runs even if the app sleeps."),
        userTurn("did the app just die?", 1.4),
        assistantTurn("It did — the eggs timer didn't. The deadline lives on the phone."),
        userTurn("how long left?", 1.0),
        assistantTurn("All nine still — it fires at 18:14 no matter what this session does.")
      ],
      userActions: [
        { afterTurn: 2, action: { kind: "approve", callId: "c-eggs" } },
        { afterTurn: 2, action: { kind: "kill" } },
        { afterTurn: 4, action: { kind: "resume" } },
        { afterTurn: 6, action: { kind: "advanceMinutes", minutes: 9 } }
      ]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        { id: "c-candidates", name: "getRecipeCandidates", status: "ok" },
        { id: "c-eggs", name: "proposeTimerStart", status: "ok" }
      ],
      proposals: [{ tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" }],
      timers: [{ label: "eggs", minutes: 9, fired: true, survivedKill: true }]
    }
  };
}

export function planTimerApprovalModes(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-timer-approval-modes",
    blurb: "a dictated timer is userInitiated → device-auto and executes at submit; a model-proposed timer is explicit and waits for the tap",
    script: script({
      sessionId: "planner-timers-modes-12",
      job: "plan",
      turns: [
        userTurn("give me eight minutes on the rice", 2.0),
        assistantTurn("Eight minutes — starting it.", {
          calls: [timerStartCall("c-rice-dictated", "rice", 8, true)]
        }),
        userTurn("and one for the bread when I get there?", 1.6),
        assistantTurn("Bread, five minutes — it's on your tap.", {
          calls: [timerStartCall("c-bread", "bread", 5)],
          prompted: true
        })
      ],
      userActions: [{ afterTurn: 3, action: { kind: "approve", callId: "c-bread" } }]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        { id: "c-rice-dictated", name: "proposeTimerStart", status: "ok" },
        { id: "c-bread", name: "proposeTimerStart", status: "ok" }
      ],
      proposals: [
        { tool: "proposeTimerStart", requiredApproval: "device-auto", state: "executed" },
        { tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" }
      ],
      timers: [
        { label: "rice", minutes: 8, fired: false, survivedKill: false },
        { label: "bread", minutes: 5, fired: false, survivedKill: false }
      ]
    }
  };
}
