/**
 * Planner policy tests — the deny-list denies unprompted non-timer writes
 * at the dispatch boundary with a typed result, passes the prompted twin,
 * never touches reads or proposeTimerStart, and keeps proposeMealLog
 * explicit-approval.
 */

import { describe, it, expect } from "bun:test";
import { gateScript, runDesignSession } from "../../../../lechef/run/designRunner.js";
import { plannerDesign, PROACTIVE_WRITE_DENIALS } from "../../../../lechef/designs/planner/design.js";
import { PLANNER_SCRIPTS } from "../../../../lechef/designs/planner/scripts/index.js";

const DESIGN = plannerDesign;

function fixture(name: string) {
  const found = PLANNER_SCRIPTS.find((f) => f.name === name);
  if (found === undefined) throw new Error(`missing planner fixture: ${name}`);
  return found;
}

describe("planner design: tool policy", () => {
  it("denies an unprompted non-timer proposal with the exact typed result", () => {
    const { script } = fixture("plan-open-batch-kept");
    const record = runDesignSession(script, DESIGN);
    const denied = record.toolCalls.find((c) => c.id === "c-save-list");
    expect(denied).toBeDefined();
    expect(denied!.status).toBe("error");
    expect(denied!.result).toEqual({
      error: "policy-denied",
      deniedBy: "planner",
      reason: PROACTIVE_WRITE_DENIALS.reason
    });
  });

  it("passes the prompted twin of the denied call", () => {
    const { script } = fixture("plan-open-batch-then-midcook-suppressed");
    const record = runDesignSession(script, DESIGN);
    const adjust = record.toolCalls.find((c) => c.id === "c-adjust");
    expect(adjust).toBeDefined();
    expect(adjust!.status).toBe("ok");
    // And the approved adjust produced a real timer change (10 minutes).
    const simmer = record.timers.find((t) => t.label === "simmer");
    expect(simmer).toBeDefined();
    expect(simmer!.minutes).toBe(10);
  });

  it("never denies reads, even a proactive read-heavy open", () => {
    const { script } = fixture("plan-read-burst");
    const record = runDesignSession(script, DESIGN);
    expect(record.toolCalls).toHaveLength(4);
    expect(record.toolCalls.every((c) => c.status === "ok")).toBe(true);
  });

  it("denies an unprompted meal log while keeping the prompted one explicit and executing", () => {
    const { script } = fixture("remember-close-meallog-proactive-denied");
    const record = runDesignSession(script, DESIGN);
    const denied = record.toolCalls.find((c) => c.id === "c-log-proactive");
    expect(denied!.status).toBe("error");
    expect(denied!.result).toEqual({
      error: "policy-denied",
      deniedBy: "planner",
      reason: PROACTIVE_WRITE_DENIALS.reason
    });
    const prompted = record.proposals.find((p) => p.tool === "proposeMealLog");
    expect(prompted).toBeDefined();
    expect(prompted!.requiredApproval).toBe("explicit");
    expect(prompted!.state).toBe("executed");
  });

  it("executes an approved meal log from the closing offer (explicit-approval preserved)", () => {
    const { script } = fixture("remember-close-meallog-approved");
    const record = runDesignSession(script, DESIGN);
    expect(record.proposals).toHaveLength(1);
    expect(record.proposals[0].tool).toBe("proposeMealLog");
    expect(record.proposals[0].requiredApproval).toBe("explicit");
    expect(record.proposals[0].state).toBe("executed");
  });

  it("keeps proposeTimerStart out of the deny-list — the opening batch proposes timers unprompted", () => {
    const { script } = fixture("plan-open-batch-kept");
    const record = runDesignSession(script, DESIGN);
    const timers = record.toolCalls.filter((c) => c.name === "proposeTimerStart");
    expect(timers).toHaveLength(2);
    expect(timers.every((c) => c.status === "ok")).toBe(true);
  });

  it("routes a dictated timer as userInitiated → device-auto and a proposed timer as explicit", () => {
    const { script } = fixture("plan-timer-approval-modes");
    const record = runDesignSession(script, DESIGN);
    const byToolState = record.proposals.map((p) => `${p.tool}/${p.requiredApproval}/${p.state}`);
    expect(byToolState).toContain("proposeTimerStart/device-auto/executed");
    expect(byToolState).toContain("proposeTimerStart/explicit/executed");
  });

  it("gates nothing for the prompted-only control — the gate is a pure no-op there", () => {
    const { script } = fixture("plan-prompted-only-control");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([]);
    expect(gate.remappedActions).toEqual([]);
    expect(gate.droppedActions).toEqual([]);
  });
});
