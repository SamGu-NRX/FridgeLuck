/**
 * Coach design speech-budget tests — maxUnpromptedTurns: 2, minGapTurns: 2.
 * The coach never talks over the user: a third unprompted interjection dies
 * of budget, adjacent unprompted turns die of min-gap, and scripted user
 * actions on suppressed turns remap instead of dropping.
 */

import { describe, it, expect } from "bun:test";
import { gateScript, runDesignSession } from "../../../../lechef/run/designRunner.js";
import { parseSessionScript } from "../../../../lechef/fakeModel.js";
import type { SessionScript } from "../../../../lechef/fakeModel.js";
import { coachDesign } from "../../../../lechef/designs/coach/design.js";
import { COACH_SCRIPTS } from "../../../../lechef/designs/coach/scripts/index.js";
import type { CoachCase } from "../../../../lechef/designs/coach/scripts/types.js";

function findCase(name: string): CoachCase {
  const found = COACH_SCRIPTS.find((c) => c.name === name);
  if (!found) throw new Error(`coach script fixture not found: ${name}`);
  return found;
}

function gate(c: CoachCase): ReturnType<typeof gateScript> {
  return gateScript(parseSessionScript(c.script) as SessionScript, coachDesign);
}

describe("coach design speech budget", () => {
  it("suppresses a third cleanly-gapped unprompted turn as budget-exhausted", () => {
    const gated = gate(findCase("coach-008-budget-exhausted"));
    expect(gated.suppressed).toEqual([{ turn: 6, because: "budget-exhausted" }]);
    // Budget counts KEPT unprompted turns only: the first two interjections survive.
    expect(gated.script.turns.map((t) => t.i)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  it("suppresses an unprompted turn that lands inside the min gap, and re-arms after a user exchange", () => {
    const gated = gate(findCase("coach-009-min-gap"));
    expect(gated.suppressed).toEqual([{ turn: 1, because: "min-gap" }]);
    // The suppressed turn consumed no budget: the later unprompted turn 4 is kept.
    expect(gated.script.turns.map((t) => t.i)).toEqual([0, 2, 3, 4]);
  });

  it("remaps user actions scripted onto suppressed turns instead of dropping them", () => {
    const gated = gate(findCase("coach-010-suppressed-action-remap"));
    expect(gated.suppressed.map((s) => s.turn)).toEqual([1, 2]);
    expect(gated.remappedActions).toEqual([
      { from: 1, to: 3 },
      { from: 2, to: 3 }
    ]);
    expect(gated.droppedActions).toEqual([]);
  });

  it("gates deterministically per session: gating the same script twice gives identical suppression", () => {
    const c = findCase("coach-008-budget-exhausted");
    const first = gate(c);
    const second = gate(c);
    expect(second.suppressed).toEqual(first.suppressed);
    expect(second.script.turns.map((t) => t.i)).toEqual(first.script.turns.map((t) => t.i));
  });
});
