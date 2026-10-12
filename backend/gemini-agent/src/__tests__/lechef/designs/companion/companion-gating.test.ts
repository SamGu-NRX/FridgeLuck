/**
 * Companion design SCRIPT tests — budget, third-rejection silence, and
 * policy denials replayed through the shared design runner on the design's
 * own session scripts (src/lechef/designs/companion/scripts/).
 */

import { describe, expect, test } from "bun:test";
import { companionDesign } from "../../../../lechef/designs/companion/design.js";
import { gateScript, runDesignSession } from "../../../../lechef/run/designRunner.js";
import { parseSessionScript, type SessionScript, type ScriptTurn } from "../../../../lechef/fakeModel.js";

import budgetScript from "../../../../lechef/designs/companion/scripts/budget-exhaustion.json";
import collapseScript from "../../../../lechef/designs/companion/scripts/checkin-run-collapse.json";
import silenceScript from "../../../../lechef/designs/companion/scripts/use-soon-silence.json";
import gatingScript from "../../../../lechef/designs/companion/scripts/proposal-gating.json";
import timerScript from "../../../../lechef/designs/companion/scripts/timer-allowance.json";
import inventoryScript from "../../../../lechef/designs/companion/scripts/inventory-correction-proactive.json";
import stepScript from "../../../../lechef/designs/companion/scripts/step-advance-allowance.json";
import burntScript from "../../../../lechef/designs/companion/scripts/burnt-smell-empathy.json";
import focusScript from "../../../../lechef/designs/companion/scripts/mixed-focus-backoff.json";

// JSON imports are unknown-shaped until parsed: validate, then use the
// typed result. A malformed script fails the suite loudly, once, here.
function parsed(value: unknown): SessionScript {
  return parseSessionScript(value);
}

function keptUnprompted(s: SessionScript): number {
  return s.turns.filter((t) => t.proactive === true).length;
}

function toolCall(record: ReturnType<typeof runDesignSession>, id: string) {
  const call = record.toolCalls.find((c) => c.id === id);
  if (call === undefined) throw new Error(`no tool call ${id} in record`);
  return call;
}

describe("companion scripts parse and carry the design stamp", () => {
  test("every script validates against the pinned schema", () => {
    for (const raw of [budgetScript, collapseScript, silenceScript, gatingScript, timerScript, inventoryScript, stepScript, burntScript, focusScript]) {
      const s = parsed(raw);
      expect(s.design).toBe("companion");
      expect(["coach", "remember"].includes(s.job)).toBe(true);
    }
  });
});

describe("companion budget on real scripts", () => {
  test("budget-exhaustion: three spaced check-ins kept, the fourth budget-exhausted", () => {
    const s = parsed(budgetScript);
    const g = gateScript(s, companionDesign);
    expect(g.suppressed).toEqual([{ turn: 9, because: "budget-exhausted" }]);
    expect(keptUnprompted(g.script)).toBe(3);
  });

  test("checkin-run-collapse: a proactive run collapses to its first turn", () => {
    const s = parsed(collapseScript);
    const g = gateScript(s, companionDesign);
    expect(g.suppressed).toEqual([
      { turn: 1, because: "min-gap" },
      { turn: 2, because: "min-gap" },
      { turn: 3, because: "min-gap" }
    ]);
    expect(g.script.turns.filter((t) => t.role === "assistant").map((t) => t.i)).toEqual([0, 5]);
  });

  test("mixed-focus-backoff: terse cook gets min-gap and budget suppression, never nagging", () => {
    const s = parsed(focusScript);
    const g = gateScript(s, companionDesign);
    expect(g.suppressed).toEqual([
      { turn: 4, because: "min-gap" },
      { turn: 10, because: "budget-exhausted" }
    ]);
    expect(keptUnprompted(g.script)).toBe(3);
  });
});

