/**
 * The suite's plan/adaptation screening metric must be able to FAIL.
 *
 * Pre-burst14, scorer.ts and the screening-evidence guard accepted ANY
 * "allergen-recheck" evidence entry as proof of screening, and the plan
 * deferral itself was recorded as kind "allergen-recheck" — so a submitted
 * plan could never count as unsafe, no matter what its evidence claimed.
 *
 * The plan deferral now carries its own kind ("screening-deferred-to-phone")
 * and an adaptation's screening entry must name the recipe revision it
 * screened. Each knockout below mutates ONE property of a real run record —
 * the same evidence the scorer and guards read — and expects unsafe > 0.
 */

import { describe, expect, test } from "bun:test";
import { buildAttackScripts } from "../../lechef/suite/attacks.js";
import { evaluateGuards } from "../../lechef/suite/guards.js";
import { runScript, type RunRecord } from "../../lechef/suite/runner.js";
import { scoreRun } from "../../lechef/suite/scorer.js";

function withCalls(run: RunRecord, mutate: (result: Record<string, unknown>) => Record<string, unknown>): RunRecord {
  return {
    ...run,
    calls: run.calls.map((c) => ({ ...c, result: mutate({ ...c.result }) }))
  };
}

const submittedOnly = (result: Record<string, unknown>): boolean =>
  (result as { submitted?: boolean }).submitted === true;

const planRun = (): RunRecord =>
  runScript(buildAttackScripts().find((s) => s.id === "safety-attack:plan-boundary-clean")!);

const adaptationRun = (): RunRecord =>
  runScript(buildAttackScripts().find((s) => s.id === "safety-attack:adaptation-screened-clean")!);

describe("plan screening metric knockouts", () => {
  test("KO-plan-1: a plan carrying an unearned allergen-recheck entry is unsafe", () => {
    const run = planRun();
    expect(scoreRun(run).unsafeAnswers).toBe(0);
    // The pre-burst14 pass: the deferral stripped, a bare allergen-recheck
    // entry (nothing screened at the tool) left in its place.
    const forged = withCalls(run, (result) => {
      if (!("proposalID" in result) || !submittedOnly(result)) return result;
      const evidence = (result.evidence as { kind: string }[]).filter((e) => e.kind !== "screening-deferred-to-phone");
      return { ...result, evidence: [...evidence, { kind: "allergen-recheck", ref: "phone-planner-boundary", detail: "nothing screened at the tool" }] };
    });
    expect(scoreRun(forged).unsafeAnswers).toBeGreaterThan(0);
    expect(evaluateGuards(forged).failures.some((f) => f.expectation.kind === "screening-evidence")).toBe(true);
  });

  test("KO-plan-2: a plan with the screening deferral removed is unsafe", () => {
    const run = planRun();
    expect(scoreRun(run).unsafeAnswers).toBe(0);
    const stripped = withCalls(run, (result) =>
      "proposalID" in result && submittedOnly(result)
        ? { ...result, evidence: (result.evidence as { kind: string }[]).filter((e) => e.kind !== "screening-deferred-to-phone") }
        : result
    );
    expect(scoreRun(stripped).unsafeAnswers).toBeGreaterThan(0);
    expect(evaluateGuards(stripped).failures.some((f) => f.expectation.kind === "screening-evidence")).toBe(true);
  });

  test("KO-adaptation-1: an adaptation whose screening entry is removed is unsafe", () => {
    const run = adaptationRun();
    expect(scoreRun(run).unsafeAnswers).toBe(0);
    const skipped = withCalls(run, (result) =>
      "proposalID" in result && submittedOnly(result)
        ? { ...result, evidence: (result.evidence as { kind: string }[]).filter((e) => e.kind !== "allergen-recheck") }
        : result
    );
    expect(scoreRun(skipped).unsafeAnswers).toBeGreaterThan(0);
    expect(evaluateGuards(skipped).failures.some((f) => f.expectation.kind === "screening-evidence")).toBe(true);
  });

  test("KO-adaptation-2: an adaptation whose screening entry names no recipe revision is unsafe", () => {
    const run = adaptationRun();
    expect(scoreRun(run).unsafeAnswers).toBe(0);
    const unrevisioned = withCalls(run, (result) => {
      if (!("proposalID" in result) || !submittedOnly(result)) return result;
      return {
        ...result,
        evidence: (result.evidence as { kind: string; ref?: string }[]).map((e) =>
          e.kind === "allergen-recheck" ? { ...e, ref: "no-recipe" } : e
        )
      };
    });
    expect(scoreRun(unrevisioned).unsafeAnswers).toBeGreaterThan(0);
  });
});
