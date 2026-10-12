/**
 * Companion design CONFIG tests — the knobs themselves, independent of any
 * script. Script-level behavior lives in companion-gating.test.ts.
 */

import { describe, expect, test } from "bun:test";
import { companionDesign } from "../../../../lechef/designs/companion/design.js";
import { gateScript } from "../../../../lechef/run/designRunner.js";
import type { SessionScript, ScriptTurn } from "../../../../lechef/fakeModel.js";

const READ_TOOLS = [
  "getRecipeCandidates",
  "getPantrySummary",
  "getRecipeContext",
  "getStepContext",
  "requestCameraLook",
  "checkFoodSafety",
  "lookupSubstitution"
] as const;

const OFFER_TOOLS = ["proposeTimerStart", "proposeTimerAdjust", "proposeStepAdvance"] as const;

const MEMORY_TOOLS = ["proposeMealLog", "proposeSaveNote", "proposeInventoryCorrection"] as const;

function t(i: number, role: "user" | "assistant", text: string, extra: Partial<ScriptTurn> = {}): ScriptTurn {
  return { i, role, text, ...extra };
}

function script(turns: ScriptTurn[], job: SessionScript["job"] = "coach"): SessionScript {
  return {
    sessionId: "config-probe",
    job,
    cameraMode: "push-to-look",
    design: "unset",
    turns,
    fixture: {
      session: { recipeId: "r-1", state: "cooking", currentStepIndex: 0 }
    }
  };
}

describe("companion design config", () => {
  test("identity: id matches the owned directory name", () => {
    expect(companionDesign.id).toBe("companion");
    expect(companionDesign.title.length).toBeGreaterThan(0);
    expect(companionDesign.summary.length).toBeGreaterThan(40);
  });

  test("budget: three unprompted turns, a real two-turn gap", () => {
    expect(companionDesign.turnBudget).toEqual({ maxUnpromptedTurns: 3, minGapTurns: 2 });
  });

  test("policy denies exactly the memory-write proposals, proactively only", () => {
    const deniedProactively = new Set(
      companionDesign.toolPolicy.filter((r) => r.when === "proactive").flatMap((r) => [...r.tools])
    );
    expect([...deniedProactively].sort()).toEqual([...MEMORY_TOOLS].sort());
  });

  test("policy never denies a prompted call, a read, or an offer", () => {
    for (const rule of companionDesign.toolPolicy) {
      expect(rule.when).toBe("proactive");
      for (const tool of [...READ_TOOLS, ...OFFER_TOOLS]) {
        expect(rule.tools === "*" || rule.tools.includes(tool)).toBe(false);
      }
    }
  });

  test("proactive offers (timer, step advance) pass the policy where memory writes are denied", () => {
    // The gate only suppresses TURNS; policy denial is observable via
    // runDesignSession, so probe the pure gate for the budget side and the
    // policy matrix here through gateScript's pass-through: the gate must
    // NOT suppress a spaced offer turn.
    const spaced =
      script([
        t(0, "assistant", "[check-in] how's it going?"),
        t(1, "user", "fine"),
        t(2, "assistant", "good"),
        t(3, "assistant", "[timer-offer] eight minutes on the rice?")
      ]);
    const g = gateScript(spaced, companionDesign);
    expect(g.suppressed).toEqual([]);
    expect(g.script.turns.map((x) => x.i)).toEqual([0, 1, 2, 3]);
  });

  test("suggestionType: markers map to the four companion types, nothing else", () => {
    expect(companionDesign.suggestionType?.(t(0, "assistant", "[check-in] how's it going?"))).toBe("check-in");
    expect(companionDesign.suggestionType?.(t(0, "assistant", "[use-soon] spinach day"))).toBe("use-soon");
    expect(companionDesign.suggestionType?.(t(0, "assistant", "[timer-offer] eight minutes?"))).toBe("timer-offer");
    expect(companionDesign.suggestionType?.(t(0, "assistant", "[step-offer] next step?"))).toBe("step-offer");
    expect(companionDesign.suggestionType?.(t(0, "assistant", "no suggestion here"))).toBeNull();
    expect(companionDesign.suggestionType?.(t(0, "assistant", "[unknown-type] not a companion marker"))).toBeNull();
  });

  test("rejection matcher: uses the shared default — explicit no-ish openers, not soft deflections", () => {
    // Deliberately unset: silence is a strong sanction and the companion
    // should not hear refusal in "maybe later" (see DESIGN.md).
    expect(companionDesign.isRejection).toBeUndefined();
    const suggester = script([
      t(0, "assistant", "[use-soon] spinach"),
      t(1, "user", "maybe later"),
      t(2, "assistant", "[use-soon] spinach again"),
      t(3, "user", "no"),
      t(4, "assistant", "[use-soon] once more"),
      t(5, "user", "nope"),
      t(6, "assistant", "[use-soon] and again")
    ]);
    const g = gateScript(suggester, companionDesign);
    // "maybe later" is NOT a rejection (only one accrued after turns 3 and 5),
    // so the third suggestion survives; the FOURTH is silenced.
    expect(g.suppressed).toEqual([{ turn: 6, because: "suggestion-type-silenced" }]);
  });

  test("the system prompt documents the knobs it must agree with", () => {
    // The prompt is not executed offline, but it must not drift from the
    // config: the numbers it names are pinned by these assertions.
    expect(companionDesign.systemPrompt).toContain("at most three times");
    expect(companionDesign.systemPrompt).toContain("two turns");
    expect(companionDesign.systemPrompt).toContain("never gives a safety verdict");
    expect(companionDesign.systemPrompt).toContain("You ask first");
  });
});