describe("companion third-rejection silence on a real script", () => {
  test("the third use-soon is silenced after two rejections; a check-in still passes", () => {
    const s = parsed(silenceScript);
    const g = gateScript(s, companionDesign);
    expect(g.suppressed).toEqual([{ turn: 5, because: "suggestion-type-silenced" }]);
    const byI = new Map(g.script.turns.map((t): [number, ScriptTurn] => [t.i, t]));
    expect(byI.get(5)).toBeUndefined(); // the silenced suggestion is gone
    expect(byI.get(7)?.text).toContain("[check-in]"); // other types unaffected
    const record = runDesignSession(s, companionDesign);
    expect(record.design).toBe("companion");
    expect(record.turns.map((t) => t.i)).toEqual([0, 1, 2, 3, 4, 6, 7]);
  });
});

describe("companion policy denials on real scripts", () => {
  test("proactive memory writes are denied with the design's reason; the same asks prompted pass", () => {
    const record = runDesignSession(parsed(gatingScript), companionDesign);
    for (const id of ["g-ml1", "g-nt1"]) {
      const call = toolCall(record, id);
      expect(call.status).toBe("error");
      expect(call.result).toEqual({
        error: "policy-denied",
        deniedBy: "companion",
        reason: companionDesign.toolPolicy[0].reason
      });
    }
    const mealLog = toolCall(record, "g-ml2");
    const note = toolCall(record, "g-nt2");
    expect(mealLog.status).toBe("ok");
    expect(note.status).toBe("ok");
    expect(record.proposals.map((p) => `${p.tool}:${p.state}`)).toEqual([
      "proposeMealLog:executed",
      "proposeSaveNote:proposed"
    ]);
    expect(record.proposals.every((p) => p.requiredApproval === "explicit")).toBe(true);
  });

  test("proactive inventory correction is denied; the cook's own report passes", () => {
    const record = runDesignSession(parsed(inventoryScript), companionDesign);
    const denied = toolCall(record, "ic1");
    expect(denied.status).toBe("error");
    expect(denied.result).toMatchObject({ error: "policy-denied", deniedBy: "companion" });
    const allowed = toolCall(record, "ic2");
    expect(allowed.status).toBe("ok");
    expect(record.proposals).toHaveLength(1);
    expect(record.proposals[0].requiredApproval).toBe("explicit");
  });

  test("the proactive timer offer is ALLOWED and stays explicit — the proposal is the ask", () => {
    const record = runDesignSession(parsed(timerScript), companionDesign);
    const offer = toolCall(record, "t-of1");
    expect(offer.status).toBe("ok");
    // At proposal time: explicit approval, state "proposed" — the phone asks the cook.
    expect(offer.result).toMatchObject({
      state: "proposed",
      requiredApproval: "explicit",
      userInitiated: false
    });
    expect(record.proposals).toHaveLength(1);
    expect(record.proposals[0].tool).toBe("proposeTimerStart");
    expect(record.proposals[0].requiredApproval).toBe("explicit");
    expect(record.proposals[0].userInitiated).toBe(false);
    // The RunRecord reports the final lifecycle: the scripted approval executed it.
    expect(record.proposals[0].state).toBe("executed");
    expect(record.timers[0]).toMatchObject({ label: "rice", minutes: 8 });
  });

  test("the proactive step-offer is ALLOWED and executes on approval", () => {
    const record = runDesignSession(parsed(stepScript), companionDesign);
    expect(toolCall(record, "s-a1").status).toBe("ok");
    expect(record.proposals[0].tool).toBe("proposeStepAdvance");
    expect(record.proposals[0].requiredApproval).toBe("explicit");
    expect(record.proposals[0].state).toBe("executed");
  });
});

describe("companion reads and honest unknowns on real scripts", () => {
  test("burnt-smell: reads pass the policy, the camera yields no verdict, the rulebook answer is explicit", () => {
    const record = runDesignSession(parsed(burntScript), companionDesign);
    expect(toolCall(record, "b-cam1").status).toBe("ok");
    expect(toolCall(record, "b-fs1").status).toBe("ok");
    expect(record.camera).toHaveLength(1);
    expect(record.camera[0].safetyVerdict).toBeNull();
    expect(record.camera[0].cannotAssess.length).toBeGreaterThan(0);
    expect(record.answers).toHaveLength(1);
    expect(record.answers[0].sourcedCheck).toBeNull(); // cooked rice: uncovered → explicit unknown
  });
});
