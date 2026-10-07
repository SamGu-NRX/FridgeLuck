import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson } from "./canonicalJson.js";
import { decodeStrict } from "./runRouting.js";
import { parseStates, projectState, type StateRow } from "./reverseMealProjection.js";
import { exactObject, MODES, nonemptyString, type Mode } from "./routingInput.js";

export const POLICY_VERSION = "meal-photo-confirmation-v1";
const STATUSES = ["ok", "provider_refusal", "refusal", "invalid", "timeout", "error"] as const;
export type Status = typeof STATUSES[number];
const isStatus = (value: unknown): value is Status => STATUSES.some(status => status === value);
const isMode = (value: unknown): value is Mode => MODES.some(mode => mode === value);
export interface Prediction { case_id: string; status: Status; mode: Mode | null }
export type Action = "offer_accept" | "check_prompt" | "manual_pick";
export interface OutcomeLabel {
  case_id: string;
  group_id: string;
  stratum: string;
  expected_hard_fail: "no_candidate" | "missing_required" | "ambiguity" | null;
  original_proposal_correct: boolean | null;
  required_edit_fields: string[] | null;
}
// Verbatim qualifications from reverse-meal-spec-v1.md, retained in every score header.
export const CAVEATS = [
  "This specification gives the FridgeLuck product owner a bounded family and replay for the real iOS Bayesian consumer. It supplements, and does not alter, the original 18-case evaluation. Those cases remain exposed cross-language diagnostics. Neither family is an independent holdout or evidence of live product quality.",
  "A `producer_state` contains the post-deduplication detection confidences and the final ranked candidate list. Candidate IDs are synthetic handles. Candidate scores are injected post-ranking scores; they are not recomputed by this family from photographs, local recipe scoring or a cloud model. Preserve the supplied final ordering, including ties. This isolates the confidence consumer. The snapshots are not claimed to reproduce the upstream joint distribution or to be reachable through every earlier pipeline stage. In particular, high-score endpoint cases must not become claims about real candidate-search frequency.",
  "JSON spelling differences such as `1` and `1.0` are not evidence differences. Compare decoded objects, signal order and finite numeric values; record each implementation's serialized bytes separately. Float32 conversion is intentional, not a serialization tolerance. Cross-language projection and learner scores should use an absolute diagnostic tolerance of 1e-12, with mode and hard-failure strings exactly equal. That tolerance is a proposed numerical convention, not measured accuracy. Any mismatch near a route threshold needs investigation rather than rounding it away.",
  "`original_proposal_correct` describes the unchanged top recipe together with the proposed servings and portion. The declared reference recipe/quantity and `required_edit_fields` support field-specific reporting. A true outcome does not imply the model had enough evidence to justify exact mode. The family contains high-score wrong proposals and low-score correct proposals on purpose.",
  "The replay has 12 episodes: seven explicit top picks rewarded 0.96, two non-top picks rewarded 0.78, and three manual picks rewarded 0.45. It includes choosing an incorrect top dish, correcting a wrong top proposal through another selection, and manually reselecting a correct top dish. The state D1 is deliberately reused with different hidden truth in RMD-01/RMD-02. All development requests are distinct from evaluation requests after projection, but that does not make these synthetic families independent samples.",
  "The hypothesis is that selection-based rewards can reinforce wrong proposals or discount correct ones, changing later confidence dispositions in an unhelpful direction. The constructed replay makes that mechanism testable. It does not establish why Sam found the model poor.",
  "All worlds, outcomes and histories are invented, nonprivate and manually assigned by the evaluation author, an AI agent. These are construction assumptions, not human annotations or observed user behavior. They support offline engineering and hypothesis checks. Consequential quality or safety claims require independent outcomes and adjudication.",
  "An amount-only false-one-tap opportunity is evidence about missing input or the confirmation design, not proof that a recipe-identity classifier chose the wrong route. The truth-control reward deliberately targets the whole original proposal, so it also penalizes amount errors that the four signals cannot identify; it is not asserted to be the correct production training objective.",
  "The collision groups expose an information limit. RM-03/RM-04/RM-13 have byte-equivalent derived evidence and one correct versus two incorrect outcomes. RM-06/RM-16 have identical evidence and one correct versus one incorrect outcome. A fixed deterministic candidate in the same state cannot route members differently. Stochastic differences are not successful disambiguation. Report groupwise coverage/error trade-offs, never require perfect acceptance of correct members and rejection of wrong members simultaneously. Servings and portion are absent from this input boundary; a better classifier cannot recover those facts from nothing.",
  "The labels are available to engineers and already exposed in this phase. Derived cases cannot become a fresh independent holdout by changing IDs or wording. Keep the groups together in any later partition and collect new outcome evidence for consequential comparisons.",
  "This control changes both the meaning and scale of reward. The learner also sends one reward to every signal and blends it with agreement with its own score. Improvement under the truth control would warrant a separate matched-scale study, not isolate selection bias as the cause. No improvement would weaken the narrow prediction on these cases, not vindicate the policy generally. The fixed replay holds user actions constant, so it does not model the fact that a changed UI may alter selections, abandonment or which episodes receive feedback. A later consented study needs both actual actions and independently assessed correctness, including missing outcomes.",
  "The current implementation comparison is a system comparison under declared conditioning. A1 has the supplied development history; default Luna has its fixed prompt. Expose the development file to both implementation owners, document any development-time prompt choices, and freeze the question before outputs. Do not secretly add development truth to Luna's per-case request. A history-conditioned Luna variant would need a separate versioned arm. No claim of pure algorithm superiority follows from unequal training or model priors.",
  "Every path still requires an explicit user tap. There is no automatic logging or numerical adjustment by mode. The selected dish's amounts scale by the user-confirmed servings and portion. Failure containment earns no correct-choice or successful-deferral credit.",
  "They are opportunities for an incorrect one-tap confirmation, not measured wrong logs: users may still reject or edit them.",
  "These are possible extra checks/picks, not measured time, annoyance or user corrections. Failure-induced manual picks are reported separately as failure burden.",
  "Do not assume prompting causes the required edit or that all manual picks are correct.",
  "An offer-accept output for an absent candidate is invalid for the product action, but the raw choice must remain visible. Unknown portion truth does not enter the binary outcome denominator.",
  "Report policy invariants outside classifier quality: explicit confirmation always required; mode never changes the amounts derived from the user's confirmed dish, servings and portion. The owner's portion-logging tests cover implementation behavior; these synthetic labels are not a new app-runtime test.",
  "Do not estimate calibration, causal benefit, latency, spend or significance from this small constructed set. Do not compare the Bayesian scalar to Decisions confidence as if both meant the same probability. No new live evaluation is authorized by this specification."
];
export function actionFor(prediction: Prediction): Action {
  if (prediction.status !== "ok") return "manual_pick";
  return prediction.mode === "exact" ? "offer_accept" : prediction.mode === "review_required" ? "check_prompt" : "manual_pick";
}
export function parsePredictions(text: string): Prediction[] {
  const ids = new Set<string>();
  return text.split(/\r?\n/).filter(s => s.trim()).map(line => {
    const p = exactObject(decodeStrict(line), ["case_id", "status", "mode"], "prediction");
    nonemptyString(p.case_id, "prediction.case_id");
    if (ids.has(p.case_id)) throw new Error(`duplicate prediction: ${p.case_id}`);
    ids.add(p.case_id);
    if (!isStatus(p.status)) throw new Error("prediction: unknown status");
    if (p.status === "ok") {
      if (!isMode(p.mode)) throw new Error("prediction: ok requires a mode; failure requires null mode");
      return { case_id: p.case_id, status: p.status, mode: p.mode };
    }
    if (p.mode !== null) throw new Error("prediction: ok requires a mode; failure requires null mode");
    return { case_id: p.case_id, status: p.status, mode: null };
  });
}
export function parseLabels(text: string): OutcomeLabel[] {
  const ids = new Set<string>();
  return text.split(/\r?\n/).filter(s => s.trim()).map(line => {
    const v = decodeStrict(line);
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("label: expected object");
    const l = v as OutcomeLabel;
    nonemptyString(l.case_id, "label.case_id");
    nonemptyString(l.group_id, "label.group_id");
    nonemptyString(l.stratum, "label.stratum");
    if (ids.has(l.case_id)) throw new Error(`duplicate label: ${l.case_id}`);
    ids.add(l.case_id);
    if (![null, "no_candidate", "missing_required", "ambiguity"].includes(l.expected_hard_fail)) throw new Error("label: invalid expected_hard_fail");
    if (["RM-01", "RM-02", "RM-12", "RM-15"].includes(l.case_id) && l.stratum === "outcome") throw new Error(`label: ${l.case_id} is not a binary outcome case`);
    if (l.stratum === "outcome") {
      if (!Array.isArray(l.required_edit_fields) || new Set(l.required_edit_fields).size !== l.required_edit_fields.length || l.required_edit_fields.some(f => !["recipe_id", "servings", "portion_multiplier"].includes(f))) throw new Error("label: invalid required_edit_fields");
      if (typeof l.original_proposal_correct !== "boolean" || l.original_proposal_correct !== (l.required_edit_fields.length === 0)) throw new Error("label: inconsistent outcome/edit fields");
      return l;
    }
    if (l.original_proposal_correct !== null) throw new Error("label: non-outcome must not have binary truth");
    // The spec defines required edits only for binary outcomes. Other rows have no known edit set.
    return { ...l, required_edit_fields: null };
  });
}
const rate = (numerator: number, denominator: number) => ({ numerator, denominator, rate: denominator ? numerator / denominator : null });
export interface ParityComparison { case_id: string; swift_candidate: string; swift_mode: Mode; ts_mode: Mode; swift_score: number; ts_score: number }
export function parseParity(text: string, states: StateRow[]): ParityComparison[] {
  const value = decodeStrict(text) as { comparisons?: unknown };
  if (!value || !Array.isArray(value.comparisons)) throw new Error("cross-check: expected comparisons array");
  const comparisons = value.comparisons as ParityComparison[];
  const seen = new Set<string>(), ids = new Set(states.map(s => s.case_id));
  for (const c of comparisons) {
    if (!c || !ids.has(c.case_id) || typeof c.swift_candidate !== "string" || !c.swift_candidate.trim() || !MODES.includes(c.swift_mode) || !MODES.includes(c.ts_mode) || !Number.isFinite(c.swift_score) || !Number.isFinite(c.ts_score) || c.swift_score < 0 || c.swift_score > 1 || c.ts_score < 0 || c.ts_score > 1) throw new Error("cross-check: invalid comparison");
    const key = `${c.swift_candidate}/${c.case_id}`;
    if (seen.has(key)) throw new Error(`cross-check: duplicate comparison ${key}`);
    seen.add(key);
  }
  for (const arm of new Set(comparisons.map(c => c.swift_candidate))) if (comparisons.filter(c => c.swift_candidate === arm).length !== states.length) throw new Error(`cross-check: incomplete arm ${arm}`);
  if (!comparisons.length) throw new Error("cross-check: no comparisons");
  return comparisons;
}
export function scoreReverseMeal(states: StateRow[], predictions: Prediction[], labels: OutcomeLabel[], parity?: ParityComparison[]) {
  const join = <T extends { case_id: string }>(rows: T[], name: string) => {
    const map = new Map(rows.map(r => [r.case_id, r]));
    if (map.size !== rows.length || rows.length !== states.length || states.some(s => !map.has(s.case_id))) throw new Error(`${name}: expected exactly one row per attempted state`);
    return map;
  };
  if (new Set(states.map(s => s.case_id)).size !== states.length) throw new Error("duplicate state IDs");
  const P = join(predictions, "predictions"), L = join(labels, "labels");
  const rows = states.map(state => {
    const raw = P.get(state.case_id)!, label = L.get(state.case_id)!, request = projectState(state.producer_state);
    if (label.stratum === "outcome" && !state.producer_state.ranked_candidates.length) throw new Error(`outcome without candidate: ${state.case_id}`);
    return { state, raw, label, request, action: actionFor(raw), guard: state.case_id === "RM-12", hasCandidate: state.producer_state.ranked_candidates.length > 0 };
  });
  type Row = typeof rows[number];
  const count = (slice: Row[], predicate: (row: Row) => boolean) => slice.filter(predicate).length;
  const valid = (row: Row) => row.raw.status === "ok";
  const failures = (slice: Row[]) => Object.fromEntries(["provider_refusal", "refusal", "invalid", "timeout", "error"].map(status => [status, rate(count(slice, r => r.raw.status === status), slice.length)]));
  const modes = (slice: Row[]) => ({ ...Object.fromEntries(MODES.map(mode => [mode, rate(count(slice, r => valid(r) && r.raw.mode === mode), slice.length)])), failures: failures(slice) });
  const sliceCounts = (slice: Row[]) => ({ attempts: slice.length, valid_modes: rate(count(slice, valid), slice.length), raw_modes: modes(slice), actions: Object.fromEntries((["offer_accept", "check_prompt", "manual_pick"] as Action[]).map(action => [action, rate(count(slice, r => valid(r) && r.action === action), slice.length)])), failure_induced_manual_pick: rate(count(slice, r => !valid(r)), slice.length) });
  const conformance = (slice: Row[]) => {
    const hardFails = slice.filter(r => r.request.hardFailReasons.length);
    return { attempts: slice.length, valid_mode_rate: rate(count(slice, valid), slice.length), failures_by_status: failures(slice), raw_modes: modes(slice), hard_failure_attempts: hardFails.length,
      hard_failure_mode_violations: rate(count(hardFails, r => valid(r) && r.raw.mode !== "estimate_only"), hardFails.length),
      hard_failure_violations_among_valid: rate(count(hardFails, r => valid(r) && r.raw.mode !== "estimate_only"), count(hardFails, valid)),
      source_annotation_mismatches: slice.filter(r => (r.label.expected_hard_fail === null ? [] : [{ no_candidate: "No confident recipe candidate.", missing_required: "Too many required ingredients are missing.", ambiguity: "Top recipe candidates are highly ambiguous." }[r.label.expected_hard_fail]]).join() !== r.request.hardFailReasons.join()).map(r => r.raw.case_id) };
  };
  const known = rows.filter(r => !r.guard && r.label.stratum === "outcome");
  const correct = known.filter(r => r.label.original_proposal_correct === true), incorrect = known.filter(r => r.label.original_proposal_correct === false);
  const offers = known.filter(r => valid(r) && r.action === "offer_accept" && r.hasCandidate);
  const falseOffers = offers.filter(r => !r.label.original_proposal_correct);
  const groupIds = [...new Set(known.map(r => r.label.group_id))].sort();
  const groups = groupIds.map(group_id => {
    const members = known.filter(r => r.label.group_id === group_id);
    return { group_id, case_ids: members.map(r => r.raw.case_id), correct: sliceCounts(members.filter(r => r.label.original_proposal_correct)), incorrect: sliceCounts(members.filter(r => !r.label.original_proposal_correct)) };
  });
  const evidence = new Map<string, Row[]>();
  for (const r of known) { const key = canonicalJson(r.request); evidence.set(key, [...(evidence.get(key) ?? []), r]); }
  const collisions = [...evidence.values()].filter(group => group.length > 1).map(group => ({ case_ids: group.map(r => r.raw.case_id), group_ids: [...new Set(group.map(r => r.label.group_id))],
    dispositions_identical: new Set(group.map(r => `${r.raw.status}/${r.raw.mode}`)).size === 1,
    correct: sliceCounts(group.filter(r => r.label.original_proposal_correct)), incorrect: sliceCounts(group.filter(r => !r.label.original_proposal_correct)),
    false_one_tap_rate: rate(count(group, r => valid(r) && r.action === "offer_accept" && !r.label.original_proposal_correct), count(group, r => valid(r) && r.action === "offer_accept")) }));
  const special = (ids: string[]) => rows.filter(r => ids.includes(r.raw.case_id)).map(r => ({ case_id: r.raw.case_id, raw: r.raw, action: r.action, contained_failure: !valid(r), has_top_candidate: r.hasCandidate, offer_accept_preconditions_valid: r.action !== "offer_accept" || r.hasCandidate, hard_fail_reasons: r.request.hardFailReasons, quality_aggregation: false }));
  return {
    header: { policy_version: POLICY_VERSION, caveats: CAVEATS, grouping: "Rows are diagnostic variants, not independent observations. No pooled group utility or significance is computed.", scoring_inputs: "Labels join after candidate outputs are locked; labels never enter candidate requests." },
    conformance: conformance(rows), guard_only_conformance: conformance(rows.filter(r => r.guard)), non_guard_conformance: conformance(rows.filter(r => !r.guard)),
    known_outcome: { attempts: known.length, scenario_groups: groupIds.length, correct_proposals: correct.length, incorrect_proposals: incorrect.length,
      raw_modes: modes(known), offer_accept_correct: rate(count(offers, r => r.label.original_proposal_correct === true), correct.length),
      offer_accept_incorrect: rate(falseOffers.length, incorrect.length), false_one_tap_rate_among_valid_offers: rate(falseOffers.length, offers.length),
      offer_accept_coverage_over_all_attempts: rate(offers.length, known.length),
      false_one_tap_fields: Object.fromEntries(["recipe_id", "servings", "portion_multiplier"].map(field => [field, { among_false_offers: rate(count(falseOffers, r => r.label.required_edit_fields?.includes(field) ?? false), falseOffers.length), over_known_attempts: rate(count(falseOffers, r => r.label.required_edit_fields?.includes(field) ?? false), known.length) }])),
      friction_on_correct: sliceCounts(correct), incorrect_dispositions: sliceCounts(incorrect), group_tradeoffs: groups, evidence_collision_tradeoffs: collisions },
    absence_handling: special(["RM-01", "RM-02"]), evidence_required: special(["RM-15"]), defensive_guard: special(["RM-12"]),
    other_non_binary: rows.filter(r => !r.guard && r.label.stratum !== "outcome").map(r => ({ case_id: r.raw.case_id, stratum: r.label.stratum, raw: r.raw, action: r.action })),
    projected_actions: rows.map(r => ({ case_id: r.raw.case_id, policy_version: POLICY_VERSION, action: r.action, failure_containment: !valid(r), product_action_valid: r.action !== "offer_accept" || r.hasCandidate })),
    policy_invariants: { explicit_confirmation_always_required: true, mode_changes_confirmed_amounts: false, evidence: "Declared meal-photo-confirmation-v1 policy, not a new app-runtime test." },
    swift_typescript_agreement: parity ? {
      status: "supplied", tolerance: 1e-12, candidates: [...new Set(parity.map(c => c.swift_candidate))].sort().map(candidate => {
        const comparisons = parity.filter(c => c.swift_candidate === candidate);
        const agreement = (slice: ParityComparison[]) => ({ comparisons: slice.length, mode_agreement: rate(slice.filter(c => c.swift_mode === c.ts_mode).length, slice.length), score_agreement: rate(slice.filter(c => Math.abs(c.swift_score - c.ts_score) <= 1e-12).length, slice.length), maximum_absolute_score_difference: slice.length ? Math.max(...slice.map(c => Math.abs(c.swift_score - c.ts_score))) : null });
        return { candidate, all_attempts: agreement(comparisons), guard_only: agreement(comparisons.filter(c => c.case_id === "RM-12")), non_guard: agreement(comparisons.filter(c => c.case_id !== "RM-12")) };
      })
    } : { status: "not_supplied", reason: "Raw normalized outputs contain no scalar scores. Supply --cross-check locked/ts-cross-check.json; do not infer score agreement from modes." }
  };
}
export function validateV1Family(states: StateRow[], labels: OutcomeLabel[]) {
  const ids = new Set(Array.from({ length: 16 }, (_, i) => `RM-${String(i + 1).padStart(2, "0")}`));
  if (states.length !== 16 || new Set(states.map(s => s.case_id)).size !== 16 || states.some(s => !ids.has(s.case_id))) throw new Error("reverse-meal-v1: expected exactly RM-01 through RM-16");
  if (labels.length !== 16 || new Set(labels.map(l => l.case_id)).size !== 16 || labels.some(l => !ids.has(l.case_id))) throw new Error("reverse-meal-v1: expected one label per state");
  const outcomes = labels.filter(l => l.stratum === "outcome");
  if (outcomes.length !== 12 || outcomes.filter(l => l.original_proposal_correct === true).length !== 8 || outcomes.filter(l => l.original_proposal_correct === false).length !== 4 || new Set(outcomes.map(l => l.group_id)).size !== 7 || new Set(labels.map(l => l.group_id)).size !== 11) throw new Error("reverse-meal-v1: expected 12 known outcomes in 7 groups, 8 correct/4 incorrect, and 11 total groups");
}
export function runScorer(args: string[], readBytes: (path: string) => Buffer = readFileSync) {
  let statesPath: string | undefined, labelsPath: string | undefined, crossCheckPath: string | undefined, manifestPath: string | undefined;
  let synthetic = false;
  const outputs: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (key === "--unverified-synthetic" && !synthetic) { synthetic = true; continue; }
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(`missing value for ${key}`);
    if (key === "--states" && !statesPath) statesPath = value;
    else if (key === "--labels" && !labelsPath) labelsPath = value;
    else if (key === "--outputs") outputs.push(value);
    else if (key === "--cross-check" && !crossCheckPath) crossCheckPath = value;
    else if (key === "--manifest" && !manifestPath) manifestPath = value;
    else throw new Error(`unknown/duplicate option: ${key}`);
  }
  if (!statesPath || !labelsPath || !outputs.length) throw new Error("required: --states STATES --outputs NORMALIZED_JSONL [--outputs ...] --labels LABELS [--cross-check PARITY_JSON] --manifest MANIFEST");
  if (!manifestPath && !synthetic) throw new Error("required: --manifest PATH, or --unverified-synthetic for authored test data only");
  let manifest: Record<string, unknown> | undefined;
  if (!synthetic) {
    const value = decodeStrict(readBytes(manifestPath!).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("manifest: expected object");
    manifest = value as Record<string, unknown>;
  }
  const readVerified = (path: string, section: "input_sha256" | "output_sha256") => {
    const bytes = readBytes(path);
    if (manifest) {
      const hashes = manifest[section];
      if (!hashes || typeof hashes !== "object" || Array.isArray(hashes)) throw new Error(`manifest: missing ${section}`);
      // Locked manifests contain absolute paths from the original checkout. A unique
      // filename also identifies the same artifact after copying the checkout elsewhere.
      const matches = Object.entries(hashes).filter(([key]) => basename(key) === basename(path));
      if (matches.length !== 1) throw new Error(`manifest: expected exactly one ${section} entry for ${path}`);
      const expected = matches[0]![1];
      if (typeof expected !== "string" || !/^[a-f0-9]{64}$/.test(expected)) throw new Error(`manifest: invalid sha256 for ${path}`);
      const actual = createHash("sha256").update(bytes).digest("hex");
      if (actual !== expected) throw new Error(`manifest: sha256 mismatch for ${path}`);
    }
    return bytes.toString("utf8");
  };
  // Retain the verified bytes; never reopen artifacts after opening labels.
  const statesText = readVerified(statesPath, "input_sha256");
  const predictionTexts = outputs.map(path => readVerified(path, "output_sha256"));
  const parityText = crossCheckPath ? readVerified(crossCheckPath, "output_sha256") : undefined;
  const states = parseStates(statesText);
  const parity = parityText === undefined ? undefined : parseParity(parityText, states);
  const predictions = predictionTexts.map(parsePredictions);
  const labels = parseLabels(readBytes(labelsPath).toString("utf8"));
  validateV1Family(states, labels);
  const results = outputs.map((path, i) => ({ outputs_path: path, ...scoreReverseMeal(states, predictions[i]!, labels, parity) }));
  const scored = { header: { caveats: CAVEATS, policy_version: POLICY_VERSION, ...(synthetic ? { verification: "synthetic, unverified" } : {}) }, results };
  console.log(canonicalJson(scored));
  return scored;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runScorer(process.argv.slice(2)); }
  catch (e) { console.error(e instanceof Error ? e.message : e); process.exitCode = 1; }
}
