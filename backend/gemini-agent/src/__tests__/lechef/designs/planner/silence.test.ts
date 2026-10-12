/**
 * Planner silence tests — third-rejection silence on the planner's typed
 * suggestion types: plan-pitch, timer-offer, meal-log-offer.
 */

import { describe, it, expect } from "bun:test";
import { gateScript } from "../../../../lechef/run/designRunner.js";
import { plannerDesign, plannerSuggestionType } from "../../../../lechef/designs/planner/design.js";
import { PLANNER_SCRIPTS } from "../../../../lechef/designs/planner/scripts/index.js";

const DESIGN = plannerDesign;

function fixture(name: string) {
  const found = PLANNER_SCRIPTS.find((f) => f.name === name);
  if (found === undefined) throw new Error(`missing planner fixture: ${name}`);
  return found;
}

describe("planner design: third-rejection silence", () => {
  it("silences the plan pitch after two rejections", () => {
    const { script } = fixture("plan-pitch-rejection-silence");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([{ turn: 4, because: "suggestion-type-silenced" }]);
  });

  it("scopes silence to the rejected type — a silenced timer offer does not mute the plan type", () => {
    const { script } = fixture("timer-offer-silence-scoped");
    const gate = gateScript(script, DESIGN);
    // Turn 4 (timer offer) silenced; turn 5 (plan pitch) kept.
    expect(gate.suppressed).toEqual([{ turn: 4, because: "suggestion-type-silenced" }]);
    const keptPlan = gate.script.turns.find((t) => t.i === 5);
    expect(keptPlan).toBeDefined();
    expect(plannerSuggestionType(keptPlan!)).toBe("plan-pitch");
  });

  it("silences the meal-log offer after two declines — the remember step never begs", () => {
    const { script } = fixture("remember-meallog-silence-after-two");
    const gate = gateScript(script, DESIGN);
    expect(gate.suppressed).toEqual([{ turn: 5, because: "suggestion-type-silenced" }]);
  });

  it("does not accrue silence when the user has nothing to reject — suppression is not contagious", () => {
    const { script } = fixture("plan-user-driven-budget-stress");
    const gate = gateScript(script, DESIGN);
    // The only suppression is budget; "enough — quiet now" follows non-suggestion turns.
    expect(gate.suppressed.every((s) => s.because === "budget-exhausted")).toBe(true);
  });

  it("cannot be triggered by rejecting a suppressed suggestion — rejections accrue only to emitted suggestions", () => {
    const { script } = fixture("plan-open-batch-then-midcook-suppressed");
    const gate = gateScript(script, DESIGN);
    // Turn 5 is budget-suppressed; no suggestion-type silence appears anywhere.
    expect(gate.suppressed).toEqual([{ turn: 5, because: "budget-exhausted" }]);
  });
});
