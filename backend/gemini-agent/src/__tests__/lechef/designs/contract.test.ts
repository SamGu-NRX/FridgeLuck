/**
 * Parent-owned join-infra tests: the LeChefDesign contract and the
 * policy-gated design runner. The three design tasks own their own configs
 * and tests; these pin the mechanics they all share.
 */

import { describe, expect, test } from "bun:test";
import { gateScript, runDesignSession } from "../../../lechef/run/designRunner.js";
import { runSession } from "../../../lechef/run/harness.js";
import { defaultIsRejection, type LeChefDesign } from "../../../lechef/designs/contract.js";
import type { SessionScript, ScriptTurn } from "../../../lechef/fakeModel.js";

function permissiveDesign(): LeChefDesign {
  return {
    id: "test-permissive",
    title: "Permissive",
    summary: "No gating — equivalence baseline.",
    systemPrompt: "n/a",
    toolPolicy: [],
    turnBudget: { maxUnpromptedTurns: 999, minGapTurns: 0 }
  };
}

function strictDesign(): LeChefDesign {
  return {
    id: "test-strict",
    title: "Strict",
    summary: "Denies proactive proposals; tiny speech budget.",
    systemPrompt: "n/a",
    toolPolicy: [
      {
        tools: ["proposeMealLog", "proposeSaveNote"],
        when: "proactive",
        reason: "proposals need an ask"
      }
    ],
    turnBudget: { maxUnpromptedTurns: 1, minGapTurns: 0 }
  };
}

function t(i: number, role: "user" | "assistant", text: string, extra: Partial<ScriptTurn> = {}): ScriptTurn {
  return { i, role, text, ...extra };
}

function coachScript(turns: ScriptTurn[], extra: Partial<SessionScript> = {}): SessionScript {
  return {
    sessionId: "T-1",
    job: "coach",
    cameraMode: "push-to-look",
    design: "unset",
    turns,
    fixture: {
      pantry: [
        {
          ingredientId: "ing-eggs",
          name: "eggs",
          quantity: { kind: "known", value: 6, unit: "count" },
          state: "sufficient",
          source: "manual"
        }
      ]
    },
    ...extra
  };
}

describe("gateScript — turn budget", () => {
  test("suppresses proactive turns beyond the budget, keeping the first", () => {
    const s = coachScript([t(0, "assistant", "eggs look great"), t(1, "assistant", "also: use soon"), t(2, "assistant", "one more thing")]);
    const g = gateScript(s, strictDesign());
    expect(g.script.turns.map((x) => x.i)).toEqual([0]);
    expect(g.suppressed).toEqual([
      { turn: 1, because: "budget-exhausted" },
      { turn: 2, because: "budget-exhausted" }
    ]);
  });

  test("paces unprompted turns at least minGapTurns emitted turns apart", () => {
    const s = coachScript([t(0, "assistant", "a"), t(1, "assistant", "b"), t(2, "user", "ok"), t(3, "assistant", "c"), t(4, "assistant", "d")]);
    const g = gateScript(s, { ...strictDesign(), turnBudget: { maxUnpromptedTurns: 99, minGapTurns: 1 } });
    // a0 kept; a1 adjacent (gap 0 < 1) suppressed; u2 counts toward the gap;
    // a3 is prompted (answers u2) and passes; a4 is proactive again with gap 2.
    expect(g.script.turns.map((x) => x.i)).toEqual([0, 2, 3, 4]);
    expect(g.suppressed).toEqual([{ turn: 1, because: "min-gap" }]);
  });

  test("the gate annotates kept proactive turns; prompted turns stay unannotated", () => {
    const s = coachScript([t(0, "user", "hello"), t(1, "assistant", "step two"), t(2, "assistant", "also: timer check"), t(3, "assistant", "one more")]);
    const g = gateScript(s, strictDesign());
    const byI = new Map(g.script.turns.map((x) => [x.i, x]));
    expect(byI.get(1)?.proactive).toBeUndefined();
    expect(byI.get(2)?.proactive).toBe(true);
    expect(g.suppressed).toEqual([{ turn: 3, because: "budget-exhausted" }]);
  });

  test("replay honors a hand-set proactive annotation at the policy boundary", () => {
    const s = coachScript([
      t(0, "user", "log this meal"),
      t(1, "assistant", "logged for you", { proactive: true, toolCalls: [{ id: "tc-1", name: "proposeMealLog", args: { recipeId: "r-1", revision: 1, servings: 2, sourcedFrom: "screen" } }] })
    ]);
    const record = runDesignSession(s, strictDesign());
    expect(record.toolCalls[0].status).toBe("error");
    expect(record.toolCalls[0].result).toEqual({ error: "policy-denied", deniedBy: "test-strict", reason: "proposals need an ask" });
  });

  test("prompted turns always pass the budget", () => {
    const s = coachScript([t(0, "user", "what should I do"), t(1, "assistant", "step two"), t(2, "user", "and now"), t(3, "assistant", "step three")]);
    const g = gateScript(s, strictDesign());
    expect(g.suppressed).toEqual([]);
    expect(g.script.turns.map((x) => x.i)).toEqual([0, 1, 2, 3]);
  });
});

