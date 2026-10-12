/**
 * Planner budget tests — the opening batch survives, mid-cook proactivity
 * does not, and prompted turns never consume the allowance.
 */

import { describe, it, expect } from "bun:test";
import { gateScript } from "../../../../lechef/run/designRunner.js";
import { plannerDesign } from "../../../../lechef/designs/planner/design.js";
import { PLANNER_SCRIPTS } from "../../../../lechef/designs/planner/scripts/index.js";

const DESIGN = plannerDesign;

function fixture(name: string) {
  const found = PLANNER_SCRIPTS.find((f) => f.name === name);
  if (found === undefined) throw new Error(`missing planner fixture: ${name}`);
  return found;
}

describe("planner design: turn budget", () => {
  it("keeps the whole three-turn opening batch (maxUnpromptedTurns 3, minGap 0)", () => {
    const { script } = fixture("plan-open-batch-kept");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([]);
    expect(gate.script.turns).toHaveLength(script.turns.length);
  });

  it("suppresses a mid-cook unprompted turn once the batch spent the budget, keeping its prompted retry", () => {
    const { script } = fixture("plan-open-batch-then-midcook-suppressed");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([{ turn: 5, because: "budget-exhausted" }]);
    // 8 source turns - 1 suppressed = 7 kept.
    expect(gate.script.turns).toHaveLength(7);
  });

  it("spends the session-wide allowance mid-cook when no opening batch exists — the documented phase-blindness cost", () => {
    const { script } = fixture("plan-user-driven-budget-stress");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([{ turn: 5, because: "budget-exhausted" }]);
    // Exactly three proactive turns kept (2, 3, 4) then the wall.
  });

  it("never spends budget on prompted assistant turns", () => {
    const { script } = fixture("plan-prompted-only-control");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([]);
    expect(gate.script.turns).toHaveLength(script.turns.length);
  });

  it("keeps the read burst exactly at the three-turn allowance", () => {
    const { script } = fixture("plan-read-burst");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([]);
    expect(gate.script.turns).toHaveLength(5);
  });
});
