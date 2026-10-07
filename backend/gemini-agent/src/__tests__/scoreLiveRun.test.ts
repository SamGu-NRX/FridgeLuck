import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { canonicalJson } from "../evaluation/canonicalJson.js";
import { parseHeldoutLabels, scoreHeldout, scoreLiveRun } from "../evaluation/scoreLiveRun.js";
import { MODES } from "../evaluation/routingInput.js";
import { runLiveDecisions } from "../evaluation/runLiveDecisions.js";
import type { Prediction } from "../evaluation/scoreReverseMeal.js";

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const sha = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
const jsonl = (rows: unknown[]) => rows.map(row => JSON.stringify(row)).join("\n") + "\n";
function fixture(partial = false) {
  const dir = mkdtempSync(join(tmpdir(), "live-score-test-")); dirs.push(dir);
  const run = join(dir, "run"); mkdirSync(run);
  const states = Array.from({ length: 16 }, (_, i) => ({ case_id: `RM-${String(i + 1).padStart(2, "0")}`, producer_state: { detection_confidences: [0.9], ranked_candidates: [{ id: 1, confidence_score: 0.9, matched_required: 1, total_required: 1, missing_required_count: 0 }] } }));
  const heldout = Array.from({ length: 18 }, (_, i) => ({ case_id: `FLH-${String(i + 1).padStart(2, "0")}`, request: { signals: [{ key: "test", weight: 1, rawScore: 0.9, reason: "synthetic" }], hardFailReasons: [] } }));
  let outcome = 0;
  const reverseLabels = states.map(row => {
    const nonbinary = ["RM-01", "RM-02", "RM-12", "RM-15"].includes(row.case_id);
    const index = nonbinary ? 0 : outcome++;
    return { case_id: row.case_id, group_id: nonbinary ? `nonbinary-${row.case_id}` : `outcome-${index % 7}`, stratum: nonbinary ? "diagnostic" : "outcome", expected_hard_fail: null,
      original_proposal_correct: nonbinary ? null : index < 8, required_edit_fields: nonbinary ? null : index < 8 ? [] : ["recipe_id"] };
  });
  const heldoutLabels = heldout.map((row, i) => ({ case_id: row.case_id, group_id: `group-${i === 17 ? 16 : i}`, reference_mode: MODES[Math.floor(i / 6)]!, safety_critical: i >= 16,
    tags: ["synthetic"], basis: "synthetic rationale", correction_action: i < 6 ? "none" : "manual", provenance: "test" }));
  writeFileSync(join(dir, "reverse-meal-labels-v1.jsonl"), jsonl(reverseLabels));
  writeFileSync(join(dir, "heldout-labels.jsonl"), jsonl(heldoutLabels));
  const question = (name: string) => JSON.stringify({ name, type: "choice", instructions: "Choose using synthetic evidence", choices: MODES.map(value => ({ value, description: value })) });
  const inputFiles = { "reverse-meal-states-v1.jsonl": jsonl(states), "heldout-inputs.jsonl": jsonl(heldout), "reverse-meal-question-v1.json": question("fridgeluck_reverse_meal_route"), "decision-question.json": question("fridgeluck_route") };
  const inputHashes = Object.fromEntries(Object.entries(inputFiles).map(([name, text]) => { const path = join(dir, name); writeFileSync(path, text); return [path, sha(text)]; }));
  const outputHashes: Record<string, string> = {};
  const families = Object.fromEntries(["reverse-meal-v1", "heldout18"].map(family => {
    mkdirSync(join(run, family));
    const order = (family === "reverse-meal-v1" ? states : heldout).map(row => row.case_id);
    const attempted = partial ? order.slice(0, family === "reverse-meal-v1" ? 3 : 0) : order;
    const predictions = attempted.map((case_id, i) => ({ case_id, status: i === 1 ? "error" : "ok", mode: i === 1 ? null : "exact" }));
    for (const [name, text] of Object.entries({ "outputs.jsonl": attempted.length ? jsonl(predictions) : "", "raw-responses.jsonl": attempted.length ? jsonl(predictions) : "", "order.json": JSON.stringify({ case_order: order }) })) {
      const path = join(run, family, name); writeFileSync(path, text); outputHashes[path] = sha(text);
    }
    return [family, { case_order: order, case_order_sha256: sha(canonicalJson(order)), attempted_ids: attempted, unattempted_ids: order.slice(attempted.length) }];
  }));
  const manifest = { status: partial ? "INCOMPLETE" : "COMPLETE", stop_reason: partial ? "http_401" : null, in_flight: null, config: { input_sha256: inputHashes }, output_sha256: outputHashes, families };
  const manifestPath = join(run, "manifest.json"); writeFileSync(manifestPath, JSON.stringify(manifest));
  const args = ["--run", run, "--labels", dir, "--states", join(dir, "reverse-meal-states-v1.jsonl")];
  return { dir, run, args, manifest, manifestPath, heldoutLabels };
}
test("complete scoring verifies hashes and reports two separate sections with failure-inclusive denominators", () => {
  const f = fixture(); const result = scoreLiveRun(f.args);
  expect(result.header.status).toBe("complete"); expect(result.header.families_scored_separately).toBe(true);
  expect(Object.keys(result.results).sort()).toEqual(["heldout18", "reverse-meal-v1"]);
  expect(result.results["reverse-meal-v1"]!.header.denominator).toBe(16);
  expect(result.results.heldout18!.header.denominator).toBe(18);
  expect(Object.keys(result.header.label_sha256).length).toBe(2);
});
for (const target of ["input", "normalized", "raw", "order"]) test(`hash mismatch in ${target} refuses before labels are opened`, () => {
  const f = fixture();
  const path = target === "input" ? join(f.dir, "heldout-inputs.jsonl") : join(f.run, "reverse-meal-v1", target === "normalized" ? "outputs.jsonl" : target === "raw" ? "raw-responses.jsonl" : "order.json");
  writeFileSync(path, "tampered");
  const args = f.args.map(arg => arg === f.dir ? join(f.dir, "missing-labels") : arg);
  expect(() => scoreLiveRun(args)).toThrow("Frozen artifact hash mismatch");
});
test("INCOMPLETE scoring includes only attempted cases and preserves failed-call denominators", () => {
  const f = fixture(true); const result = scoreLiveRun(f.args);
  expect(result.header.status).toBe("partial"); expect(result.header.stop_reason).toBe("http_401");
  const reverse = result.results["reverse-meal-v1"]!;
  expect(reverse.header.denominator).toBe(3); expect(reverse.header.unattempted_ids.length).toBe(13); expect(reverse.header.failures_included).toBe(true);
  const heldout = result.results.heldout18!;
  expect(heldout.header.denominator).toBe(0); expect(heldout.header.unattempted_ids.length).toBe(18);
  // Narrow the union returned for the two separate scorer shapes.
  expect("conformance" in reverse.metrics && reverse.metrics.conformance.failures_by_status.error.denominator).toBe(3);
  expect("n" in heldout.metrics && heldout.metrics.n).toBe(0);
  expect("route_accuracy" in heldout.metrics && heldout.metrics.route_accuracy).toBeNull();
});
test("a hash-valid extra unattempted prediction is refused, not scored", () => {
  const f = fixture(true); const path = join(f.run, "heldout18", "outputs.jsonl");
  writeFileSync(path, jsonl([{ case_id: "FLH-01", status: "ok", mode: "exact" }]));
  f.manifest.output_sha256[path] = sha(readFileSync(path)); writeFileSync(f.manifestPath, JSON.stringify(f.manifest));
  expect(() => scoreLiveRun(f.args)).toThrow("exactly the attempted IDs");
});
test("missing required hash or unresolved in-flight attempt refuses before labels", () => {
  const f = fixture(true);
  delete f.manifest.output_sha256[join(f.run, "heldout18", "order.json")];
  writeFileSync(f.manifestPath, JSON.stringify(f.manifest)); expect(() => scoreLiveRun(f.args)).toThrow("missing required output hash");
  writeFileSync(f.manifestPath, JSON.stringify({ ...f.manifest, in_flight: { case_id: "RM-04" } }));
  expect(() => scoreLiveRun(f.args)).toThrow("unresolved in-flight");
});
for (const partial of [false, true]) test(`scoring accepts the real runner's ${partial ? "INCOMPLETE" : "COMPLETE"} manifest offline`, async () => {
  const f = fixture(); const out = join(f.dir, "generated-run"), keyFile = join(f.dir, "key.env");
  writeFileSync(keyFile, "OPENAI_API_KEY=sk-offline-integration-fixture\n", { mode: 0o600 });
  await runLiveDecisions(["--families", "reverse-meal-v1,heldout18", "--fixtures", f.dir, "--out", out, "--key-file", keyFile, "--spend-ceiling-usd", "1", "--confirm-live"], { fetch: async (_, init) => {
    if (partial) return Response.json({ error: "offline access denied" }, { status: 401 });
    const body = JSON.parse(String(init.body));
    return Response.json({ answers: [{ name: body.questions[0].name, type: "choice", choice: "exact" }] });
  } });
  const result = scoreLiveRun(f.args.map(arg => arg === f.run ? out : arg));
  expect(result.header.status).toBe(partial ? "partial" : "complete");
  expect(result.results["reverse-meal-v1"]!.header.denominator).toBe(partial ? 1 : 16);
  expect(result.results.heldout18!.header.denominator).toBe(partial ? 0 : 18);
});
test("heldout metric equations match the evaluation spec's Python scorer on all four reference checks", () => {
  const f = fixture(); const labels = parseHeldoutLabels(jsonl(f.heldoutLabels));
  const variants: Prediction[][] = [
    labels.map(label => ({ case_id: label.case_id, status: "ok", mode: label.reference_mode })),
    labels.map(label => ({ case_id: label.case_id, status: "ok", mode: "estimate_only" })),
    labels.map(label => ({ case_id: label.case_id, status: "provider_refusal", mode: null })),
    labels.map(label => ({ case_id: label.case_id, status: "ok", mode: "exact" })),
  ];
  // Verbatim score() from evaluation-spec.md lines 266-298, with globals supplied
  // from synthetic test data. This independent reference runs no candidate.
  const reference = spawnSync("python3", ["-B", "-c", `
import json,sys
from collections import Counter
payload=json.load(sys.stdin)
labels=payload['labels']
MODES=('exact','review_required','estimate_only')
STATUSES=('ok','provider_refusal','invalid','timeout','error')
def score(pred):
    n = len(labels)
    count = lambda test: sum(test(g, pred[g['case_id']]) for g in labels)
    chosen = lambda p, m: p['status'] == 'ok' and p['mode'] == m
    ratio = lambda a, b: a / b if b else None
    gold_n = Counter(g['reference_mode'] for g in labels)
    pred_n = {m: count(lambda g, p: chosen(p, m)) for m in MODES}
    tp = {m: count(lambda g, p: g['reference_mode'] == m and chosen(p, m)) for m in MODES}
    false_exact = pred_n['exact'] - tp['exact']
    safety_n = sum(g['safety_critical'] for g in labels)
    confusion = {m: dict(Counter((p['mode'] if p['status'] == 'ok' else p['status']) for g in labels if g['reference_mode'] == m for p in [pred[g['case_id']]])) for m in MODES}
    return {
        'n': n, 'confusion': confusion,
        'route_accuracy': sum(tp.values()) / n,
        'macro_f1': sum(2 * tp[m] / (gold_n[m] + pred_n[m]) for m in MODES) / len(MODES),
        'exact_coverage': pred_n['exact'] / n,
        'exact_precision': ratio(tp['exact'], pred_n['exact']),
        'false_exact_count': false_exact,
        'false_exact_rate_among_exact': ratio(false_exact, pred_n['exact']),
        'supported_claim_acceptance': ratio(tp['exact'], gold_n['exact']),
        'review_recall': ratio(tp['review_required'], gold_n['review_required']),
        'unnecessary_review_among_supported': ratio(count(lambda g, p: g['reference_mode'] == 'exact' and chosen(p, 'review_required')), gold_n['exact']),
        'unnecessary_estimate_among_supported': ratio(count(lambda g, p: g['reference_mode'] == 'exact' and chosen(p, 'estimate_only')), gold_n['exact']),
        'required_abstention_recall': ratio(tp['estimate_only'], gold_n['estimate_only']),
        'valid_estimate_rate': pred_n['estimate_only'] / n,
        'status_counts': dict(Counter(p['status'] for p in pred.values())),
        'status_rates': {s: sum(p['status'] == s for p in pred.values()) / n for s in STATUSES},
        'safety_n': safety_n,
        'safety_estimate_count': count(lambda g, p: g['safety_critical'] and chosen(p, 'estimate_only')),
        'safety_exact_violations': count(lambda g, p: g['safety_critical'] and chosen(p, 'exact')),
        'safety_review_violations': count(lambda g, p: g['safety_critical'] and chosen(p, 'review_required')),
        'safety_failure_containment_count': count(lambda g, p: g['safety_critical'] and p['status'] != 'ok')
    }
print(json.dumps([score({p['case_id']:p for p in variant}) for variant in payload['variants']]))
`], { encoding: "utf8", input: JSON.stringify({ labels, variants }) });
  expect(reference.status).toBe(0);
  const expected = JSON.parse(reference.stdout);
  variants.forEach((predictions, i) => expect(scoreHeldout(predictions, labels)).toEqual(expected[i]));
});
