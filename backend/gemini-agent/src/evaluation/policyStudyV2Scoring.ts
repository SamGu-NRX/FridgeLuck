// Scorer for the frozen policy-study-v2 arm run (spec: §8 scoring-time).
//
// Contract, in order:
//  1. Verify frozen inputs byte-for-byte against the committed
//     build-manifest.json file_sha256 record.
//  2. Verify the committed arm run byte-for-byte against
//     runs/2026-10-10-r1/run-manifest.json (sha256 of every artifact).
//  3. Recompute the producer projection (4 signals + hard-fail rules) for
//     every recorded outcome and require exact parity with the Swift
//     producer's exported values.
//  4. Only then score: dish-identity outcomes, risk-vs-coverage sweeps,
//     friction, collision groups, and amount-target coverage. Trust
//     statistics are reported but never treated as calibrated correctness
//     probabilities.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const RUN_ID = "2026-10-10-r1";

export type Signals = { key: string; rawScore: number; weight: number; reason: string };
export type Candidate = {
  recipe_id: number;
  confidence_score: number;
  matched_required: number;
  total_required: number;
  missing_required_count: number;
  matched_optional: number;
  ranking_score: number;
  match_tier: string;
};
export type CaseOutcome = {
  case_id: string;
  overall_detection_confidence: number;
  search_ingredient_ids: number[];
  signals: Signals[];
  hardFailReasons: string[];
  assessment: {
    mode: string;
    overallScore: number;
    deterministicReady: boolean;
    reasons: string[];
    signals: { key: string; rawScore: number; adjustedScore: number; trustMean: number; trustUncertainty: number; weight: number; reason: string }[];
  };
  candidates: Candidate[];
  db_event_count: number;
};
export type ArmsFile = {
  version: string;
  arms: { "learner-cold": CaseOutcome[]; "learner-devwarm": CaseOutcome[]; "degenerate-input": unknown[] };
  execution_record: Record<string, number>;
};
export type RequestRow = { case_id: string; detections: [number, number][] };
export type LabelRow = {
  case_id: string;
  stratum: string;
  truth_ingredient_ids: number[];
  optional_ingredient_ids: number[];
  targets: {
    native_recipe_identity: { mapped_recipe_id: number | null };
    dish_category: { food101_class: string | null };
    weighed_mass: unknown;
  };
};
export type RegistryRow = { case_id: string; slice: string; stratum: string };

export class StudyVerificationError extends Error {}

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function require(condition: boolean, message: string): void {
  if (!condition) throw new StudyVerificationError(message);
}

// --- Pinned producer projection (mirrors the Swift runner's pinned copies) ---

const ROUTING_FLOOR = 0.45;
const AMBIGUITY_MARGIN = 0.06;
const MAX_MISSING_REQUIRED = 2;
const SIGNAL_KEYS = [
  "reverse_scan.vision_detection",
  "reverse_scan.recipe_match",
  "reverse_scan.required_coverage",
  "reverse_scan.candidate_margin",
];
const SIGNAL_WEIGHTS = [0.32, 0.3, 0.23, 0.15];

export type Det = { id: number; conf: number };

export function routedSearch(dets: Det[]): Det[] {
  return dets.filter((d) => d.conf >= ROUTING_FLOOR);
}
export function averageConfidence(dets: Det[]): number {
  if (dets.length === 0) return 0;
  const sum = dets.reduce((acc, d) => acc + Math.max(0, Math.min(d.conf, 1.0)), 0);
  return sum / dets.length;
}
export function project(
  dets: Det[],
  candidates: Candidate[]
): { signals: Signals[]; hardFailReasons: string[] } {
  const overall = averageConfidence(dets);
  const searchCount = new Set(routedSearch(dets).map((d) => d.id)).size;
  const top = candidates[0];
  const topScore = top ? top.confidence_score : 0;
  const requiredCoverage = top ? top.matched_required / Math.max(top.total_required, 1) : 0;
  let marginScore: number;
  if (candidates.length >= 2) {
    const margin = Math.max(0, candidates[0].confidence_score - candidates[1].confidence_score);
    marginScore = Math.max(0, Math.min(0.5 + margin, 1.0));
  } else if (candidates.length === 1) {
    marginScore = 0.82;
  } else {
    marginScore = 0;
  }
  const values = [overall, topScore, requiredCoverage, marginScore];
  const signals = SIGNAL_KEYS.map((key, i) => ({
    key,
    rawScore: values[i],
    weight: SIGNAL_WEIGHTS[i],
    reason: "",
  }));
  let hardFailReasons: string[];
  if (!top) hardFailReasons = ["No confident recipe candidate."];
  else if (top.missing_required_count > MAX_MISSING_REQUIRED)
    hardFailReasons = ["Too many required ingredients are missing."];
  else if (
    candidates.length >= 2 &&
    candidates[0].confidence_score - candidates[1].confidence_score < AMBIGUITY_MARGIN
  )
    hardFailReasons = ["Top recipe candidates are highly ambiguous."];
  else hardFailReasons = [];
  return { signals, hardFailReasons };
}

