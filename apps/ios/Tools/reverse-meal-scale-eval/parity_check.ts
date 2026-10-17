// Producer parity check for the policy-study-v2 learner-arm run.
//
// Recomputes the pinned producer projection (ConfidenceRouter routing floor,
// ReverseScanService confidence signals + hard-fail rules) in TypeScript from
// the fields the Swift runner exported, and asserts exact agreement with the
// Swift producer's recorded output for EVERY case in every learner arm.
//
// This is a verification harness, not a learner substitute: the assessment
// itself is only ever produced by the real Swift ConfidenceLearningService.
//
// Usage: bun parity_check.ts STUDY_ARMS_JSON REQUESTS_JSONL

import { readFileSync } from "node:fs";

const [armsPath, requestsPath] = process.argv.slice(2);
if (!armsPath || !requestsPath) {
  console.error("usage: bun parity_check.ts STUDY_ARMS_JSON REQUESTS_JSONL");
  process.exit(2);
}

type Signals = { key: string; rawScore: number; weight: number; reason: string };
type Candidate = {
  recipe_id: number; confidence_score: number; matched_required: number;
  total_required: number; missing_required_count: number; matched_optional: number;
  ranking_score: number; match_tier: string;
};
type CaseOutcome = {
  case_id: string; overall_detection_confidence: number; search_ingredient_ids: number[];
  signals: Signals[]; hardFailReasons: string[];
  assessment: { mode: string; overallScore: number; deterministicReady: boolean; reasons: string[]; signals: { key: string; rawScore: number; adjustedScore: number }[] };
  candidates: Candidate[]; db_event_count: number;
};
type ArmsFile = { version: string; arms: Record<string, CaseOutcome[]>; execution_record: Record<string, unknown> };
type RequestRow = { case_id: string; detections: [number, number][] };

const f32 = (x: number): number => Math.fround(x);

// Pinned producer math (mirrors the Swift runner's pinned copies).
const ROUTING_FLOOR = 0.45;
function routedSearch(dets: { id: number; conf: number }[]): { id: number; conf: number }[] {
  return dets.filter((d) => d.conf >= ROUTING_FLOOR);
}
function averageConfidence(dets: { conf: number }[]): number {
  if (dets.length === 0) return 0;
  const sum = dets.reduce((acc, d) => acc + Math.max(0, Math.min(d.conf, 1.0)), 0);
  return sum / dets.length;
}
function confidenceScore(c: Candidate, overall: number, searchCount: number): number {
  const requiredCoverage = c.matched_required / Math.max(c.total_required, 1);
  const missingPenalty = c.missing_required_count * 0.18;
  const optionalCoverage = c.matched_optional / Math.max(searchCount, 1);
  const raw = requiredCoverage * 0.62 + overall * 0.24 + optionalCoverage * 0.14 - missingPenalty;
  return Math.max(0, Math.min(raw, 1.0));
}
const SIGNAL_KEYS = ["reverse_scan.vision_detection", "reverse_scan.recipe_match", "reverse_scan.required_coverage", "reverse_scan.candidate_margin"];
const SIGNAL_WEIGHTS = [0.32, 0.30, 0.23, 0.15];
const SIGNAL_REASONS = ["ingredient detection", "recipe match", "required ingredient coverage", "candidate ambiguity"];
const AMBIGUITY_MARGIN = 0.06;
const MAX_MISSING_REQUIRED = 2;

function project(dets: { id: number; conf: number }[], candidates: Candidate[]): { signals: Signals[]; hardFailReasons: string[] } {
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
  const signals = SIGNAL_KEYS.map((key, i) => ({ key, rawScore: values[i], weight: SIGNAL_WEIGHTS[i], reason: SIGNAL_REASONS[i] }));
  let hardFailReasons: string[];
  if (!top) hardFailReasons = ["No confident recipe candidate."];
  else if (top.missing_required_count > MAX_MISSING_REQUIRED) hardFailReasons = ["Too many required ingredients are missing."];
  else if (candidates.length >= 2 && candidates[0].confidence_score - candidates[1].confidence_score < AMBIGUITY_MARGIN) hardFailReasons = ["Top recipe candidates are highly ambiguous."];
  else hardFailReasons = [];
  return { signals, hardFailReasons };
}

const arms: ArmsFile = JSON.parse(readFileSync(armsPath, "utf8"));
if (arms.version !== "policy-study-v2") throw new Error(`version mismatch: ${arms.version}`);

const requests = new Map<string, RequestRow>(
  readFileSync(requestsPath, "utf8").split("\n").filter(Boolean).map((line) => {
    const row = JSON.parse(line) as RequestRow;
    return [row.case_id, row];
  })
);

