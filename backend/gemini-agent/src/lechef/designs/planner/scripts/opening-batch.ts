/**
 * Opening-batch fixtures — the planner's signature move.
 *
 * plan-open-batch-kept: the whole batch (pitch, timers, list) survives the
 *   budget; a proactive note-save inside it is policy-denied while the
 *   prompted equivalent passes.
 * plan-open-batch-then-midcook-suppressed: the same open, then a mid-cook
 *   unprompted timer adjust suppressed as budget-exhausted; the prompted
 *   retry executes.
 * plan-prompted-only-control: every assistant turn prompted — the
 *   equivalence-check baseline for the permissive-design comparison.
 * plan-read-burst: a proactive read-heavy open — reads are never denied.
 */

import type { PlannerScriptFixture } from "./expectations.js";
import { PROACTIVE_WRITE_DENIALS } from "../design.js";
import { EATERS, NOW_ISO, PANTRY, RECIPES, makeTurns, timerStartCall } from "./shared-world.js";
import type { SessionScript } from "../../../fakeModel.js";

function script(overrides: {
  sessionId: string;
  job: SessionScript["job"];
  turns: SessionScript["turns"];
  userActions?: SessionScript["userActions"];
  sessionState?: "planning" | "cooking" | "done";
  recipeId?: string;
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
      session: {
        state: overrides.sessionState ?? "planning",
        ...(overrides.recipeId !== undefined ? { recipeId: overrides.recipeId } : {}),
        eaters: EATERS
      },
      recipes: RECIPES
    }
  };
}

export function planOpenBatchKept(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-open-batch-kept",
    blurb: "the three-turn opening batch survives the budget; a proactive note-save inside it is policy-denied, its prompted twin passes",
    script: script({
      sessionId: "planner-open-kept-01",
      job: "plan",
      turns: [
        assistantTurn("Plan: tonight is egg shakshuka — you have the eggs and the spinach; tomatoes are the one gap. Butter bean curry is the backup.", {
          calls: [{ id: "c-candidates", name: "getRecipeCandidates", args: { goal: "weeknight dinners from stock, use-soon first" } }]
        }),
        assistantTurn("Plan: I propose two timers — nine minutes for the eggs once they are in, twelve for the simmer.", {
          calls: [timerStartCall("c-eggs-timer", "eggs", 9), timerStartCall("c-simmer-timer", "simmer", 12)]
        }),
        assistantTurn("Plan: the cook order is sauce, then eggs. Shopping list is one line — tomatoes. Want me to save it to the cook?", {
          calls: [{ id: "c-save-list", name: "proposeSaveNote", args: { text: "Shopping: tomatoes", scope: "cook" } }],
          prompted: true
        }),
        userTurn("don't save anything yet — just start the eggs when I say go", 3.2),
        assistantTurn("Understood — nothing saved. The eggs timer goes in on your word."),
        userTurn("go", 0.6),
        assistantTurn("Eggs in. Nine minutes, running on the phone.")
      ],
      userActions: [{ afterTurn: 5, action: { kind: "approve", callId: "c-eggs-timer" } }]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        { id: "c-candidates", name: "getRecipeCandidates", status: "ok" },
        { id: "c-eggs-timer", name: "proposeTimerStart", status: "ok" },
        { id: "c-simmer-timer", name: "proposeTimerStart", status: "ok" },
        {
          id: "c-save-list",
          name: "proposeSaveNote",
          status: "error",
          result: {
            error: "policy-denied",
            deniedBy: "planner",
            reason: PROACTIVE_WRITE_DENIALS.reason
          }
        }
      ],
      proposals: [
        { tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" },
        { tool: "proposeTimerStart", requiredApproval: "explicit", state: "proposed" }
      ],
      timers: [{ label: "eggs", minutes: 9, fired: false, survivedKill: false }]
    }
  };
}