// --- Loading with byte verification ---

export type StudyPaths = {
  fixtureDir: string;
  runDir: string;
};

export function loadVerifiedStudy(fixturesRoot: string): {
  paths: StudyPaths;
  arms: ArmsFile;
  requests: Map<string, RequestRow>;
  labels: Map<string, LabelRow>;
  registry: RegistryRow[];
} {
  const fixtureDir = fixturesRoot;
  const runDir = join(fixtureDir, "runs", RUN_ID);
  require(existsSync(runDir), `run dir missing: ${RUN_ID}`);

  // 1. Frozen study inputs must match the committed build manifest.
  const buildManifest = JSON.parse(readFileSync(join(fixtureDir, "build-manifest.json"), "utf8")) as {
    file_sha256: Record<string, string>;
  };
  for (const [name, want] of Object.entries(buildManifest.file_sha256)) {
    const p = join(fixtureDir, name);
    require(existsSync(p), `frozen input missing: ${name}`);
    require(sha256File(p) === want, `frozen input tampered: ${name}`);
  }

  // 2. The committed arm run must match its recorded hashes.
  const runManifest = JSON.parse(readFileSync(join(runDir, "run-manifest.json"), "utf8")) as Record<
    string,
    string
  >;
  for (const [name, want] of Object.entries(runManifest)) {
    const p = join(runDir, name);
    require(existsSync(p), `run artifact missing: ${name}`);
    require(sha256File(p) === want, `run artifact tampered: ${name}`);
  }

  const arms = JSON.parse(readFileSync(join(runDir, "study-arms.json"), "utf8")) as ArmsFile;
  require(arms.version === "policy-study-v2", `arms version: ${arms.version}`);

  const requests = new Map<string, RequestRow>();
  for (const line of readFileSync(join(fixtureDir, "requests.jsonl"), "utf8").split("\n")) {
    if (!line) continue;
    const row = JSON.parse(line) as RequestRow;
    requests.set(row.case_id, row);
  }
  const labels = new Map<string, LabelRow>();
  for (const line of readFileSync(join(fixtureDir, "labels.jsonl"), "utf8").split("\n")) {
    if (!line) continue;
    const row = JSON.parse(line) as LabelRow;
    labels.set(row.case_id, row);
  }
  const registry = readFileSync(join(fixtureDir, "cases.jsonl"), "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as RegistryRow);
  return { paths: { fixtureDir, runDir }, arms, requests, labels, registry };
}

// --- Parity: recompute the producer projection for every recorded outcome ---

export type ParityResult = { casesChecked: number; failures: string[] };

export function checkParity(arms: ArmsFile, requests: Map<string, RequestRow>): ParityResult {
  const failures: string[] = [];
  let casesChecked = 0;
  const close = (a: number, b: number): boolean =>
    a === b || Math.abs(a - b) <= 1e-12 * Math.max(1, Math.abs(a), Math.abs(b));

  for (const row of arms.arms["learner-cold"]) {
    const req = requests.get(row.case_id);
    if (!req) {
      failures.push(`learner-cold/${row.case_id}: no request row`);
      continue;
    }
    const dets: Det[] = req.detections.map(([id, conf]) => ({ id, conf: Math.fround(conf) }));
    const recomputed = project(dets, row.candidates);
    for (let i = 0; i < SIGNAL_KEYS.length; i++) {
      if (!close(recomputed.signals[i].rawScore, row.signals[i].rawScore))
        failures.push(`learner-cold/${row.case_id}: signal ${SIGNAL_KEYS[i]}`);
    }
    if (JSON.stringify(recomputed.hardFailReasons) !== JSON.stringify(row.hardFailReasons))
      failures.push(`learner-cold/${row.case_id}: hardFails`);
    if (!close(row.overall_detection_confidence, averageConfidence(dets)))
      failures.push(`learner-cold/${row.case_id}: overall`);
    casesChecked++;
  }
  return { casesChecked, failures };
}

// --- Policies ---

export type Decision = "adopt_top_pick" | "review" | "estimate_only" | "no_candidate";

export function learnerDecision(row: CaseOutcome): Decision {
  if (row.candidates.length === 0) return "no_candidate";
  if (row.assessment.deterministicReady && row.hardFailReasons.length === 0) return "adopt_top_pick";
  if (row.assessment.mode === "review_required") return "review";
  return "estimate_only";
}
export function fixedRuleDecision(row: CaseOutcome): Decision {
  if (row.candidates.length === 0) return "no_candidate";
  return row.hardFailReasons.length === 0 ? "adopt_top_pick" : "review";
}
export function alwaysCheckDecision(_row: CaseOutcome): Decision {
  return "review";
}
export const POLICIES: Record<string, (row: CaseOutcome) => Decision> = {
  "learner-cold": learnerDecision,
  "learner-devwarm": learnerDecision,
  "fixed-rule-top-pick": fixedRuleDecision,
  "always-check": alwaysCheckDecision,
};

// --- Statistics ---

export function wilson95(successes: number, n: number): [number, number] {
  if (n === 0) return [0, 0];
  const z = 1.959963984540054;
  const p = successes / n;
  const denom = 1 + (z * z) / n;
  const center = (p + (z * z) / (2 * n)) / denom;
  const spread = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / denom;
  return [Math.max(0, center - spread), Math.min(1, center + spread)];
}

// --- Grouped (cluster) bootstrap confidence intervals ---
//
// Evaluation cases are not independent: cases with byte-identical producer
// evidence (producer-equivalence groups) necessarily share outcomes, so the
// study protocol requires grouped intervals. We resample producer-equivalence
// groups with replacement (cluster bootstrap) and recompute the rate over all
// cases in the sampled groups. Deterministic: seeded mulberry32, fixed
// iteration count, so the committed summary is byte-reproducible.

export const GROUPED_BOOTSTRAP_ITERATIONS = 10000;
export const GROUPED_BOOTSTRAP_SEED = 20261010;

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function groupedCi95(
  clusters: string[][],
  indicator: Map<string, boolean>,
  iterations: number = GROUPED_BOOTSTRAP_ITERATIONS,
  seed: number = GROUPED_BOOTSTRAP_SEED
): [number, number] | null {
  if (clusters.length === 0) return null;
  const rand = mulberry32(seed);
  const rates = new Array<number>(iterations);
  for (let it = 0; it < iterations; it++) {
    let succ = 0;
    let n = 0;
    for (let g = 0; g < clusters.length; g++) {
      for (const id of clusters[(rand() * clusters.length) | 0]) {
        const v = indicator.get(id);
        if (v === undefined) continue;
        n += 1;
        if (v) succ += 1;
      }
    }
    rates[it] = n === 0 ? 0 : succ / n;
  }
  rates.sort((a, b) => a - b);
  return [rates[Math.floor(0.025 * iterations)], rates[Math.ceil(0.975 * iterations) - 1]];
}

// Cluster the given case ids by producer-equivalence group (singletons when
// no group map is supplied).
export function clustersFor(ids: Iterable<string>, groupKeys?: Map<string, string>): string[][] {
  if (!groupKeys) return [...ids].map((id) => [id]);
  const byKey = new Map<string, string[]>();
  for (const id of ids) {
    const key = groupKeys.get(id) ?? id;
    const bucket = byKey.get(key) ?? [];
    if (bucket.length === 0) byKey.set(key, bucket);
    bucket.push(id);
  }
  return [...byKey.values()];
}

export type ArmMetrics = {
  policy: string;
  cases: number;
  decisions: Record<Decision, number>;
  adopt_rate: number;
  friction_rate: number;
  identity_adjudicable: number;
  adopted_with_known_identity: number;
  adopted_correct_identity: number;
  adopt_precision: number | null;
  adopt_precision_wilson95: [number, number] | null;
  adopt_precision_grouped_ci95: [number, number] | null;
  top1_among_adjudicable_with_candidates: { n: number; correct: number; rate: number; wilson95: [number, number]; grouped_ci95: [number, number] | null };
  top3_among_adjudicable_with_candidates: { n: number; correct: number; rate: number; wilson95: [number, number]; grouped_ci95: [number, number] | null };
};

export function scoreArm(
  policyName: string,
  decide: (row: CaseOutcome) => Decision,
  rows: CaseOutcome[],
  labels: Map<string, LabelRow>,
  groupKeys?: Map<string, string>
): ArmMetrics {
  const decisions: Record<Decision, number> = {
    adopt_top_pick: 0,
    review: 0,
    estimate_only: 0,
    no_candidate: 0,
  };
  let adoptedKnown = 0;
  let adoptedCorrect = 0;
  let adjudicable = 0;
  let top1N = 0;
  let top1Correct = 0;
  let top3N = 0;
  let top3Correct = 0;
  const top1Indicator = new Map<string, boolean>();
  const top3Indicator = new Map<string, boolean>();
  const adoptIndicator = new Map<string, boolean>();
  for (const row of rows) {
    const d = decide(row);
    decisions[d] += 1;
    const label = labels.get(row.case_id);
    const trueId = label?.targets?.native_recipe_identity?.mapped_recipe_id ?? null;
    if (trueId != null) adjudicable += 1;
    if (row.candidates.length > 0 && trueId != null) {
      top1N += 1;
      const ok1 = row.candidates[0].recipe_id === trueId;
      top1Indicator.set(row.case_id, ok1);
      if (ok1) top1Correct += 1;
      const top3 = new Set(row.candidates.slice(0, 3).map((c) => c.recipe_id));
      const ok3 = top3.has(trueId);
      top3Indicator.set(row.case_id, ok3);
      top3N += 1;
      if (ok3) top3Correct += 1;
    }
    if (d === "adopt_top_pick" && trueId != null) {
      adoptedKnown += 1;
      const ok = row.candidates[0].recipe_id === trueId;
      adoptIndicator.set(row.case_id, ok);
      if (ok) adoptedCorrect += 1;
    }
  }
  const n = rows.length;
  const adopts = decisions.adopt_top_pick;
  const friction = decisions.review + decisions.estimate_only + decisions.no_candidate;
  return {
    policy: policyName,
    cases: n,
    decisions,
    adopt_rate: n === 0 ? 0 : adopts / n,
    friction_rate: n === 0 ? 0 : friction / n,
    identity_adjudicable: adjudicable,
    adopted_with_known_identity: adoptedKnown,
    adopted_correct_identity: adoptedCorrect,
    adopt_precision: adoptedKnown === 0 ? null : adoptedCorrect / adoptedKnown,
    adopt_precision_wilson95: adoptedKnown === 0 ? null : wilson95(adoptedCorrect, adoptedKnown),
    adopt_precision_grouped_ci95: groupedCi95(clustersFor(adoptIndicator.keys(), groupKeys), adoptIndicator),
    top1_among_adjudicable_with_candidates: {
      n: top1N,
      correct: top1Correct,
      rate: top1N === 0 ? 0 : top1Correct / top1N,
      wilson95: wilson95(top1Correct, top1N),
      grouped_ci95: groupedCi95(clustersFor(top1Indicator.keys(), groupKeys), top1Indicator),
    },
    top3_among_adjudicable_with_candidates: {
      n: top3N,
      correct: top3Correct,
      rate: top3N === 0 ? 0 : top3Correct / top3N,
      wilson95: wilson95(top3Correct, top3N),
      grouped_ci95: groupedCi95(clustersFor(top3Indicator.keys(), groupKeys), top3Indicator),
    },
  };
}

// --- Risk vs coverage: sweep an adoption threshold over the top-candidate
// producer confidence (fixed-rule family). Risk = 1 - precision on adopted
// cases with known identity; coverage = adoption rate over all eval cases. ---

export type SweepPoint = {
  threshold: number;
  adopted: number;
  coverage: number;
  adjudicated: number;
  correct: number;
  risk: number | null;
  precision_grouped_ci95: [number, number] | null;
};

export function riskCoverageSweep(
  rows: CaseOutcome[],
  labels: Map<string, LabelRow>,
  scoreSource: "producer_top_confidence" | "learner_overall" = "producer_top_confidence",
  groupKeys?: Map<string, string>
): SweepPoint[] {
  const points: SweepPoint[] = [];
  for (const t of [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]) {
    let adopted = 0;
    let adjudicated = 0;
    let correct = 0;
    const precIndicator = new Map<string, boolean>();
    for (const row of rows) {
      const top = row.candidates[0];
      if (!top) continue;
      const score = scoreSource === "learner_overall" ? row.assessment.overallScore : top.confidence_score;
      if (score < t) continue;
      if (row.hardFailReasons.length > 0) continue;
      adopted += 1;
      const trueId = labels.get(row.case_id)?.targets?.native_recipe_identity?.mapped_recipe_id ?? null;
      if (trueId != null) {
        adjudicated += 1;
        const ok = top.recipe_id === trueId;
        precIndicator.set(row.case_id, ok);
        if (ok) correct += 1;
      }
    }
    points.push({
      threshold: t,
      adopted,
      coverage: rows.length === 0 ? 0 : adopted / rows.length,
      adjudicated,
      correct,
      risk: adjudicated === 0 ? null : 1 - correct / adjudicated,
      precision_grouped_ci95: groupedCi95(
        clustersFor(precIndicator.keys(), groupKeys),
        precIndicator
      ),
    });
  }
  return points;
}

// --- Collision groups (producer level): canonical 4-signal request including
// hard-fail reasons; groups with distinct label signatures are information
// limits -- arm differences inside them are chance, reported separately. ---

// Producer-equivalence group key per case. Shared by the collision report and
// the grouped bootstrap intervals.
export function producerGroupKeys(
  rows: CaseOutcome[],
  requests: Map<string, RequestRow>
): Map<string, string> {
  const out = new Map<string, string>();
  const groups = new Map<string, string[]>();
  for (const row of rows) {
    const req = requests.get(row.case_id);
    const dets: Det[] = (req?.detections ?? []).map(([id, conf]) => ({ id, conf: Math.fround(conf) }));
    const p = project(dets, row.candidates);
    const key = JSON.stringify([p.signals.map((s) => s.rawScore), p.hardFailReasons]);
    const bucket = groups.get(key) ?? [];
    if (bucket.length === 0) groups.set(key, bucket);
    bucket.push(row.case_id);
  }
  for (const [key, members] of groups) for (const id of members) out.set(id, key);
  return out;
}

export type CollisionReport = {
  producer_groups: number;
  largest_group_size: number;
  eval_cases_in_multi_groups: number;
  multi_groups_with_diverse_label_signatures: {
    size: number;
    eval_cases: number;
    distinct_label_signatures: number;
    empty_evidence: boolean;
  }[];
};

export function producerCollisions(
  rows: CaseOutcome[],
  requests: Map<string, RequestRow>,
  labels: Map<string, LabelRow>
): CollisionReport {
  const groupKeys = producerGroupKeys(rows, requests);
  const groups = new Map<string, string[]>();
  for (const row of rows) {
    const key = groupKeys.get(row.case_id) ?? row.case_id;
    const bucket = groups.get(key) ?? [];
    if (bucket.length === 0) groups.set(key, bucket);
    bucket.push(row.case_id);
  }
  const multi = [...groups.values()].filter((g) => g.length > 1);
  const detailed = multi.map((members) => {
    const sigs = new Set(
      members.map((id) => {
        const l = labels.get(id);
        return JSON.stringify([
          l?.targets?.native_recipe_identity ?? null,
          l?.targets?.dish_category ?? null,
          l?.targets?.weighed_mass ?? null,
          l?.truth_ingredient_ids ?? null,
        ]);
      })
    );
    const empty = members.every((id) => (requests.get(id)?.detections.length ?? -1) === 0);
    return {
      size: members.length,
      eval_cases: members.length,
      distinct_label_signatures: sigs.size,
      empty_evidence: empty,
    };
  });
  return {
    producer_groups: groups.size,
    largest_group_size: multi.reduce((m, g) => Math.max(m, g.length), 1),
    eval_cases_in_multi_groups: multi.reduce((s, g) => s + g.length, 0),
    multi_groups_with_diverse_label_signatures: detailed.filter((g) => g.distinct_label_signatures > 1),
  };
}

// --- Full scoring entry ---

export type StudySummary = {
  run_id: string;
  study_arms_sha256: string;
  eval_cases: number;
  dev_cases_excluded: number;
  arms: Record<string, ArmMetrics>;
  risk_coverage: Record<string, SweepPoint[]>;
  collisions: CollisionReport;
  identity_evidence: { kind: string; note: string };
  amount_outcomes: {
    weighed_mass_truth_cases: number;
    adjudicable_amount_decisions: number;
    note: string;
  };
  trust_caveat: string;
  degenerate_arm: { cases: number; all_failed_closed: boolean };
  live_decisions_arm: string;
};

export function scoreStudy(fixturesRoot: string): StudySummary {
  const { paths, arms, requests, labels, registry } = loadVerifiedStudy(fixturesRoot);
  const evalIds = new Set(registry.filter((r) => r.slice === "eval").map((r) => r.case_id));

  // Parity gate before any metric is computed.
  const parity = checkParity(arms, requests);
  require(parity.failures.length === 0, `producer parity failed: ${parity.failures.slice(0, 5).join("; ")}`);

  // The learner arms include dev rows; score the eval slice only.
  const coldEval = arms.arms["learner-cold"].filter((r) => evalIds.has(r.case_id));
  const warmEval = arms.arms["learner-devwarm"].filter((r) => evalIds.has(r.case_id));
  require(coldEval.length === evalIds.size, `cold arm eval size: ${coldEval.length} != ${evalIds.size}`);
  require(warmEval.length === evalIds.size, `warm arm eval size: ${warmEval.length} != ${evalIds.size}`);

  const armPairs: [string, CaseOutcome[]][] = [
    ["learner-cold", coldEval],
    ["learner-devwarm", warmEval],
    ["fixed-rule-top-pick", coldEval],
    ["always-check", coldEval],
  ];
  // Producer-equivalence groups (eval slice): shared by the collision report
  // and every grouped interval below.
  const groupKeys = producerGroupKeys(coldEval, requests);
  const scored: Record<string, ArmMetrics> = {};
  for (const [name, rows] of armPairs) {
    scored[name] = scoreArm(name, POLICIES[name], rows, labels, groupKeys);
  }

  let massTruth = 0;
  for (const id of evalIds) {
    if (labels.get(id)?.targets?.weighed_mass != null) massTruth += 1;
  }

  const degenerate = arms.arms["degenerate-input"] as { case_id: string; outcome: CaseOutcome }[];
  const allFailedClosed = degenerate.every(
    (d) =>
      d.outcome.db_event_count === 0 &&
      (d.outcome.hardFailReasons.length > 0 || d.outcome.candidates.length > 0)
  );

  return {
    run_id: RUN_ID,
    study_arms_sha256: sha256File(join(paths.runDir, "study-arms.json")),
    eval_cases: evalIds.size,
    dev_cases_excluded: arms.arms["learner-cold"].length - evalIds.size,
    arms: scored,
    risk_coverage: {
      "fixed-rule-top-pick": riskCoverageSweep(coldEval, labels, "producer_top_confidence", groupKeys),
      "learner-cold": riskCoverageSweep(coldEval, labels, "learner_overall", groupKeys),
      "learner-devwarm": riskCoverageSweep(warmEval, labels, "learner_overall", groupKeys),
    },
    collisions: producerCollisions(coldEval, requests, labels),
    identity_evidence: {
      kind: "synthetic-mapped-proxy",
      note: "Naming correction (review of PR #46): Food-101 case 'detections' are synthesized from the mapped recipe's own required/optional ingredient list (build_cases.py draw_detections, food101-photo stratum); the native_recipe_identity target names the recipe that generated the evidence. No Food-101 photograph was downloaded or used. Every identity metric in this summary therefore measures mapped-recipe recovery from synthetic mapped evidence, not photograph recipe recognition. The frozen field name is historical; frozen inputs are hash-locked and unchanged.",
    },
    amount_outcomes: {
      weighed_mass_truth_cases: massTruth,
      adjudicable_amount_decisions: 0,
      note: "The request family models identity+confidence evidence only; the runner exports no per-ingredient quantity decisions, so no amount outcome is adjudicable in this run. Weighed-mass truth is committed for a future amount study; nothing is imputed.",
    },
    trust_caveat:
      "Trust means and overall scores are learner statistics, not calibrated correctness probabilities; adopt decisions are gated on deterministic readiness and hard-fail rules, and precision is reported only on adjudicated identities.",
    degenerate_arm: { cases: degenerate.length, all_failed_closed: allFailedClosed },
    live_decisions_arm: "not-run: no operator-supplied access or spend limits; never imputed",
  };
}