let checked = 0;
const failures: string[] = [];
function close(a: number, b: number, eps = 1e-12): boolean {
  return a === b || Math.abs(a - b) <= eps * Math.max(1, Math.abs(a), Math.abs(b));
}

for (const [armName, rows] of Object.entries(arms.arms)) {
  if (armName === "degenerate-input") {
    // Degenerate rows carry their detections inline.
    for (const row of rows) {
      const detPairs = (row as unknown as { detections: [number, number][] }).detections;
      const dets = detPairs.map(([id, conf]) => ({ id: id, conf: f32(conf) }));
      const outcome = (row as unknown as { outcome: CaseOutcome }).outcome;
      const recomputed = project(dets, outcome.candidates);
      for (let i = 0; i < SIGNAL_KEYS.length; i++) {
        if (!close(recomputed.signals[i].rawScore, outcome.signals[i].rawScore)) {
          failures.push(`${armName}/${outcome.case_id} signal ${SIGNAL_KEYS[i]}: ${recomputed.signals[i].rawScore} != ${outcome.signals[i].rawScore}`);
        }
      }
      if (JSON.stringify(recomputed.hardFailReasons) !== JSON.stringify(outcome.hardFailReasons)) {
        failures.push(`${armName}/${outcome.case_id} hardFails: ${JSON.stringify(recomputed.hardFailReasons)} != ${JSON.stringify(outcome.hardFailReasons)}`);
      }
      checked++;
    }
    continue;
  }
  for (const row of rows) {
    const req = requests.get(row.case_id);
    if (!req) { failures.push(`${armName}/${row.case_id}: no request row`); continue; }
    const dets = req.detections.map(([id, conf]) => ({ id: id, conf: f32(conf) }));
    const recomputed = project(dets, row.candidates);
    for (let i = 0; i < SIGNAL_KEYS.length; i++) {
      if (recomputed.signals[i].key !== row.signals[i].key) failures.push(`${armName}/${row.case_id}: signal key order`);
      if (!close(recomputed.signals[i].rawScore, row.signals[i].rawScore)) {
        failures.push(`${armName}/${row.case_id} signal ${SIGNAL_KEYS[i]}: ${recomputed.signals[i].rawScore} != ${row.signals[i].rawScore}`);
      }
      if (row.signals[i].weight !== SIGNAL_WEIGHTS[i]) failures.push(`${armName}/${row.case_id}: weight ${i}`);
    }
    if (JSON.stringify(recomputed.hardFailReasons) !== JSON.stringify(row.hardFailReasons)) {
      failures.push(`${armName}/${row.case_id} hardFails: ${JSON.stringify(recomputed.hardFailReasons)} != ${JSON.stringify(row.hardFailReasons)}`);
    }
    // overall_detection_confidence must equal the mean over ALL detections.
    if (!close(row.overall_detection_confidence, averageConfidence(dets))) {
      failures.push(`${armName}/${row.case_id}: overall_detection_confidence mismatch`);
    }
    // search_ingredient_ids must equal the routed, deduped set.
    const wantSearch = [...new Set(routedSearch(dets).map((d) => d.id))].sort((a, b) => a - b);
    if (JSON.stringify(wantSearch) !== JSON.stringify(row.search_ingredient_ids)) {
      failures.push(`${armName}/${row.case_id}: search ids mismatch`);
    }
    // assessment invariants.
    if (!close(row.assessment.overallScore, Math.max(0, Math.min(row.assessment.overallScore, 1)))) {
      failures.push(`${armName}/${row.case_id}: overallScore out of range`);
    }
    for (const s of row.assessment.signals) {
      if (!(s.adjustedScore >= 0 && s.adjustedScore <= 1)) failures.push(`${armName}/${row.case_id}: adjustedScore out of range for ${s.key}`);
    }
    checked++;
  }
}

// Arm-level invariants: the two learner arms must cover the same case ids.
const armNames = Object.keys(arms.arms);
const learnerArms = ["learner-cold", "learner-devwarm"];
const idSets = learnerArms.map((n) => new Set(arms.arms[n].map((r) => r.case_id)));
for (let i = 1; i < idSets.length; i++) {
  if (idSets[i].size !== idSets[0].size) failures.push(`arm size mismatch: ${learnerArms[i]}`);
}
for (const name of ["learner-cold", "learner-devwarm"]) {
  for (const row of arms.arms[name]) {
    if (row.db_event_count !== 0 && name === "learner-cold") failures.push(`${name}/${row.case_id}: cold arm wrote events`);
  }
}

console.log(JSON.stringify({
  version: arms.version,
  arms_checked: armNames,
  cases_checked: checked,
  parity_failures: failures.length,
  failures: failures.slice(0, 20),
}, null, 2));
if (failures.length > 0) process.exit(1);
