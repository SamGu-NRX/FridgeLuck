import { describe, expect, test } from "bun:test";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  checkParity,
  groupedCi95,
  loadVerifiedStudy,
  riskCoverageSweep,
  scoreStudy,
  StudyVerificationError,
  wilson95,
  type SweepPoint,
} from "../evaluation/policyStudyV2Scoring";

/**
 * Tests for the policy-study-v2 scoring layer
 * (src/evaluation/policyStudyV2Scoring.ts) over the frozen run
 * evaluation-fixtures/policy-study-v2/runs/2026-10-10-r1.
 *
 * Contract under test:
 *  - scoring refuses to run when any frozen input or run artifact fails byte
 *    verification (hash manifest), regardless of what changed;
 *  - scoring is deterministic and reproduces the committed summary byte-for-byte;
 *  - producer parity must recompute with zero failures over recorded outcomes;
 *  - no amount decision is adjudicable from this run (none imputed);
 *  - the degenerate arm failed closed and the live-decisions arm is reported
 *    not-run rather than imputed;
 *  - risk/coverage sweeps honor their declared score source.
 */

const FIXTURES = join(import.meta.dir, "../../evaluation-fixtures/policy-study-v2");

function makeTmpFixtureCopy(): string {
  const dir = mkdtempSync(join(tmpdir(), "policy-study-v2-tamper-"));
  cpSync(FIXTURES, dir, { recursive: true });
  return dir;
}

function patchRunFile(root: string, name: string, patch: (text: string) => string): void {
  const path = join(root, "runs", "2026-10-10-r1", name);
  writeFileSync(path, patch(readFileSync(path, "utf8")));
}

describe("policy-study-v2 scoring: reproducibility", () => {
  test("scoreStudy reproduces the committed scoring-summary.json exactly", () => {
    const committed = JSON.parse(
      readFileSync(join(FIXTURES, "runs", "2026-10-10-r1", "scoring-summary.json"), "utf8")
    );
    const recomputed = JSON.parse(JSON.stringify(scoreStudy(FIXTURES)));
    expect(recomputed).toEqual(committed);
  });
});

describe("policy-study-v2 scoring: verification and parity", () => {
  test("frozen inputs and run artifacts verify; cold arm records all 1,208 cases", () => {
    const { arms, registry } = loadVerifiedStudy(FIXTURES);
    expect(arms.arms["learner-cold"].length).toBe(1208);
    expect(arms.arms["learner-devwarm"].length).toBe(1208);
    expect(registry.filter((r) => r.slice === "eval").length).toBe(1008);
    expect(registry.filter((r) => r.slice === "dev").length).toBe(200);
  });

  test("producer parity recomputes with zero failures over recorded outcomes", () => {
    const { arms, requests } = loadVerifiedStudy(FIXTURES);
    const parity = checkParity(arms, requests);
    expect(parity.failures).toEqual([]);
    expect(parity.casesChecked).toBe(1208);
  });
});