describe("gateScript — third-rejection silence", () => {
  const suggester: LeChefDesign = {
    ...strictDesign(),
    turnBudget: { maxUnpromptedTurns: 99, minGapTurns: 0 },
    suggestionType: (turn) => (turn.text.includes("use-soon") ? "use-soon" : null)
  };

  test("a third suggestion of a twice-rejected type is silenced", () => {
    const s = coachScript([
      t(0, "assistant", "use-soon: the spinach"),
      t(1, "user", "no"),
      t(2, "assistant", "use-soon: really, the spinach"),
      t(3, "user", "not interested"),
      t(4, "assistant", "use-soon: the spinach!")
    ]);
    const g = gateScript(s, suggester);
    expect(g.suppressed).toEqual([{ turn: 4, because: "suggestion-type-silenced" }]);
  });

  test("a rejection after a suppressed suggestion attributes to nothing", () => {
    const s = coachScript([
      t(0, "assistant", "use-soon: the spinach"),
      t(1, "user", "no"),
      t(2, "assistant", "use-soon: the spinach again"),
      t(3, "user", "nope"),
      t(4, "assistant", "use-soon: third time"),
      t(5, "user", "stop"),
      t(6, "assistant", "use-soon: fourth")
    ]);
    const g = gateScript(s, suggester);
    // turn 4 silenced; turn 5's "stop" follows silence — attributes to nothing;
    // turn 6 was already silenced by the two accrued rejections anyway.
    expect(g.suppressed).toEqual([
      { turn: 4, because: "suggestion-type-silenced" },
      { turn: 6, because: "suggestion-type-silenced" }
    ]);
  });

  test("defaultIsRejection matches explicit no-ish openers only", () => {
    expect(defaultIsRejection(t(0, "user", "no"))).toBe(true);
    expect(defaultIsRejection(t(0, "user", "Nope."))).toBe(true);
    expect(defaultIsRejection(t(0, "user", "not now, thanks"))).toBe(true);
    expect(defaultIsRejection(t(0, "user", "normal eggs please"))).toBe(false);
    expect(defaultIsRejection(t(0, "user", "what's next?"))).toBe(false);
  });
});

describe("gateScript — user action remapping", () => {
  test("actions on suppressed turns move to the next kept turn; orphaned ones drop", () => {
    const s = coachScript([t(0, "assistant", "a"), t(1, "assistant", "b")], {
      userActions: [
        { afterTurn: 0, action: { kind: "kill" } },
        { afterTurn: 1, action: { kind: "resume" } }
      ]
    });
    const g = gateScript(s, strictDesign());
    // turn 0 kept (kill untouched); turn 1 suppressed; its resume moves to...
    // no kept turn after 1 — dropped.
    expect(g.suppressed).toEqual([{ turn: 1, because: "budget-exhausted" }]);
    expect(g.remappedActions).toEqual([]);
    expect(g.droppedActions).toEqual([{ afterTurn: 1, action: { kind: "resume" } }]);
    expect(g.script.userActions).toEqual([{ afterTurn: 0, action: { kind: "kill" } }]);
  });

  test("an action on a suppressed turn reattaches to the next kept turn", () => {
    const s = coachScript([t(0, "assistant", "a"), t(1, "assistant", "b"), t(2, "user", "hi"), t(3, "assistant", "c")], {
      userActions: [{ afterTurn: 1, action: { kind: "kill" } }]
    });
    const g = gateScript(s, strictDesign());
    expect(g.remappedActions).toEqual([{ from: 1, to: 2 }]);
    expect(g.script.userActions).toEqual([{ afterTurn: 2, action: { kind: "kill" } }]);
  });
});

