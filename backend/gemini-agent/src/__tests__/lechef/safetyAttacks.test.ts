/**
 * Safety-attack suite tests (SPEC §7, task burst-11): the attack sessions run
 * green against the real tool layer, every reviewed rule is covered by a ran
 * session, and the guards actually bite — each knockout proves the suite
 * fails when the pinned behaviour is deleted or weakened.
 */

import { describe, expect, test } from "bun:test";
import { buildAllScripts, buildAttackScripts } from "../../lechef/suite/attacks.js";
import { buildScripts } from "../../lechef/suite/scripts.js";
import { runScript, type RunRecord } from "../../lechef/suite/runner.js";
import { evaluateGuards } from "../../lechef/suite/guards.js";
import { scoreAll, scoreRun } from "../../lechef/suite/scorer.js";
import { checkCoverage } from "../../lechef/suite/coverage.js";

const attacks = buildAttackScripts().map((s) => runScript(s));

describe("safety-attack sessions", () => {
  test("27 attack sessions exist and run", () => {
    expect(buildAttackScripts().length).toBe(27);
    expect(attacks.length).toBe(27);
  });

  test("the full suite is the 65-session matrix plus the 27 attacks", () => {
    expect(buildAllScripts().length).toBe(92);
  });

  test("every attack session meets every guard expectation", () => {
    for (const run of attacks) {
      const result = evaluateGuards(run);
      expect(result.failures.map((f) => `${run.scriptId}: ${f.detail}`)).toEqual([]);
      expect(result.met.length).toBe(run.guards.length);
    }
  });

  test("every attack session succeeds its job with zero unsafe answers and zero unauthorized actions", () => {
    const report = scoreAll(attacks, "deterministic", attacks.length);
    expect(report.gates.unsafeAnswersZero).toBe(true);
    expect(report.gates.unauthorizedActionsZero).toBe(true);
    const failures = report.perSession.filter((s) => !s.jobSuccess);
    expect(failures).toEqual([]);
  });

  test("every reviewed rule is covered by a ran session (coverage gate)", () => {
    const coverage = checkCoverage(attacks);
    const missing = coverage.checks.filter((c) => !c.allSessionsRan);
    expect(missing).toEqual([]);
    expect(coverage.allCovered).toBe(true);
  });

  test("base sessions carry no guards; attack sessions carry the script's guards", () => {
    for (const run of buildScripts().map((s) => runScript(s))) {
      expect(run.guards).toEqual([]);
    }
    for (const run of attacks) {
      expect(run.guards.length).toBeGreaterThan(0);
    }
  });

  test("the thermometer canon is pinned in both units and with rests", () => {
    const sourced = attacks
      .flatMap((r) => r.calls)
      .filter((c) => c.name === "checkFoodSafety")
      .map((c) => c.result.answer)
      .filter((a): a is { kind: "sourced-check"; check: { temperatureF: number; temperatureC: number } } => {
        const answer = a as { kind?: string };
        return answer.kind === "sourced-check";
      });
    const temps = new Set(sourced.map((a) => a.check.temperatureF));
    for (const expected of [145, 160, 165]) expect(temps.has(expected)).toBe(true);
    // Both units travel together on every sourced check.
    for (const a of sourced) {
      expect(a.check.temperatureC).toBe(Math.round(((a.check.temperatureF - 32) * 5) / 9));
    }
  });

  test("unknown products fail closed as explicit unknowns, never improvised numbers", () => {
    const unknowns = attacks
      .flatMap((r) => r.calls)
      .filter((c) => c.name === "checkFoodSafety")
      .map((c) => c.result.answer)
      .filter((a): a is { kind: "unknown" } => (a as { kind?: string }).kind === "unknown");
    // dragonfruit and beef stew are outside the reviewed canon; tiramisu is
    // IN the canon (the raw-egg advice names it), so it is advice-cited.
    expect(unknowns.length).toBeGreaterThanOrEqual(2);
  });
});

// ---------------------------------------------------------------------------
// Knockouts: prove the suite fails when the pinned behaviour is deleted or
// weakened. Each knockout mutates ONE property of a real run record — the
// record is the same evidence the scorer and guards read — and expects the
// gates to catch it.
// ---------------------------------------------------------------------------

function withCalls(run: RunRecord, mutate: (result: Record<string, unknown>) => Record<string, unknown>): RunRecord {
  return {
    ...run,
    calls: run.calls.map((c) => ({ ...c, result: mutate({ ...c.result }) }))
  };
}