describe("policy-study-v2 scoring: tamper refusal", () => {
  test("a modified byte in the frozen study-arms run artifact is refused", () => {
    const root = makeTmpFixtureCopy();
    try {
      patchRunFile(root, "study-arms.json", (t) => t.replace("learner-cold", "learner-coldX"));
      expect(() => scoreStudy(root)).toThrow(StudyVerificationError);
      expect(() => scoreStudy(root)).toThrow(/run artifact/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a deleted case from the run artifacts is refused", () => {
    const root = makeTmpFixtureCopy();
    try {
      patchRunFile(root, "study-arms.json", (t) => {
        const parsed = JSON.parse(t) as { arms: Record<string, unknown[]> };
        parsed.arms["learner-cold"] = parsed.arms["learner-cold"].slice(1);
        return JSON.stringify(parsed);
      });
      expect(() => scoreStudy(root)).toThrow(StudyVerificationError);
      expect(() => scoreStudy(root)).toThrow(/run artifact/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a modified frozen input is refused even when the run matches it", () => {
    const root = makeTmpFixtureCopy();
    try {
      const path = join(root, "requests.jsonl");
      const first = readFileSync(path, "utf8").split("\n");
      first[0] = first[0].replace(/\[\[/, "[[0.5,");
      writeFileSync(path, first.join("\n"));
      expect(() => scoreStudy(root)).toThrow(StudyVerificationError);
      expect(() => scoreStudy(root)).toThrow(/frozen input/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a missing run artifact is refused", () => {
    const root = makeTmpFixtureCopy();
    try {
      rmSync(join(root, "runs", "2026-10-10-r1", "parity-result.json"));
      rmSync(join(root, "runs", "2026-10-10-r1", "scoring-summary.json"));
      expect(() => scoreStudy(root)).toThrow(StudyVerificationError);
      expect(() => scoreStudy(root)).toThrow(/run artifact/);
      expect(existsSync(join(root, "runs", "2026-10-10-r1", "scoring-summary.json"))).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("policy-study-v2 scoring: honest-outcome guards", () => {
  const summary = scoreStudy(FIXTURES);

  test("no amount decision is adjudicable from this run; weighed-mass truth is counted, not imputed", () => {
    expect(summary.amount_outcomes.adjudicable_amount_decisions).toBe(0);
    expect(summary.amount_outcomes.weighed_mass_truth_cases).toBe(600);
  });

  test("the degenerate arm failed closed on every case", () => {
    expect(summary.degenerate_arm).toEqual({ cases: 12, all_failed_closed: true });
  });

  test("the live-decisions arm is reported not-run, not imputed", () => {
    expect(summary.live_decisions_arm).toMatch(/not-run/);
    expect(summary.live_decisions_arm).toMatch(/never imputed/);
  });

  test("trust statistics are flagged as non-calibrated learner statistics", () => {
    expect(summary.trust_caveat).toMatch(/not calibrated/);
  });

  test("the committed scoring summary hashes the committed study-arms file", () => {
    expect(summary.study_arms_sha256).toBe(
      "f2fac4f969ac89cb2b05af7801d078cbd6dcb328e648d4d0027c4e0e9294385f"
    );
  });
});

describe("policy-study-v2 scoring: identity evidence relabeling", () => {
  const summary = scoreStudy(FIXTURES);

  test("identity evidence is declared a synthetic mapped proxy, not photograph truth", () => {
    expect(summary.identity_evidence.kind).toBe("synthetic-mapped-proxy");
    expect(summary.identity_evidence.note).toMatch(/synthesized from the mapped recipe/);
    expect(summary.identity_evidence.note).toMatch(/No Food-101 photograph/);
  });

  test("every arm carries grouped intervals on identity and adoption precision", () => {
    for (const arm of Object.values(summary.arms)) {
      if (arm.top1_among_adjudicable_with_candidates.n === 0) {
        expect(arm.top1_among_adjudicable_with_candidates.grouped_ci95).toBeNull();
      } else {
        expect(arm.top1_among_adjudicable_with_candidates.grouped_ci95).toBeArrayOfSize(2);
        expect(arm.top1_among_adjudicable_with_candidates.grouped_ci95![0]).toBeLessThanOrEqual(
          arm.top1_among_adjudicable_with_candidates.grouped_ci95![1]
        );
      }
      if (arm.top3_among_adjudicable_with_candidates.n === 0) {
        expect(arm.top3_among_adjudicable_with_candidates.grouped_ci95).toBeNull();
      } else {
        expect(arm.top3_among_adjudicable_with_candidates.grouped_ci95).toBeArrayOfSize(2);
      }
      if (arm.adopt_precision != null) {
        expect(arm.adopt_precision_grouped_ci95).toBeArrayOfSize(2);
      } else {
        expect(arm.adopt_precision_grouped_ci95).toBeNull();
      }
    }
  });

  test("sweep points carry grouped precision intervals where any adjudicated case was adopted", () => {
    for (const points of Object.values(summary.risk_coverage)) {
      for (const p of points) {
        if (p.adjudicated === 0) expect(p.precision_grouped_ci95).toBeNull();
        else {
          expect(p.precision_grouped_ci95).toBeArrayOfSize(2);
          expect(p.precision_grouped_ci95![0]).toBeLessThanOrEqual(p.precision_grouped_ci95![1]);
        }
      }
    }
  });

  test("grouped intervals stay inside the degenerate bounds and round-trip deterministically", () => {
    const cold = summary.arms["learner-cold"].top1_among_adjudicable_with_candidates;
    const [lo, hi] = cold.grouped_ci95!;
    expect(lo).toBeGreaterThanOrEqual(0);
    expect(hi).toBeLessThanOrEqual(1);
    const again = scoreStudy(FIXTURES).arms["learner-cold"].top1_among_adjudicable_with_candidates;
    expect(again.grouped_ci95).toEqual(cold.grouped_ci95);
  });
});

describe("policy-study-v2 scoring: grouped bootstrap behavior", () => {
  test("within-cluster correlation widens the interval beyond the naive Wilson band", () => {
    // 100 clusters of 10 cases; each cluster is perfectly correlated
    // (all-success or all-failure). Pooled counts are 500/1000, whose naive
    // Wilson band is narrow; the cluster bootstrap must be wider.
    const clusters: string[][] = [];
    const indicator = new Map<string, boolean>();
    for (let g = 0; g < 100; g++) {
      const members: string[] = [];
      for (let c = 0; c < 10; c++) {
        const id = `g${g}-c${c}`;
        members.push(id);
        indicator.set(id, g < 50);
      }
      clusters.push(members);
    }
    const [lo, hi] = groupedCi95(clusters, indicator)!;
    const [wLo, wHi] = wilson95(500, 1000);
    expect(lo).toBeLessThan(wLo);
    expect(hi).toBeGreaterThan(wHi);
  });

  test("grouped bootstrap on singleton clusters is exact and repeats the seed", () => {
    const clusters: string[][] = [];
    const indicator = new Map<string, boolean>();
    for (let i = 0; i < 200; i++) {
      const id = `s${i}`;
      clusters.push([id]);
      indicator.set(id, i < 100);
    }
    const [lo1, hi1] = groupedCi95(clusters, indicator)!;
    const [lo2, hi2] = groupedCi95(clusters, indicator)!;
    expect(lo1).toBe(lo2);
    expect(hi1).toBe(hi2);
    // With singletons the bootstrap rate concentrates near the point estimate.
    expect(lo1).toBeLessThanOrEqual(0.5 + 1e-9);
    expect(hi1).toBeGreaterThanOrEqual(0.5 - 1e-9);
  });

  test("an empty cluster list yields null rather than a fabricated interval", () => {
    expect(groupedCi95([], new Map())).toBeNull();
  });
});

describe("policy-study-v2 scoring: risk/coverage score source", () => {
  test("learner sweeps use the learner overall score, not the producer confidence", () => {
    const { arms, requests, labels, registry } = loadVerifiedStudy(FIXTURES);
    const evalIds = new Set(registry.filter((r) => r.slice === "eval").map((r) => r.case_id));
    const coldEval = arms.arms["learner-cold"].filter((r) => evalIds.has(r.case_id));
    const byThreshold = (points: SweepPoint[]) => new Map(points.map((p) => [p.threshold, p.adopted]));
    const producer = byThreshold(riskCoverageSweep(coldEval, labels, "producer_top_confidence"));
    const learner = byThreshold(riskCoverageSweep(coldEval, labels, "learner_overall"));
    expect(producer.get(0.5)).toBe(280);
    expect(learner.get(0.5)).toBe(250);
  });
});
