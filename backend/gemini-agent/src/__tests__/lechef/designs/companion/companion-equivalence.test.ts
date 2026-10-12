/**
 * Companion EQUIVALENCE test — with the gates opened (empty policy, no
 * budget), the companion design must reproduce the plain harness record
 * exactly on the prompted-only control script. This pins that the design
 * layer only ever REMOVES behavior; the companion's presence in a record
 * is entirely its gating, not a different replay.
 */

import { describe, expect, test } from "bun:test";
import { companionDesign } from "../../../../lechef/designs/companion/design.js";
import { runDesignSession } from "../../../../lechef/run/designRunner.js";
import { runSession } from "../../../../lechef/run/harness.js";
import { parseSessionScript } from "../../../../lechef/fakeModel.js";
import controlScript from "../../../../lechef/designs/companion/scripts/control-prompted-only.json";

/** The companion with every gate opened — same matcher, no denials, no budget. */
function permissiveCompanion() {
  return {
    ...companionDesign,
    id: "companion-permissive",
    toolPolicy: [],
    turnBudget: { maxUnpromptedTurns: 999, minGapTurns: 0 }
  } as const;
}

describe("permissive companion ≡ plain harness", () => {
  test("the prompted-only control script replays identically through the design layer", () => {
    const script = parseSessionScript(controlScript);
    const plain = runSession(script);
    const throughDesign = runDesignSession(script, permissiveCompanion());
    // The only difference may be the design stamp (each layer stamps its own id).
    expect(throughDesign.design).toBe("companion-permissive");
    expect({ ...throughDesign, design: plain.design }).toEqual(plain);
  });

  test("sanity: the SAME control script through the real companion design is also un-gated", () => {
    // The control is prompted-only, so even the real budget/policy never fire —
    // the records agree, and both stamp "companion".
    const script = parseSessionScript(controlScript);
    const plain = runSession(script);
    const gated = runDesignSession(script, companionDesign);
    expect(gated.design).toBe("companion");
    expect({ ...gated, design: plain.design }).toEqual(plain);
  });
});
