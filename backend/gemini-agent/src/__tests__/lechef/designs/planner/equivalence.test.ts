/**
 * Equivalence check — a permissive variant of the planner design (budget
 * effectively unlimited, only the safety-critical read deny-list retained)
 * must reproduce the PLAIN harness record for the prompted-only control
 * script: no gate effect, no policy effect, identical record body. Only
 * the design stamp differs, by construction.
 */

import { describe, it, expect } from "bun:test";
import { runSession, buildSessionWorld } from "../../../../lechef/run/harness.js";
import { runDesignSession } from "../../../../lechef/run/designRunner.js";
import { plannerDesign, plannerSuggestionType } from "../../../../lechef/designs/planner/design.js";
import type { LeChefDesign } from "../../../../lechef/designs/contract.js";
import type { RunRecord } from "../../../../lechef/run/harness.js";
import { PLANNER_SCRIPTS } from "../../../../lechef/designs/planner/scripts/index.js";

const PERMISSIVE_PLANNER: LeChefDesign = {
  id: "planner-permissive",
  title: "Planner (permissive control)",
  summary: "Equivalence control: the planner with the proactive gate and write denials removed.",
  systemPrompt: plannerDesign.systemPrompt,
  toolPolicy: [
    {
      tools: ["getSafetyVerdict", "assessFoodImage", "assessFoodClip"],
      when: "any",
      reason: "camera looks never give safety verdicts (SPEC 2)"
    }
  ],
  turnBudget: { maxUnpromptedTurns: Number.MAX_SAFE_INTEGER, minGapTurns: 0 },
  suggestionType: plannerSuggestionType
};

function fixture(name: string) {
  const found = PLANNER_SCRIPTS.find((f) => f.name === name);
  if (found === undefined) throw new Error(`missing planner fixture: ${name}`);
  return found;
}

/** Everything the harness emits except the design stamp. */
function body(record: RunRecord): Omit<RunRecord, "design"> {
  const { design: _design, ...rest } = record;
  return rest;
}

describe("planner design: permissive equivalence", () => {
  it("reproduces the plain harness record for the prompted-only control script", () => {
    const { script } = fixture("plan-prompted-only-control");

    const world = buildSessionWorld(script);
    const plain = runSession(script, world);
    const permissive = runDesignSession(script, PERMISSIVE_PLANNER);

    expect(body(permissive)).toEqual(body(plain));
    expect(plain.design).toBe("planner");
    expect(permissive.design).toBe("planner-permissive");
  });

  it("keeps the strict design in sync on the same script except for the two documented gate effects", () => {
    // The strict planner also leaves the prompted-only control untouched —
    // the two designs differ only on proactive turns, which the control
    // script has none of.
    const { script } = fixture("plan-prompted-only-control");
    const strict = runDesignSession(script, plannerDesign);
    const world = buildSessionWorld(script);
    const plain = runSession(script, world);
    expect(body(strict)).toEqual(body(plain));
    expect(strict.design).toBe("planner");
  });
});