describe("wrapWithPolicy — tool policy at the dispatch boundary", () => {
  const mealLogArgs = { recipeId: "r-1", revision: 1, servings: 2, sourcedFrom: "screen" as const };

  test("denies a proactive proposal call before the layer sees it", () => {
    const s = coachScript([t(0, "assistant", "logged for you", { toolCalls: [{ id: "tc-1", name: "proposeMealLog", args: mealLogArgs }] })]);
    const record = runDesignSession(s, strictDesign());
    expect(record.toolCalls).toHaveLength(1);
    expect(record.toolCalls[0].status).toBe("error");
    expect(record.toolCalls[0].result).toEqual({
      error: "policy-denied",
      deniedBy: "test-strict",
      reason: "proposals need an ask"
    });
    expect(record.proposals).toEqual([]);
    expect(record.receipts).toEqual([]);
  });

  test("the same call passes when prompted, and stays explicit-approval", () => {
    const s = coachScript([
      t(0, "user", "log this meal"),
      t(1, "assistant", "done proposing", { toolCalls: [{ id: "tc-2", name: "proposeMealLog", args: mealLogArgs }] })
    ]);
    const record = runDesignSession(s, strictDesign());
    expect(record.toolCalls[0].status).toBe("ok");
    expect(record.proposals).toHaveLength(1);
    expect(record.proposals[0].requiredApproval).toBe("explicit");
    expect(record.proposals[0].state).toBe("proposed");
  });

  test("policy never blocks reads, and proposal dedupe still works through the wrapper", () => {
    const s = coachScript([
      t(0, "user", "pantry? and start the rice timer"),
      t(1, "assistant", "checking, and timer", {
        toolCalls: [
          { id: "tc-3", name: "getPantrySummary", args: {} },
          { id: "tc-4", name: "proposeTimerStart", args: { label: "rice", minutes: 8, userInitiated: true } },
          { id: "tc-5", name: "proposeTimerStart", args: { label: "rice", minutes: 8, userInitiated: true } }
        ]
      })
    ]);
    const record = runDesignSession(s, strictDesign());
    expect(record.toolCalls[0].status).toBe("ok");
    expect(record.toolCalls[1].status).toBe("ok");
    expect(record.toolCalls[2].status).toBe("duplicate");
    expect(record.toolCalls[2].dupOf).toBe("proposal-0001");
    expect(record.proposals).toHaveLength(1);
  });
});

describe("runDesignSession — record integrity", () => {
  test("stamps the design id into the record", () => {
    const s = coachScript([t(0, "user", "hi"), t(1, "assistant", "hello")]);
    const record = runDesignSession(s, strictDesign());
    expect(record.design).toBe("test-strict");
  });

  test("a permissive design reproduces the plain harness record exactly", () => {
    const s = coachScript([
      t(0, "user", "start rice", { audioSeconds: 1.5 }),
      t(1, "assistant", "timer proposed", { toolCalls: [{ id: "tc-5", name: "proposeTimerStart", args: { label: "rice", minutes: 8, userInitiated: true } }] }),
      t(2, "user", "how's the rice"),
      t(3, "assistant", "six more minutes"),
      t(4, "assistant", "use-soon: spinach")
    ]);
    const plain = runSession(s);
    const throughDesign = runDesignSession(s, permissiveDesign());
    expect({ ...throughDesign, design: plain.design }).toEqual(plain);
  });

  test("a cancelled call inside a suppressed turn vanishes from the record", () => {
    const s = coachScript([
      t(0, "assistant", "kept", { toolCalls: [{ id: "tc-6", name: "getPantrySummary", args: {} }], cancelled: [] }),
      t(1, "assistant", "suppressed", { toolCalls: [{ id: "tc-7", name: "proposeStepAdvance", args: { stepIndex: 1 } }], cancelled: ["tc-7"] })
    ]);
    const record = runDesignSession(s, strictDesign());
    expect(record.toolCalls.map((c) => c.id)).toEqual(["tc-6"]);
  });
});