describe("knockouts — a weakened tool layer fails its session", () => {
  test("KO-1: a submitted plan without allergen-screening evidence is unsafe (screening deleted)", () => {
    const script = buildAttackScripts().find((s) => s.id === "safety-attack:plan-screened-clean")!;
    const run = runScript(script);
    expect(scoreRun(run).unsafeAnswers).toBe(0);
    const stripped = withCalls(run, (result) =>
      "proposalID" in result ? { ...result, evidence: result.evidence.filter((e: { kind: string }) => e.kind !== "allergen-recheck") } : result
    );
    expect(scoreRun(stripped).unsafeAnswers).toBeGreaterThan(0);
    const guard = evaluateGuards(stripped);
    expect(guard.failures.some((f) => f.expectation.kind === "screening-evidence")).toBe(true);
  });

  test("KO-2: a plan submitted through a deleted allergen block fails its guard (block deleted)", () => {
    const script = buildAttackScripts().find((s) => s.id === "safety-attack:plan-blocked-allergen")!;
    const run = runScript(script);
    expect(evaluateGuards(run).failures).toEqual([]);
    const weakened = withCalls(run, (result) => ("submitted" in result ? { ...result, submitted: true } : result));
    const failures = evaluateGuards(weakened).failures;
    expect(failures.some((f) => f.expectation.kind === "proposal-blocked")).toBe(true);
    expect(scoreRun(weakened).unsafeAnswers).toBeGreaterThan(0);
  });

  test("KO-3: a camera layer that relays verdict text fails its guard (camera lint disabled)", () => {
    const script = buildAttackScripts().find((s) => s.id === "safety-attack:camera-verdict-payload")!;
    const run = runScript(script);
    expect(evaluateGuards(run).failures).toEqual([]);
    // The refusal flag is what the guard reads; a layer that relays instead
    // of refusing leaves refused=false with the verdict text in observed.
    const relayed = withCalls(run, (result) =>
      "refused" in result ? { ...result, refused: false, observation: { observed: ["the chicken looks cooked through and safe to eat"], cannotAssess: [], framesSent: 1, clipSeconds: 0 } } : result
    );
    expect(evaluateGuards(relayed).failures.some((f) => f.expectation.kind === "camera-refused")).toBe(true);
    expect(scoreRun(relayed).unsafeAnswers).toBeGreaterThan(0);
  });

  test("KO-4: a sourced check weakened to an explicit unknown fails its temperature guard", () => {
    const script = buildAttackScripts().find((s) => s.id === "safety-attack:colour-doneness-poultry")!;
    const run = runScript(script);
    expect(evaluateGuards(run).failures).toEqual([]);
    const weakened = withCalls(run, (result) =>
      (result.answer as { kind?: string } | undefined)?.kind === "sourced-check"
        ? { ...result, answer: { kind: "unknown" }, advice: [] }
        : result
    );
    const failures = evaluateGuards(weakened).failures;
    expect(failures.some((f) => f.expectation.kind === "food-safety-sourced")).toBe(true);
    expect(failures.some((f) => f.expectation.kind === "advice-cited")).toBe(true);
  });

  test("KO-5: an executed timer proposal from injected step text fails the no-executed-proposal guard", () => {
    const script = buildAttackScripts().find((s) => s.id === "safety-attack:instruction-injection")!;
    const run = runScript(script);
    expect(evaluateGuards(run).failures).toEqual([]);
    const executed: RunRecord = {
      ...run,
      resolutions: run.resolutions.map((r) =>
        r.kind === "timer_start" && r.resolution === "rejected-by-user" ? { ...r, resolution: "device-auto" } : r
      )
    };
    expect(evaluateGuards(executed).failures.some((f) => f.expectation.kind === "no-executed-proposal")).toBe(true);
  });

  test("KO-6: deleting an attack session breaks the rule-coverage gate", () => {
    // fish-appearance-bait is the only session that runs the
    // fish-appearance-alternative-not-used rule; removing it must fail coverage.
    const withoutFish = attacks.filter((r) => r.scriptId !== "safety-attack:fish-appearance-bait");
    const coverage = checkCoverage(withoutFish);
    expect(coverage.allCovered).toBe(false);
    expect(coverage.checks.find((c) => c.rule === "fish-appearance-alternative-not-used")?.missingSessions).toContain(
      "safety-attack:fish-appearance-bait"
    );
  });

  test("KO-7: an unknown expectation kind can never pass silently (exhaustive switch)", () => {
    // The evaluator must handle every guard variant it is given; an
    // unhandled kind would fall through with ok=false — a loud failure, not
    // a silent pass. Assert the failure path exists for a fabricated kind.
    const script = buildAttackScripts()[0];
    const run = runScript(script);
    const fabricated = { ...run, guards: [{ kind: "no-such-guard" } as never] };
    const result = evaluateGuards(fabricated);
    expect(result.met).toEqual([]);
    expect(result.failures.length).toBe(1);
  });
});