export function planOpenBatchThenMidcookSuppressed(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-open-batch-then-midcook-suppressed",
    blurb: "the open spends the whole budget; the mid-cook unprompted timer adjust is suppressed, the prompted retry executes",
    script: script({
      sessionId: "planner-open-midcook-02",
      job: "plan",
      turns: [
        assistantTurn("Plan: butter bean curry tonight — the beans are the one gap; the spinach goes in at the end.", {
          calls: [{ id: "c-candidates", name: "getRecipeCandidates", args: { goal: "weeknight dinners from stock, use-soon first" } }]
        }),
        assistantTurn("Plan: timers — twelve for the simmer, eight for the rice.", {
          calls: [timerStartCall("c-simmer", "simmer", 12), timerStartCall("c-rice", "rice", 8)]
        }),
        assistantTurn("Plan: that is the whole opening — say the word and both timers go in.", { prompted: true }),
        userTurn("put both in", 1.0),
        assistantTurn("Done — simmer and rice, both running on the device."),
        assistantTurn("Timer offer: the simmer can drop to ten now, wants me to adjust it?"),
        userTurn("actually — simmer down to ten", 1.8),
        assistantTurn("Simmer adjusted to ten minutes.", {
          calls: [{ id: "c-adjust", name: "proposeTimerAdjust", args: { label: "simmer", newMinutes: 10 } }]
        })
      ],
      userActions: [
        { afterTurn: 3, action: { kind: "approve", callId: "c-simmer" } },
        { afterTurn: 3, action: { kind: "approve", callId: "c-rice" } },
        { afterTurn: 7, action: { kind: "approve", callId: "c-adjust" } }
      ]
    }),
    expect: {
      suppressed: [{ turn: 5, because: "budget-exhausted" }],
      toolCalls: [
        { id: "c-candidates", name: "getRecipeCandidates", status: "ok" },
        { id: "c-simmer", name: "proposeTimerStart", status: "ok" },
        { id: "c-rice", name: "proposeTimerStart", status: "ok" },
        { id: "c-adjust", name: "proposeTimerAdjust", status: "ok" }
      ],
      proposals: [
        { tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" },
        { tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" },
        { tool: "proposeTimerAdjust", requiredApproval: "explicit", state: "executed" }
      ],
      timers: [
        { label: "simmer", minutes: 10, fired: false, survivedKill: false },
        { label: "rice", minutes: 8, fired: false, survivedKill: false }
      ]
    }
  };
}

export function planPromptedOnlyControl(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-prompted-only-control",
    blurb: "every assistant turn follows a user turn — no gate effect expected; the equivalence-check baseline",
    script: script({
      sessionId: "planner-control-03",
      job: "plan",
      turns: [
        userTurn("what can I cook this week?", 3.0),
        assistantTurn("Plan: shakshuka tonight, curry Wednesday, noodles Friday. The use-soon spinach goes into tonight and Wednesday.", {
          calls: [{ id: "c-candidates", name: "getRecipeCandidates", args: { goal: "weeknight dinners from stock, use-soon first" } }]
        }),
        userTurn("any timers for tonight?", 1.5),
        assistantTurn("The eggs take nine, the simmer twelve — I can propose both when you want them.", {
          calls: [timerStartCall("c-eggs", "eggs", 9)],
          prompted: true
        }),
        userTurn("start the eggs one", 1.0),
        assistantTurn("Nine minutes on the eggs — running on the phone, not on me."),
        userTurn("thanks", 0.5),
        assistantTurn("Any time.")
      ],
      userActions: [{ afterTurn: 4, action: { kind: "approve", callId: "c-eggs" } }]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        { id: "c-candidates", name: "getRecipeCandidates", status: "ok" },
        { id: "c-eggs", name: "proposeTimerStart", status: "ok" }
      ],
      proposals: [{ tool: "proposeTimerStart", requiredApproval: "explicit", state: "executed" }],
      timers: [{ label: "eggs", minutes: 9, fired: false, survivedKill: false }]
    }
  };
}

export function planReadBurst(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-read-burst",
    blurb: "a proactive read-heavy open — snapshot reads are never policy-denied, even unprompted",
    script: script({
      sessionId: "planner-reads-04",
      job: "plan",
      turns: [
        assistantTurn("Plan: reading your fridge first.", { calls: [{ id: "c-pantry", name: "getPantrySummary", args: {} }] }),
        assistantTurn("Plan: three dinners fit the stock this week.", {
          calls: [{ id: "c-cand-week", name: "getRecipeCandidates", args: { goal: "weeknight dinners" } }]
        }),
        assistantTurn("Plan: the spinach wants cooking first.", {
          calls: [{ id: "c-cand-spinach", name: "getRecipeCandidates", args: { goal: "use the spinach first" } }]
        }),
        userTurn("which one uses the rice too?", 2.4),
        assistantTurn("That's the butter bean curry — rice steams on its own timer at the end.", {
          calls: [{ id: "c-context", name: "getRecipeContext", args: {} }]
        })
      ]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        { id: "c-pantry", name: "getPantrySummary", status: "ok" },
        { id: "c-cand-week", name: "getRecipeCandidates", status: "ok" },
        { id: "c-cand-spinach", name: "getRecipeCandidates", status: "ok" },
        { id: "c-context", name: "getRecipeContext", status: "ok" }
      ],
      proposals: [],
      timers: []
    }
  };
}
