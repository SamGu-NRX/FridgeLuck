/**
 * Coach design third-rejection-silence tests — after two user rejections of
 * a suggestion type, that type is silent for the rest of the session. Other
 * types keep flowing, attribution pins only real rejections, and each
 * suggestion type silences independently.
 */

import { describe, it, expect } from "bun:test";
import { gateScript, runDesignSession } from "../../../../lechef/run/designRunner.js";
import { parseSessionScript } from "../../../../lechef/fakeModel.js";
import type { SessionScript } from "../../../../lechef/fakeModel.js";
import { coachDesign, coachSuggestionType } from "../../../../lechef/designs/coach/design.js";
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

function silence(c: CoachCase): string {
  const gated = gate(c);
  const suppressedTurns = gated.suppressed
    .filter((s) => s.because === "suggestion-type-silenced")
    .map((s) => s.turn);
  const types = suppressedTurns
    .map((turn) => {
      const sourceTurn = parseSessionScript(c.script).turns.find((t) => t.i === turn);
      if (!sourceTurn) throw new Error(`suppressed turn ${turn} missing from source`);
      return coachSuggestionType(sourceTurn);
    })
    .filter((t): t is string => t !== null);
  return [...new Set(types)].sort().join(",");
}

describe("coach design suggestion silence", () => {
  it("silences the third use-soon after two rejections while safety suggestions still flow", () => {
    const gated = gate(findCase("coach-006-use-soon-silence"));
    expect(gated.suppressed).toEqual([{ turn: 4, because: "suggestion-type-silenced" }]);
    expect(silence(findCase("coach-006-use-soon-silence"))).toBe("use-soon");
    // Safety is a different type and is never silenced by use-soon rejections.
    const record = runDesignSession(parseSessionScript(findCase("coach-006-use-soon-silence").script), coachDesign);
    expect(record.toolCalls.some((c) => c.name === "checkFoodSafety" && c.status === "ok")).toBe(true);
  });

  it("attributes rejections only to no-ish replies directly after a kept suggestion", () => {
    // The question at turn 1 sits between two use-soon suggestions; if it
    // wrongly accrued, use-soon would already be silenced at turn 4.
    const gated = gate(findCase("coach-007-rejection-attribution"));
    expect(gated.suppressed).toEqual([{ turn: 6, because: "suggestion-type-silenced" }]);
    expect(gated.script.turns.map((t) => t.i)).toContain(4);
  });

  it("silences each suggestion type independently — substitutions ignore use-soon rejections", () => {
    expect(silence(findCase("coach-012-substitution-beyond-table"))).toBe("substitution");
  });

  it("keeps silence session-scoped: a fresh gate of the same script silences the same turns", () => {
    const c = findCase("coach-006-use-soon-silence");
    expect(silence(c)).toBe(silence(c));
  });
});
