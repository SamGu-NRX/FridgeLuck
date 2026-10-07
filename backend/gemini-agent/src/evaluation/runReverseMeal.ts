import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import { canonicalJson } from "./canonicalJson.js";
import { DEFAULT_FIXTURES, readNamedFixture } from "./fixtureFiles.js";
import { decodeStrict } from "./runRouting.js";
import { parseStates, parseReplay, projectState, type StateRow, type Replay } from "./reverseMealProjection.js";
import { buildReverseMealDecisionsRequest, validateReverseMealQuestion } from "./reverseMealDecisions.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { actionFor, POLICY_VERSION, type Prediction } from "./scoreReverseMeal.js";

export const ARMS = ["ios-A0", "ios-A1-proxy", "ios-A1-truth-control"] as const;
export type Arm = typeof ARMS[number];
const ROOT = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../../..");
const LOCKED_OUTPUT = resolve(ROOT, "backend/gemini-agent/evaluation-output/reverse-meal-v1");
const sha = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
interface SwiftResult {
  case_id: string;
  assessment: { mode: Prediction["mode"]; overallScore: number; signals: Array<{ key: string; trustMean: number; trustUncertainty: number }> };
  trust_state: Array<{ signal_key: string; alpha: number; beta: number }>;
  events: unknown[];
  db_assertions: { after_event_rows: number; after_trust_rows: number; events_per_key: number; blended_reward_assertions: number; second_instance_persistence: boolean };
}
interface Projection { case_id?: string; state_id?: string; request: unknown; serialized_request: string }
export interface SwiftDocument {
  serializer: string;
  candidates: Array<{ candidate: Arm; results: SwiftResult[] }>;
  projections: Projection[];
  replay_projections: Projection[];
  checks: Record<string, unknown>;
}
export function assessTS(row: StateRow, replay: Replay, arm: Arm) {
  const service = new ConfidenceService();
  if (arm !== "ios-A0") for (const episode of replay.episodes) {
    const request = projectState(replay.states[episode.state_id]!);
    const assessment = service.assess(request);
    service.recordOutcome({ assessment, outcomeReward: arm === "ios-A1-proxy" ? episode.proxy_reward : episode.truth_reward, contextKey: `${replay.version}/${episode.episode_id}` });
  }
  return service.assess(projectState(row.producer_state));
}
export function crossCheck(rows: StateRow[], replay: Replay, swift: SwiftDocument) {
  const mismatches: Array<Record<string, unknown>> = [];
  const comparisons: Array<Record<string, unknown>> = [];
  const projectionChecks: Array<Record<string, unknown>> = [];
  const checkProjection = (id: string, state: StateRow["producer_state"], projections: Projection[], field: "case_id" | "state_id") => {
    const matches = projections.filter(p => p[field] === id);
    const ts = projectState(state), serialized = canonicalJson(ts);
    const p = matches[0];
    const decodedIdentical = matches.length === 1 && isDeepStrictEqual(ts, p?.request) && isDeepStrictEqual(ts, decodeStrict(p!.serialized_request));
    projectionChecks.push({ id, decoded_identical: decodedIdentical, serialized_bytes_identical: p?.serialized_request === serialized, typescript_serialized_request: serialized, swift_serialized_request: p?.serialized_request ?? null });
    if (!decodedIdentical) mismatches.push({ kind: "projection", id });
  };
  if (swift.projections.length !== rows.length || swift.replay_projections.length !== Object.keys(replay.states).length) throw new Error("Swift projection cardinality mismatch");
  for (const r of rows) checkProjection(r.case_id, r.producer_state, swift.projections, "case_id");
  for (const [id, state] of Object.entries(replay.states)) checkProjection(id, state, swift.replay_projections, "state_id");
  if (swift.candidates.length !== 3 || new Set(swift.candidates.map(c => c.candidate)).size !== 3) throw new Error("Swift arm cardinality mismatch");
  for (const arm of ARMS) {
    const candidate = swift.candidates.find(c => c.candidate === arm);
    if (!candidate || candidate.results.length !== rows.length || new Set(candidate.results.map(r => r.case_id)).size !== rows.length) throw new Error(`Swift results cardinality mismatch: ${arm}`);
    for (const row of rows) {
      const ios = candidate.results.find(r => r.case_id === row.case_id);
      if (!ios) throw new Error(`missing Swift result: ${arm}/${row.case_id}`);
      const ts = assessTS(row, replay, arm);
      const scoreDifference = Math.abs(ts.overallScore - ios.assessment.overallScore);
      const modesIdentical = ts.mode === ios.assessment.mode;
      const scoresAgree = Number.isFinite(ios.assessment.overallScore) && scoreDifference <= 1e-12;
      const stateAgreement = ts.signals.every(s => {
        const saved = ios.trust_state.find(t => t.signal_key === s.key);
        if (arm === "ios-A0") return ios.trust_state.length === 0;
        if (!saved) return false;
        const mean = saved.alpha / (saved.alpha + saved.beta);
        return Math.abs(mean - s.trustMean) <= 1e-12 && Math.abs(Math.sqrt(mean * (1 - mean) / (saved.alpha + saved.beta + 1)) - s.trustUncertainty) <= 1e-12;
      });
      const counts = ios.db_assertions;
      const expectedEvents = arm === "ios-A0" ? 0 : 48;
      if (ios.events.length !== expectedEvents || counts.after_event_rows !== expectedEvents || counts.after_trust_rows !== (arm === "ios-A0" ? 0 : 4) || counts.events_per_key !== (arm === "ios-A0" ? 0 : 12) || counts.blended_reward_assertions !== expectedEvents || !counts.second_instance_persistence) throw new Error(`Swift DB assertion evidence mismatch: ${arm}/${row.case_id}`);
      const hardFailViolation = projectState(row.producer_state).hardFailReasons.length > 0 && (ts.mode !== "estimate_only" || ios.assessment.mode !== "estimate_only");
      comparisons.push({ candidate: `ts-${arm.slice(4)}`, swift_candidate: arm, case_id: row.case_id, ts_mode: ts.mode, swift_mode: ios.assessment.mode, ts_score: ts.overallScore, swift_score: ios.assessment.overallScore, absolute_score_difference: scoreDifference, modes_identical: modesIdentical, scores_agree: scoresAgree, trust_readback_agrees: stateAgreement, hard_failure_violation: hardFailViolation });
      if (!modesIdentical || !scoresAgree || !stateAgreement || hardFailViolation) mismatches.push({ kind: "learner", candidate: arm, case_id: row.case_id, modesIdentical, scoreDifference, stateAgreement, hardFailViolation });
    }
  }
  return { tolerance: 1e-12, all_agree: mismatches.length === 0, comparison_count: comparisons.length, projection_count: projectionChecks.length, max_absolute_score_difference: Math.max(...comparisons.map(c => c.absolute_score_difference as number)), projection_checks: projectionChecks, comparisons, mismatches };
}
export function assertLockAvailable(directory: string) {
  if (resolve(directory) === LOCKED_OUTPUT || existsSync(directory)) throw new Error(`Refusing to overwrite existing or committed output directory: ${directory}`);
}
function git(args: string[]) {
  const result = spawnSync("git", args, { cwd: ROOT, encoding: "utf8" });
  if (result.status !== 0) throw new Error(`git metadata failed: ${args.join(" ")}`);
  return result.stdout;
}
export const SPEC_POLICY_SHA256 = "62ebfa4cacb706046c29bec4690db57ee493692821838d26bb3028c688eed2aa";
export const SPEC_POLICY_REFERENCE_COMMIT = "e18dafffd006b496975ba0d810d137b91ac7836d";
export function auditPolicySource(reference: string, current: string) {
  if (sha(reference) !== SPEC_POLICY_SHA256) throw new Error("Policy reference does not match the spec's frozen hash");
  // This frozen policy has no multiline strings or block comments. Accept only changes
  // to whole-line comments or blank lines; every executable source line must match.
  const executable = (source: string) => source.split(/\r?\n/).filter(line => line.trim() && !line.trimStart().startsWith("//")).join("\n");
  if (executable(reference) !== executable(current)) throw new Error("Executable policy source changed: lead must freeze a new policy version before locking");
  return { reference_commit: SPEC_POLICY_REFERENCE_COMMIT, reference_sha256: sha(reference), current_sha256: sha(current), source_bytes_identical: reference === current, executable_lines_identical: true, differences_limited_to_whole_line_comments_or_blank_lines: true };
}
export const COMPILE_ADMISSION = "lr-lease heavy, lockf heavy.lock, 8 GiB floor on df -k /";
interface BuildRecord {
  sources: Record<string, string>;
  binary_and_grdb: Record<string, string>;
  swift_version: string;
  compile_admission: string;
  build_script_sha256: string;
}
export function validateBuildRecord(value: unknown, recordPath: string, readBytes: (path: string) => Buffer = readFileSync): BuildRecord {
  const exactEntries = (value: unknown, expected: string[], name: string) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name}: expected object`);
    const entries = value as Record<string, unknown>;
    for (const key of expected) if (!Object.hasOwn(entries, key)) throw new Error(`${name}: missing entry ${key}`);
    for (const key of Object.keys(entries)) if (!expected.includes(key)) throw new Error(`${name}: extra entry ${key}`);
    return entries;
  };
  const record = exactEntries(value, ["sources", "binary_and_grdb", "swift_version", "compile_admission", "build_script_sha256"], "build record");
  const sources = ["Platform/Persistence/Services/ConfidenceLearningService.swift", "Platform/Persistence/Database/Migrations.swift", "Tools/reverse-meal-eval/main.swift"].map(path => resolve(ROOT, "apps/ios", path));
  const binaries = [resolve(dirname(resolve(recordPath)), "reverse-meal-runner"), "/tmp/fl-tc/grdb/libGRDB.dylib", "/tmp/fl-tc/grdb/GRDB.swiftmodule"];
  const verifyHash = (expected: unknown, path: string, name: string) => {
    if (typeof expected !== "string" || !/^[0-9a-f]{64}$/.test(expected)) throw new Error(`${name}: non-empty sha256 required for ${path}`);
    if (sha(readBytes(path)) !== expected) throw new Error(`${name}: sha256 mismatch for ${path}`);
  };
  for (const [name, paths] of [["sources", sources], ["binary_and_grdb", binaries]] as const) {
    const hashes = exactEntries(record[name], paths, name);
    for (const path of paths) verifyHash(hashes[path], path, name);
  }
  if (record.compile_admission !== COMPILE_ADMISSION) throw new Error("build record: compile_admission must attest lr-lease heavy, lockf heavy.lock, and the 8 GiB floor");
  verifyHash(record.build_script_sha256, resolve(ROOT, "apps/ios/Tools/reverse-meal-eval/run.sh"), "build_script_sha256");
  if (typeof record.swift_version !== "string" || !record.swift_version.trim()) throw new Error("build record: swift_version must be non-empty");
  return record as unknown as BuildRecord;
}
export function runReverseMeal(args: string[]) {
  const options = new Map<string, string>();
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]!, value = args[i + 1];
    if (!["--fixtures", "--swift-first", "--swift-second", "--build-record", "--out"].includes(key) || !value || options.has(key)) throw new Error(`Invalid option: ${key}`);
    options.set(key, value);
  }
  for (const key of ["--out", "--swift-first", "--swift-second", "--build-record"]) if (!options.has(key)) throw new Error(`required: ${key}`);
  if (!options.has("--fixtures")) options.set("--fixtures", DEFAULT_FIXTURES);
  const OUTPUT = resolve(options.get("--out")!);
  assertLockAvailable(OUTPUT);
  const policyPath = "apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift";
  const policySource = readFileSync(resolve(ROOT, policyPath), "utf8");
  const policyReference = readFileSync(resolve(DEFAULT_FIXTURES, "MealPhotoConfirmationPolicy.frozen.swift"), "utf8");
  const policyAudit = auditPolicySource(policyReference, policySource);
  const policyHash = policyAudit.current_sha256;
  const inputHashes: Record<string, string> = {};
  const readFixture = (name: Parameters<typeof readNamedFixture>[1]) => {
    const { path, bytes } = readNamedFixture(options.get("--fixtures")!, name);
    inputHashes[path] = sha(bytes);
    return bytes.toString("utf8");
  };
  const statesText = readFixture("reverse-meal-states-v1.jsonl"), replayText = readFixture("reverse-meal-replay-v1.json"), questionText = readFixture("reverse-meal-question-v1.json");
  for (const [name, expected] of Object.entries({ "reverse-meal-states-v1.jsonl": "75a76b70bb53fb4dfa1feb14e8804cb907dc9c1dde7c64bca2259990f25f60d1", "reverse-meal-replay-v1.json": "0012497ee2a001a03387bfdd07241b5f026ea01f28b66f269004259b0f8e2786", "reverse-meal-question-v1.json": "f0720952307e61f904482a19c1b65424fc6e58378f11955c26c79997c0960807" })) {
    if (inputHashes[resolve(options.get("--fixtures")!, name)] !== expected) throw new Error(`Frozen input hash mismatch: ${name}`);
  }
  const rows = parseStates(statesText), replay = parseReplay(replayText, rows), question = decodeStrict(questionText);
  if (rows.length !== 16 || rows.some((r, i) => r.case_id !== `RM-${String(i + 1).padStart(2, "0")}`)) throw new Error("expected declared 16-case family ordering");
  validateReverseMealQuestion(question);
  const first = readFileSync(options.get("--swift-first")!), second = readFileSync(options.get("--swift-second")!);
  if (!first.equals(second)) throw new Error("Swift complete runs are not byte-identical");
  inputHashes[resolve(options.get("--swift-first")!)] = sha(first);
  inputHashes[resolve(options.get("--swift-second")!)] = sha(second);
  const recordPath = resolve(options.get("--build-record")!), recordBytes = readFileSync(recordPath);
  inputHashes[recordPath] = sha(recordBytes);
  const build = validateBuildRecord(decodeStrict(recordBytes.toString("utf8")), recordPath);
  const admissionRecord = { completed_build_admission: build.compile_admission, build_script_sha256: build.build_script_sha256 };
  const swift = decodeStrict(first.toString("utf8")) as SwiftDocument;
  if (swift.checks.case_runs !== 192 || swift.checks.warm_case_runs !== 128 || swift.checks.warm_blended_reward_assertions !== 6144 || swift.checks.fresh_repeat_forward_reverse_seeded_shuffle !== true || swift.checks.suppressed_write_failure_detected !== true) throw new Error("Swift acceptance checks missing");
  const parity = crossCheck(rows, replay, swift);
  const files = new Map<string, string>();
  const jsonl = (values: unknown[]) => values.map(canonicalJson).join("\n") + "\n";
  const metadata = { policy_version: POLICY_VERSION, policy_source_sha256: policyHash, spec_policy_source_sha256: SPEC_POLICY_SHA256, policy_source_matches_spec_hash: policyHash === SPEC_POLICY_SHA256, policy_source_audit: policyAudit, replay_version: replay.version, input_sha256: inputHashes, compile_admission: admissionRecord, serializer: swift.serializer, checks: swift.checks, complete_runs_byte_identical: true, live_decisions: false, luna_outputs: false, development_prompt_choices: "Frozen supplied question, no changes or history-conditioned arm." };
  for (const arm of swift.candidates) {
    const normalized: Prediction[] = arm.results.map(r => ({ case_id: r.case_id, status: "ok", mode: r.assessment.mode }));
    // Preserve raw modes even on a contract violation. Actions remain a separate artifact.
    files.set(`${arm.candidate}.outputs.jsonl`, jsonl(normalized));
    files.set(`${arm.candidate}.diagnostics.jsonl`, jsonl([{ candidate: arm.candidate, ...metadata }, ...arm.results]));
    files.set(`${arm.candidate}.actions.jsonl`, jsonl(normalized.map(p => ({ case_id: p.case_id, policy_version: POLICY_VERSION, action: actionFor(p), failure_containment: false }))));
  }
  files.set("ts-cross-check.json", canonicalJson(parity) + "\n");
  files.set("policy-source-audit.json", canonicalJson({ ...policyAudit, reference_source: policyReference, current_source: policySource }) + "\n");
  files.set("paired-differences.jsonl", jsonl(rows.map(row => {
    const arms = Object.fromEntries(ARMS.map(id => { const r = swift.candidates.find(c => c.candidate === id)!.results.find(r => r.case_id === row.case_id)!; const prediction: Prediction = { case_id: row.case_id, status: "ok", mode: r.assessment.mode }; return [id, { mode: r.assessment.mode, score: r.assessment.overallScore, action: actionFor(prediction) }]; }));
    const pairs = [[ARMS[0], ARMS[1]], [ARMS[0], ARMS[2]], [ARMS[1], ARMS[2]]].map(([a, b]) => ({ from: a!, to: b!, score_difference: arms[b!]!.score - arms[a!]!.score, mode_changed: arms[b!]!.mode !== arms[a!]!.mode, action_changed: arms[b!]!.action !== arms[a!]!.action }));
    return { case_id: row.case_id, policy_version: POLICY_VERSION, arms, pairs };
  })));
  files.set("projected-requests.jsonl", jsonl(rows.map(row => ({ case_id: row.case_id, request: projectState(row.producer_state), typescript_serialized_request: canonicalJson(projectState(row.producer_state)), swift_serialized_request: swift.projections.find(p => p.case_id === row.case_id)!.serialized_request }))));
  // Shape audit only. These bodies are never sent and no mock answer is an evaluated Luna output.
  files.set("mock-request-shape-audit.json", canonicalJson({ transport_invoked: false, requests: rows.map(r => ({ case_id: r.case_id, body: buildReverseMealDecisionsRequest(projectState(r.producer_state), question) })) }) + "\n");
  const sourcePaths = ["apps/ios/Capability/Core/Services/ReverseScanService.swift", "apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift", "apps/ios/Platform/Persistence/Database/Migrations.swift", "apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift", "backend/gemini-agent/src/services/confidenceService.ts"];
  const harnessFiles = [...readdirSync(resolve(ROOT, "backend/gemini-agent/src/evaluation")).filter(n => n.endsWith(".ts")).map(n => `backend/gemini-agent/src/evaluation/${n}`), ...readdirSync(resolve(ROOT, "backend/gemini-agent/src/__tests__")).filter(n => n.startsWith("reverseMeal")).map(n => `backend/gemini-agent/src/__tests__/${n}`), "apps/ios/Tools/reverse-meal-eval/main.swift", "apps/ios/Tools/reverse-meal-eval/run.sh"];
  const sourceHashes = Object.fromEntries([...sourcePaths, ...harnessFiles].map(p => [resolve(ROOT, p), sha(readFileSync(resolve(ROOT, p)))]));
  if (sourceHashes[resolve(ROOT, "apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift")] !== policyHash) throw new Error("Policy source changed during output preparation");
  for (const [path, hash] of Object.entries(build.sources)) if (sourceHashes[path] !== hash) throw new Error(`Compiled Swift source changed during output preparation: ${path}`);
  const sourceDiffs = Object.fromEntries(sourcePaths.map(p => [resolve(ROOT, p), { status: git(["status", "--porcelain", "--", p]).trim(), diff: git(["diff", "HEAD", "--", p]) }]));
  const outputHashes = Object.fromEntries([...files].map(([name, text]) => [resolve(OUTPUT, name), sha(text)]));
  const manifest = { version: "reverse-meal-v1", source_git_commit: git(["rev-parse", "HEAD"]).trim(), source_and_runner_sha256: sourceHashes, source_worktree_diffs: sourceDiffs, build_record: build, output_sha256: outputHashes, labels_accessed: false, label_hashes: "Not read or hashed by the label-blind candidate runner. The owner's separate scorer receives labels after locking.", question_name: question.name, ...metadata, cross_check_all_agree: parity.all_agree, manifest_self_hash: "Excluded to avoid a self-referential hash; sha256 manifest.json externally." };
  mkdirSync(dirname(OUTPUT), { recursive: true });
  mkdirSync(OUTPUT);
  for (const [name, text] of files) writeFileSync(resolve(OUTPUT, name), text, { flag: "wx" });
  writeFileSync(resolve(OUTPUT, "manifest.json"), canonicalJson(manifest) + "\n", { flag: "wx" });
  console.log(canonicalJson({ locked_directory: OUTPUT, outputs: files.size + 1, manifest_sha256: sha(readFileSync(resolve(OUTPUT, "manifest.json"))), comparison_count: parity.comparison_count, projection_count: parity.projection_count, max_score_difference: parity.max_absolute_score_difference, mismatches: parity.mismatches }));
  if (!parity.all_agree) throw new Error("Swift/TS mismatch recorded; outputs preserved without reconciliation");
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runReverseMeal(process.argv.slice(2)); }
  catch (e) { console.error(e instanceof Error ? e.message : e); process.exitCode = 1; }
}
