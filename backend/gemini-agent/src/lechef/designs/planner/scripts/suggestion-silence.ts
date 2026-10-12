/**
 * Budget-stress and suggestion-silence fixtures.
 *
 * plan-user-driven-budget-stress: a session that never opens with the batch
 *   can spend the whole session-wide allowance mid-cook — the documented
 *   cost of a phase-blind TurnBudget (DESIGN.md). The probe pins the bound:
 *   exactly three unprompted turns kept, the fourth suppressed.
 * plan-pitch-rejection-silence: two plan rejections silence the third pitch.
 * timer-offer-silence-scoped: silence is per suggestion TYPE — a silenced
 *   timer-offer type does not mute the plan type; the repeated offer also
 *   exercises payload dedupe (one live proposal stands).
 */

import type { PlannerScriptFixture } from "./expectations.js";
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

export function planUserDrivenBudgetStress(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-user-driven-budget-stress",
    blurb: "no opening batch — the session-wide allowance leaks mid-cook: three unprompted turns kept, the fourth suppressed",
    script: script({
      sessionId: "planner-budget-stress-05",
      job: "coach",
      sessionState: "cooking",
      recipeId: "r-curry",
      turns: [
        userTurn("I'm making the curry — where was I?", 2.5),
        assistantTurn("Step two — the simmer. Twelve minutes once it's bubbling.", {
          calls: [{ id: "c-step", name: "getStepContext", args: {} }]
        }),
        assistantTurn("Timer offer: want the simmer timed?", {
          calls: [timerStartCall("c-simmer", "simmer", 12)]
        }),
        assistantTurn("Also — your spinach is use-soon; it goes in at the end."),
        assistantTurn("And the rice needs eight minutes on its own."),
        assistantTurn("One more thing about the rice —"),
        userTurn("enough — quiet now", 1.2),
        assistantTurn("Quiet until you call.")
      ]
    }),
    expect: {
      suppressed: [{ turn: 5, because: "budget-exhausted" }],
      toolCalls: [
        { id: "c-step", name: "getStepContext", status: "ok" },
        { id: "c-simmer", name: "proposeTimerStart", status: "ok" }
      ],
      proposals: [{ tool: "proposeTimerStart", requiredApproval: "explicit", state: "proposed" }],
      timers: []
    }
  };
}

export function planPitchRejectionSilence(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "plan-pitch-rejection-silence",
    blurb: "two rejections of the plan type silence the third unprompted pitch — the planner stops re-planning",
    script: script({
      sessionId: "planner-pitch-silence-06",
      job: "plan",
      turns: [
        assistantTurn("Plan: shakshuka tonight — the eggs and spinach are ready and it's the fastest fit.", {
          calls: [{ id: "c-candidates", name: "getRecipeCandidates", args: { goal: "weeknight dinners from stock, use-soon first" } }]
        }),
        userTurn("no", 0.5),
        assistantTurn("Plan: then butter bean curry — rice on the side, one gap (beans)."),
        userTurn("not interested", 0.8),
        assistantTurn("Plan: noodles, then — fastest of the three."),
        userTurn("seriously, stop planning for me", 1.6)
      ]
    }),
    expect: {
      suppressed: [{ turn: 4, because: "suggestion-type-silenced" }],
      toolCalls: [{ id: "c-candidates", name: "getRecipeCandidates", status: "ok" }],
      proposals: [],
      timers: []
    }
  };
}

export function timerOfferSilenceScoped(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "timer-offer-silence-scoped",
    blurb: "silence is per type — twice-rejected timer offers go quiet while the plan type still speaks; the repeat offer dedupes onto one proposal",
    script: script({
      sessionId: "planner-timer-silence-07",
      job: "plan",
      turns: [
        assistantTurn("Timer offer: twelve on the simmer once the curry starts?", {
          calls: [timerStartCall("c-simmer-1", "simmer", 12)],
          prompted: true
        }),
        userTurn("no", 0.4),
        assistantTurn("Timer offer: the simmer — twelve minutes?", {
          calls: [timerStartCall("c-simmer-2", "simmer", 12)],
          prompted: true
        }),
        userTurn("not interested", 0.7),
        assistantTurn("Timer offer: twelve, the simmer."),
        assistantTurn("Plan: curry tonight, noodles Wednesday, shakshuka holds for the weekend."),
        userTurn("fine — curry", 1.1),
        assistantTurn("Curry it is. The simmer timer is still on the table — one tap.")
      ]
    }),
    expect: {
      suppressed: [{ turn: 4, because: "suggestion-type-silenced" }],
      toolCalls: [
        { id: "c-simmer-1", name: "proposeTimerStart", status: "ok" },
        { id: "c-simmer-2", name: "proposeTimerStart", status: "duplicate" }
      ],
      proposals: [{ tool: "proposeTimerStart", requiredApproval: "explicit", state: "proposed" }],
      timers: []
    }
  };
}
