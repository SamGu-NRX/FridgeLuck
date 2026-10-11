/**
 * Remember-step fixtures — the planner's closing move.
 *
 * remember-close-meallog-approved: at the user's closing cue the planner
 *   proposes the meal log in a PROMPTED turn; the approval is a scripted
 *   tap; the proposal is executed. requiredApproval is "explicit" — the
 *   shared layer hard-codes mealLog to explicit (proposals.ts approvalFor)
 *   and this design keeps it that way.
 * remember-close-meallog-proactive-denied: the SAME log proposed unprompted
 *   is policy-denied at the dispatch boundary (exact typed result); the
 *   prompted retry passes and stays explicit.
 * remember-meallog-silence-after-two: two verbal declines of the log offer
 *   silence the third offer — the remember step never begs. Both live
 *   offers dedupe onto ONE proposal (identical payload).
 */

import type { PlannerScriptFixture } from "./expectations.js";
import { PROACTIVE_WRITE_DENIALS } from "../design.js";
import { EATERS, NOW_ISO, PANTRY, RECIPES, makeTurns } from "./shared-world.js";
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
      session: { state: "done", recipeId: "r-shakshuka", currentStepIndex: 2, eaters: EATERS },
      recipes: RECIPES
    }
  };
}

const MEAL_LOG_ARGS = {
  recipeId: "r-shakshuka",
  revision: 3,
  servings: 2,
  sourcedFrom: "voice" as const,
  note: "extra lemon at the end"
};

export function rememberCloseMeallogApproved(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "remember-close-meallog-approved",
    blurb: "the closing log offer is prompted, explicit-approval, and executes on the scripted tap",
    script: script({
      sessionId: "planner-remember-ok-08",
      job: "remember",
      turns: [
        userTurn("that's everything — dinner's done", 2.2),
        assistantTurn("Log offer: egg shakshuka for two, with the lemon note — log it?", {
          calls: [{ id: "c-log", name: "proposeMealLog", args: { ...MEAL_LOG_ARGS, userInitiated: false } }],
          prompted: true
        }),
        userTurn("yes — logged, thanks", 1.0),
        assistantTurn("Done — shakshuka for two is in the cookbook.")
      ],
      userActions: [{ afterTurn: 1, action: { kind: "approve", callId: "c-log" } }]
    }),
    expect: {
      suppressed: [],
      toolCalls: [{ id: "c-log", name: "proposeMealLog", status: "ok" }],
      proposals: [{ tool: "proposeMealLog", requiredApproval: "explicit", state: "executed" }],
      timers: []
    }
  };
}

export function rememberCloseMeallogProactiveDenied(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "remember-close-meallog-proactive-denied",
    blurb: "an unprompted log offer is policy-denied with the exact typed result; the prompted retry passes and stays explicit",
    script: script({
      sessionId: "planner-remember-denied-09",
      job: "remember",
      turns: [
        assistantTurn("Log offer: shakshuka for two — logging it for you.", {
          calls: [{ id: "c-log-proactive", name: "proposeMealLog", args: { ...MEAL_LOG_ARGS, userInitiated: false } }]
        }),
        userTurn("why wasn't it logged?", 1.5),
        assistantTurn("I only propose a log when you've called the cook done. So: log offer — shakshuka for two?", {
          calls: [{ id: "c-log-prompted", name: "proposeMealLog", args: { ...MEAL_LOG_ARGS, userInitiated: false } }],
          prompted: true
        }),
        userTurn("log it", 0.7)
      ],
      userActions: [{ afterTurn: 3, action: { kind: "approve", callId: "c-log-prompted" } }]
    }),
    expect: {
      suppressed: [],
      toolCalls: [
        {
          id: "c-log-proactive",
          name: "proposeMealLog",
          status: "error",
          result: {
            error: "policy-denied",
            deniedBy: "planner",
            reason: PROACTIVE_WRITE_DENIALS.reason
          }
        },
        { id: "c-log-prompted", name: "proposeMealLog", status: "ok" }
      ],
      proposals: [{ tool: "proposeMealLog", requiredApproval: "explicit", state: "executed" }],
      timers: []
    }
  };
}

export function rememberMeallogSilenceAfterTwo(): PlannerScriptFixture {
  const { userTurn, assistantTurn } = makeTurns();
  return {
    name: "remember-meallog-silence-after-two",
    blurb: "two verbal declines silence the third log offer; both live offers dedupe onto one never-approved proposal",
    script: script({
      sessionId: "planner-remember-silence-10",
      job: "remember",
      turns: [
        userTurn("dinner's done", 1.5),
        assistantTurn("Log offer: butter bean curry for two — log it?", {
          calls: [{ id: "c-log-1", name: "proposeMealLog", args: { recipeId: "r-curry", revision: 2, servings: 2, sourcedFrom: "voice", userInitiated: false } }],
          prompted: true
        }),
        userTurn("no", 0.5),
        assistantTurn("Log offer: it's one tap — log the curry for two?", {
          calls: [{ id: "c-log-2", name: "proposeMealLog", args: { recipeId: "r-curry", revision: 2, servings: 2, sourcedFrom: "voice", userInitiated: false } }],
          prompted: true
        }),
        userTurn("not interested", 0.7),
        assistantTurn("Log offer: last time — the curry?"),
        userTurn("leave it", 0.8)
      ]
    }),
    expect: {
      suppressed: [{ turn: 5, because: "suggestion-type-silenced" }],
      toolCalls: [
        { id: "c-log-1", name: "proposeMealLog", status: "ok" },
        { id: "c-log-2", name: "proposeMealLog", status: "duplicate" }
      ],
      proposals: [{ tool: "proposeMealLog", requiredApproval: "explicit", state: "proposed" }],
      timers: []
    }
  };
}
