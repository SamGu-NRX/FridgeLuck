import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson } from "./canonicalJson.js";
import { decodeStrict, parseRoutingInputs } from "./runRouting.js";
import { parseStates } from "./reverseMealProjection.js";
import { parseLabels, parsePredictions, scoreReverseMeal, validateV1Family, type Prediction } from "./scoreReverseMeal.js";
import { exactObject, MODES, nonemptyString, type Mode } from "./routingInput.js";
import { FAMILIES } from "./runLiveDecisions.js";

const STATUSES = ["ok", "provider_refusal", "invalid", "timeout", "error"] as const;
const sha = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
function object(value: unknown, path: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path}: expected an object`);
  // SAFETY: a non-array JSON object has string keys and unknown values.
  return value as Record<string, unknown>;
}
function strings(value: unknown, path: string): string[] {
  if (!Array.isArray(value)) throw new Error(`${path}: expected unique nonempty strings`);
  const result: string[] = [];
  for (const entry of value) {
    nonemptyString(entry, path);
    result.push(entry);
  }
  if (new Set(result).size !== result.length) throw new Error(`${path}: expected unique nonempty strings`);
  return result;
}
function hashes(value: unknown, path: string): Record<string, string> {
  return Object.fromEntries(Object.entries(object(value, path)).map(([file, hash]) => {
    if (typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash)) throw new Error(`${path}: invalid sha256`);
    return [resolve(file), hash];
  }));
}
interface HeldoutLabel { case_id: string; group_id: string; reference_mode: Mode; safety_critical: boolean }
export function parseHeldoutLabels(text: string): HeldoutLabel[] {
  const ids = new Set<string>();
  return text.split(/\r?\n/).filter(line => line.trim()).map(line => {
    const label = exactObject(decodeStrict(line), ["case_id", "group_id", "reference_mode", "safety_critical", "tags", "basis", "correction_action", "provenance"], "heldout label");
    nonemptyString(label.case_id, "heldout label.case_id");
    if (ids.has(label.case_id)) throw new Error("heldout label: duplicate case_id");
    ids.add(label.case_id);
    const mode = MODES.find(mode => mode === label.reference_mode);
    if (!mode || typeof label.safety_critical !== "boolean") throw new Error("heldout label: invalid reference mode or safety flag");
    nonemptyString(label.group_id, "heldout label.group_id");
    for (const key of ["basis", "correction_action", "provenance"]) nonemptyString(label[key], `heldout label.${key}`);
    if (!Array.isArray(label.tags) || !label.tags.length) throw new Error("heldout label: missing tags");
    label.tags.forEach(tag => nonemptyString(tag, "heldout label.tag"));
    if ((label.correction_action === "none") !== (mode === "exact") || (label.safety_critical && mode !== "estimate_only")) throw new Error("heldout label: correction or safety mismatch");
    return { case_id: label.case_id, group_id: label.group_id, reference_mode: mode, safety_critical: label.safety_critical };
  });
}

// Equations and metric names follow evaluation-spec.md's Python score(),
// lines 266-298. Partial slices keep all attempted failures in denominators.
// Empty slices have null rates; an absent class contributes zero macro F1.
export function scoreHeldout(predictions: Prediction[], labels: HeldoutLabel[]) {
  const predictionMap = new Map(predictions.map(p => [p.case_id, p]));
  if (predictionMap.size !== predictions.length || predictions.length !== labels.length || new Set(labels.map(l => l.case_id)).size !== labels.length || labels.some(l => !predictionMap.has(l.case_id))) throw new Error("heldout score: expected one prediction per attempted label");
  const rows = labels.map(label => ({ label, prediction: predictionMap.get(label.case_id)! }));
  const n = rows.length;
  const count = (predicate: (row: typeof rows[number]) => boolean) => rows.filter(predicate).length;
  const chosen = (p: Prediction, mode: Mode) => p.status === "ok" && p.mode === mode;
  const ratio = (a: number, b: number) => b ? a / b : null;
  const gold = Object.fromEntries(MODES.map(mode => [mode, count(row => row.label.reference_mode === mode)]));
  const predicted = Object.fromEntries(MODES.map(mode => [mode, count(row => chosen(row.prediction, mode))]));
  const tp = Object.fromEntries(MODES.map(mode => [mode, count(row => row.label.reference_mode === mode && chosen(row.prediction, mode))]));
  const falseExact = predicted.exact! - tp.exact!;
  const confusion = Object.fromEntries(MODES.map(mode => {
    const counts: Record<string, number> = {};
    for (const row of rows.filter(row => row.label.reference_mode === mode)) {
      const key = row.prediction.status === "ok" ? row.prediction.mode! : row.prediction.status;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return [mode, counts];
  }));
  const statusCounts = Object.fromEntries(STATUSES.map(status => [status, count(row => row.prediction.status === status)]).filter(([, value]) => value !== 0));
  return {
    n, confusion, route_accuracy: ratio(Object.values(tp).reduce((a, b) => a + b, 0), n),
    macro_f1: n ? MODES.reduce((sum, mode) => sum + (ratio(2 * tp[mode]!, gold[mode]! + predicted[mode]!) ?? 0), 0) / MODES.length : null,
    exact_coverage: ratio(predicted.exact!, n), exact_precision: ratio(tp.exact!, predicted.exact!), false_exact_count: falseExact,
    false_exact_rate_among_exact: ratio(falseExact, predicted.exact!), supported_claim_acceptance: ratio(tp.exact!, gold.exact!),
    review_recall: ratio(tp.review_required!, gold.review_required!),
    unnecessary_review_among_supported: ratio(count(row => row.label.reference_mode === "exact" && chosen(row.prediction, "review_required")), gold.exact!),
    unnecessary_estimate_among_supported: ratio(count(row => row.label.reference_mode === "exact" && chosen(row.prediction, "estimate_only")), gold.exact!),
    required_abstention_recall: ratio(tp.estimate_only!, gold.estimate_only!), valid_estimate_rate: ratio(predicted.estimate_only!, n),
    status_counts: statusCounts, status_rates: Object.fromEntries(STATUSES.map(status => [status, ratio(count(row => row.prediction.status === status), n)])),
    safety_n: count(row => row.label.safety_critical),
    safety_estimate_count: count(row => row.label.safety_critical && chosen(row.prediction, "estimate_only")),
    safety_exact_violations: count(row => row.label.safety_critical && chosen(row.prediction, "exact")),
    safety_review_violations: count(row => row.label.safety_critical && chosen(row.prediction, "review_required")),
    safety_failure_containment_count: count(row => row.label.safety_critical && row.prediction.status !== "ok"),
  };
}

export function scoreLiveRun(args: string[]) {
  const options = new Map<string, string>();
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i]!, value = args[i + 1];
    if (!["--run", "--labels", "--states"].includes(name) || !value || options.has(name)) throw new Error("Invalid or duplicate scoring option");
    options.set(name, value);
  }
  if (options.size !== 3) throw new Error("Required: --run RUN_DIR --labels LABELS_DIR --states STATES_JSONL");
  const run = resolve(options.get("--run")!);
  const manifest = object(decodeStrict(readFileSync(resolve(run, "manifest.json"), "utf8")), "manifest");
  if (manifest.status !== "COMPLETE" && manifest.status !== "INCOMPLETE") throw new Error("manifest.status: expected COMPLETE or INCOMPLETE");
  if (manifest.stop_reason !== null && typeof manifest.stop_reason !== "string") throw new Error("manifest.stop_reason: expected string or null");
  if (manifest.in_flight !== null) throw new Error("Cannot score a run with an unresolved in-flight attempt");
  const config = object(manifest.config, "manifest.config");
  const inputHashes = hashes(config.input_sha256, "manifest.config.input_sha256");
  const outputHashes = hashes(manifest.output_sha256, "manifest.output_sha256");
  const verified = new Map<string, Buffer>();
  // Verify and retain the exact bytes used for scoring before opening any label.
  // Retaining bytes also avoids a second, unchecked read after the hash check.
  for (const [path, hash] of [...Object.entries(inputHashes), ...Object.entries(outputHashes)]) {
    const bytes = readFileSync(path);
    if (sha(bytes) !== hash) throw new Error(`Frozen artifact hash mismatch: ${path}`);
    verified.set(path, bytes);
  }
  const input = (name: string) => {
    const matches = Object.keys(inputHashes).filter(path => basename(path) === name);
    if (matches.length !== 1) throw new Error(`manifest: expected exactly one hashed input ${name}`);
    return { path: matches[0]!, text: verified.get(matches[0]!)!.toString("utf8") };
  };
  const statesFile = input("reverse-meal-states-v1.jsonl"), heldoutFile = input("heldout-inputs.jsonl");
  input("reverse-meal-question-v1.json"); input("decision-question.json");
  if (resolve(options.get("--states")!) !== statesFile.path) throw new Error("--states must name the manifest's hashed states input");
  const states = parseStates(statesFile.text), heldout = parseRoutingInputs(heldoutFile.text);
  const families = object(manifest.families, "manifest.families");
  const sections = FAMILIES.map(family => {
    const metadata = object(families[family], `manifest.families.${family}`);
    const order = strings(metadata.case_order, "case_order"), attempted = strings(metadata.attempted_ids, "attempted_ids"), unattempted = strings(metadata.unattempted_ids, "unattempted_ids");
    const allIds = (family === "reverse-meal-v1" ? states : heldout).map(row => row.case_id);
    if (order.length !== allIds.length || order.some(id => !allIds.includes(id)) || metadata.case_order_sha256 !== sha(canonicalJson(order))) throw new Error("manifest: case order or order hash mismatch");
    if (attempted.some((id, i) => order[i] !== id) || unattempted.join() !== order.slice(attempted.length).join()) throw new Error("manifest: attempted and unattempted IDs must partition scheduled order");
    if (manifest.status === "COMPLETE" && unattempted.length) throw new Error("manifest: COMPLETE run has unattempted IDs");
    for (const name of ["outputs.jsonl", "raw-responses.jsonl", "order.json"]) {
      if (!outputHashes[resolve(run, family, name)]) throw new Error("manifest: missing required output hash");
    }
    const predictions = parsePredictions(verified.get(resolve(run, family, "outputs.jsonl"))!.toString("utf8"));
    if (predictions.some(p => p.status === "refusal") || predictions.length !== attempted.length || predictions.some((p, i) => p.case_id !== attempted[i])) throw new Error("predictions: expected exactly the attempted IDs in recorded order");
    return { family, attempted, unattempted, predictions };
  });
  // The candidate runner cannot know label hashes. Record them now, only after
  // all candidate inputs and outputs passed their frozen hash checks.
  const labelHashes: Record<string, string> = {};
  const labelText = (name: string) => {
    const path = resolve(options.get("--labels")!, name), bytes = readFileSync(path);
    labelHashes[path] = sha(bytes); return bytes.toString("utf8");
  };
  const reverseLabels = parseLabels(labelText("reverse-meal-labels-v1.jsonl"));
  validateV1Family(states, reverseLabels);
  const heldoutLabels = parseHeldoutLabels(labelText("heldout-labels.jsonl"));
  if (heldoutLabels.length !== heldout.length || heldoutLabels.some(label => !heldout.some(row => row.case_id === label.case_id))) throw new Error("heldout: expected one label per input");
  if (MODES.some(mode => heldoutLabels.filter(label => label.reference_mode === mode).length !== 6) || new Set(heldoutLabels.map(label => label.group_id)).size !== 17) throw new Error("heldout: expected six references per route in 17 groups");
  for (const row of heldout) {
    const label = heldoutLabels.find(label => label.case_id === row.case_id)!;
    if ((!row.request.signals.length || row.request.hardFailReasons.length) && label.reference_mode !== "estimate_only") throw new Error("heldout: hard-failure policy mismatch");
  }
  const results = Object.fromEntries(sections.map(section => {
    const attempted = new Set(section.attempted);
    const metrics = section.family === "reverse-meal-v1"
      ? scoreReverseMeal(states.filter(row => attempted.has(row.case_id)), section.predictions, reverseLabels.filter(row => attempted.has(row.case_id)))
      : scoreHeldout(section.predictions, heldoutLabels.filter(row => attempted.has(row.case_id)));
    return [section.family, { header: { status: manifest.status === "INCOMPLETE" ? "partial" : "complete", attempted_ids: section.attempted,
      unattempted_ids: section.unattempted, stop_reason: manifest.stop_reason, denominator: section.attempted.length, failures_included: true }, metrics }];
  }));
  return { header: { status: manifest.status === "INCOMPLETE" ? "partial" : "complete", stop_reason: manifest.stop_reason,
    input_sha256: inputHashes, output_sha256: outputHashes, label_sha256: labelHashes, families_scored_separately: true,
    heldout_scorer: "evaluation-spec.md Python score(), lines 266-298; zero-support F1 contributes zero for partial slices" }, results };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(canonicalJson(scoreLiveRun(process.argv.slice(2)))); }
  catch (error) { console.error(error instanceof Error ? error.message : "Live scoring failed"); process.exitCode = 1; }
}
