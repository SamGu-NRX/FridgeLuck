/**
 * Equivalence tests — the coach design's gates must add behavior on top of
 * the plain harness without changing it. A permissive variant of the design
 * (no deny-list, unbounded budget) must reproduce the plain harness record
 * for the prompted-only control script exactly, and the strict coach design
 * must do the same because nothing in an all-prompted session trips its
 * gates.
 */

import { describe, it, expect } from "bun:test";
import { runSession } from "../../../../lechef/run/harness.js";
import { runDesignSession } from "../../../../lechef/run/designRunner.js";
import { parseSessionScript } from "../../../../lechef/fakeModel.js";
import type { SessionScript } from "../../../../lechef/fakeModel.js";
import type { RunRecord } from "../../../../lechef/run/harness.js";
import { coachDesign, coachPermissiveVariant } from "../../../../lechef/designs/coach/design.js";
import { COACH_SCRIPTS } from "../../../../lechef/designs/coach/scripts/index.js";
import type { CoachCase } from "../../../../lechef/designs/coach/scripts/types.js";

function findCase(name: string): CoachCase {
  const found = COACH_SCRIPTS.find((c) => c.name === name);
  if (!found) throw new Error(`coach script fixture not found: ${name}`);
  return found;
}

/** Drop the design-attachment field so design replays compare against plain-harness records. */
function withoutDesign(record: RunRecord): Omit<RunRecord, "design"> {
  const { design: _design, ...rest } = record as RunRecord & { design?: unknown };
  return rest;
}

describe("coach design harness equivalence", () => {
  const control = findCase("coach-011-prompted-only-control");
  const parsed = parseSessionScript(control.script) as SessionScript;

  it("a permissive variant of the design reproduces the plain harness record for the prompted-only control", () => {
    const plain = withoutDesign(runSession(parsed));
    const permissive = withoutDesign(runDesignSession(parsed, coachPermissiveVariant));
    expect(permissive).toEqual(plain);
  });

  it("the strict coach design is also equivalent on an all-prompted session — its gates never fire", () => {
    const plain = withoutDesign(runSession(parsed));
    const strict = withoutDesign(runDesignSession(parsed, coachDesign));
    expect(strict).toEqual(plain);
  });

  it("the same permissive variant diverges from the coach design on a proactive script — the delta is the policy", () => {
    const proactive = findCase("coach-003-proactive-proposals-denied");
    const parsedProactive = parseSessionScript(proactive.script) as SessionScript;
    const strict = runDesignSession(parsedProactive, coachDesign);
    const permissive = runDesignSession(parsedProactive, coachPermissiveVariant);
    // Strict: proposals denied before the phone; permissive: they reach it.
    expect(strict.proposals).toEqual([]);
    expect(permissive.proposals).toHaveLength(3);
  });
});
