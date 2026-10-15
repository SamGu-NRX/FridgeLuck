import { exactObject, nonemptyString, type RoutingRequest } from "./routingInput.js";
import { decodeStrict } from "./runRouting.js";
import { canonicalJson } from "./canonicalJson.js";

export const SIGNAL_KEYS = ["reverse_scan.vision_detection", "reverse_scan.recipe_match", "reverse_scan.required_coverage", "reverse_scan.candidate_margin"] as const;
export const SIGNAL_WEIGHTS = [0.32, 0.30, 0.23, 0.15] as const;
export const SIGNAL_REASONS = ["ingredient detection", "recipe match", "required ingredient coverage", "candidate ambiguity"] as const;
export const HARD_FAILS = {
  no_candidate: "No confident recipe candidate.",
  missing_required: "Too many required ingredients are missing.",
  ambiguity: "Top recipe candidates are highly ambiguous."
} as const;
export interface RankedCandidate { id: number; confidence_score: number; matched_required: number; total_required: number; missing_required_count: number }
export interface ProducerState { detection_confidences: number[]; ranked_candidates: RankedCandidate[] }
export interface StateRow { case_id: string; producer_state: ProducerState }
function range(value: unknown, path: string): asserts value is number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) throw new Error(`${path}: expected finite number in [0,1]`);
}
function integer(value: unknown, path: string): asserts value is number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error(`${path}: expected safe integer`);
}
export function validateState(value: unknown): asserts value is ProducerState {
  const s = exactObject(value, ["detection_confidences", "ranked_candidates"], "producer_state");
  if (!Array.isArray(s.detection_confidences) || !Array.isArray(s.ranked_candidates)) throw new Error("producer_state: expected arrays");
  s.detection_confidences.forEach((v, i) => range(v, `detection_confidences[${i}]`));
  const ids = new Set<number>();
  let previous = Infinity;
  for (const [i, value] of s.ranked_candidates.entries()) {
    const p = `ranked_candidates[${i}]`;
    const c = exactObject(value, ["id", "confidence_score", "matched_required", "total_required", "missing_required_count"], p);
    integer(c.id, `${p}.id`);
    if (c.id <= 0 || ids.has(c.id)) throw new Error(`${p}.id: expected unique positive ID`);
    ids.add(c.id);
    range(c.confidence_score, `${p}.confidence_score`);
    for (const key of ["matched_required", "total_required", "missing_required_count"]) integer(c[key], `${p}.${key}`);
    const matched = c.matched_required as number, total = c.total_required as number;
    if (total < 1 || matched < 0 || matched > total || matched > s.detection_confidences.length || c.missing_required_count !== total - matched) throw new Error(`${p}: inconsistent required counts`);
    if (c.confidence_score > previous) throw new Error(`${p}: final ranking is not descending`);
    previous = c.confidence_score;
  }
}
export function projectState(state: ProducerState): RoutingRequest {
  validateState(state);
  const ds = state.detection_confidences, cs = state.ranked_candidates, top = cs[0];
  // Detection.confidence is Float; rounding must happen before Double accumulation.
  const mean = ds.length ? ds.reduce((sum, v) => sum + Math.max(0, Math.min(1, Math.fround(v))), 0) / ds.length : 0;
  const gap = cs.length >= 2 ? top!.confidence_score - cs[1]!.confidence_score : null;
  const margin = gap !== null ? Math.max(0, Math.min(1, 0.5 + Math.max(gap, 0))) : top ? 0.82 : 0;
  const values = [mean, top?.confidence_score ?? 0, top ? top.matched_required / Math.max(top.total_required, 1) : 0, margin];
  // RM-10's binary64 subtraction is below 0.06. No epsilon or decimal rounding.
  const hardFail = !top ? HARD_FAILS.no_candidate : top.missing_required_count > 2 ? HARD_FAILS.missing_required : gap !== null && gap < 0.06 ? HARD_FAILS.ambiguity : null;
  return { signals: SIGNAL_KEYS.map((key, i) => ({ key, rawScore: values[i]!, weight: SIGNAL_WEIGHTS[i]!, reason: SIGNAL_REASONS[i]! })), hardFailReasons: hardFail ? [hardFail] : [] };
}
export function parseStates(text: string): StateRow[] {
  const ids = new Set<string>();
  return text.split(/\r?\n/).filter(line => line.trim()).map((line, i) => {
    const row = exactObject(decodeStrict(line), ["case_id", "producer_state"], `state line ${i + 1}`);
    nonemptyString(row.case_id, "case_id");
    if (ids.has(row.case_id)) throw new Error(`Duplicate case_id: ${row.case_id}`);
    ids.add(row.case_id);
    validateState(row.producer_state);
    return { case_id: row.case_id, producer_state: row.producer_state };
  });
}
export interface ReplayEpisode { episode_id: string; state_id: string; action: "top_pick" | "non_top_pick" | "manual_pick"; proxy_reward: number; truth_reward: number; assessed_recipe_correct: boolean; assessed_quantity_correct: boolean }
export interface Replay { version: "reverse-meal-dev-v1"; states: Record<string, ProducerState>; episodes: ReplayEpisode[] }
export function parseReplay(text: string, evaluation: StateRow[]): Replay {
  const value = decodeStrict(text);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("replay: expected object");
  const r = value as Replay;
  if (r.version !== "reverse-meal-dev-v1" || !r.states || typeof r.states !== "object" || Array.isArray(r.states) || !Array.isArray(r.episodes) || r.episodes.length !== 12) throw new Error("replay: version/states/episode count mismatch");
  const evaluationRequests = new Set(evaluation.map(s => canonicalJson(projectState(s.producer_state))));
  for (const s of Object.values(r.states)) if (evaluationRequests.has(canonicalJson(projectState(s)))) throw new Error("replay overlaps evaluation request");
  const ids = new Set<string>(), usedStates = new Set<string>();
  const actionCounts = { top_pick: 0, non_top_pick: 0, manual_pick: 0 };
  const rewards = { top_pick: 0.96, non_top_pick: 0.78, manual_pick: 0.45 };
  for (const e of r.episodes) {
    nonemptyString(e.episode_id, "episode_id");
    if (ids.has(e.episode_id)) throw new Error("duplicate replay episode");
    ids.add(e.episode_id);
    if (!Object.hasOwn(r.states, e.state_id) || !Object.hasOwn(rewards, e.action)) throw new Error("replay: unknown state/action");
    usedStates.add(e.state_id);
    actionCounts[e.action]++;
    if (e.proxy_reward !== rewards[e.action] || typeof e.assessed_recipe_correct !== "boolean" || typeof e.assessed_quantity_correct !== "boolean" || e.truth_reward !== Number(e.assessed_recipe_correct && e.assessed_quantity_correct)) throw new Error("replay reward mismatch");
  }
  if (usedStates.size !== Object.keys(r.states).length || actionCounts.top_pick !== 7 || actionCounts.non_top_pick !== 2 || actionCounts.manual_pick !== 3) throw new Error("replay coverage/action counts mismatch");
  return r;
}
