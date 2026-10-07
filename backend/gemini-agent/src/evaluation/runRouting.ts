import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import { assessCold, assessWarm, DEV_SEQUENCE_HASH } from "./bayesRouting.js";
import { canonicalJson } from "./canonicalJson.js";
import { validateRoutingRow, type RoutingRow } from "./routingInput.js";

export type Candidate = "bayes-cold" | "bayes-warm";
export function validateCandidate(value: unknown): asserts value is Candidate {
  if (value !== "bayes-cold" && value !== "bayes-warm") throw new Error("candidate: expected bayes-cold or bayes-warm; live Decisions access is not authorized");
}

export function decodeStrict(text: string): unknown {
  const value: unknown = JSON.parse(text);
  // JSON.parse discards duplicate keys; inspect tokens before accepting that loss.
  const tokens = text.match(/"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^\s{}\[\],:]+/g) ?? [];
  let index = 0;
  function visit(): void {
    const token = tokens[index++];
    if (token === "{") {
      const seen = new Set<string>();
      while (tokens[index] !== "}") {
        const key: string = JSON.parse(tokens[index++]!);
        if (seen.has(key)) throw new Error(`Duplicate JSON key: ${key}`);
        seen.add(key);
        index++; // colon, already checked by JSON.parse
        visit();
        if (tokens[index] !== ",") break;
        index++;
      }
      index++;
    } else if (token === "[") {
      while (tokens[index] !== "]") {
        visit();
        if (tokens[index] !== ",") break;
        index++;
      }
      index++;
    }
  }
  visit();
  return value;
}
export function parseRoutingInputs(text: string): RoutingRow[] {
  const rows: RoutingRow[] = [];
  const ids = new Set<string>();
  text.split(/\r?\n/).forEach((line, i) => {
    if (!line.trim()) return;
    try {
      const row = decodeStrict(line);
      validateRoutingRow(row);
      if (ids.has(row.case_id)) throw new Error(`Duplicate case_id: ${row.case_id}`);
      ids.add(row.case_id);
      rows.push(row);
    } catch (error) {
      throw new Error(`Input line ${i + 1}: ${error instanceof Error ? error.message : String(error)}`);
    }
  });
  return rows;
}
export function assertOutputPathsAvailable(inputs: string, out: string, diagnostics: string, exists = existsSync): void {
  const paths = [inputs, out, diagnostics].map(p => resolve(p));
  if (new Set(paths).size !== paths.length) throw new Error("inputs, out and diagnostics must be distinct paths");
  for (const path of paths.slice(1)) if (exists(path)) throw new Error(`Refusing to overwrite existing output: ${path}`);
}
export function evaluateRows(rows: RoutingRow[], candidate: Candidate) {
  validateCandidate(candidate);
  return [...rows].sort((a, b) => a.case_id < b.case_id ? -1 : a.case_id > b.case_id ? 1 : 0).map(row => {
    const result = candidate === "bayes-cold" ? assessCold(row.request) : assessWarm(row.request);
    return { normalized: { case_id: row.case_id, status: result.status, mode: result.mode }, diagnostics: { case_id: row.case_id, ...result.diagnostics } };
  });
}
export function renderRun(rows: RoutingRow[], candidate: Candidate, metadata: Record<string, unknown>) {
  const results = evaluateRows(rows, candidate);
  const header = {
    ...metadata,
    candidate: candidate === "bayes-cold" ? "A0-cold-prior" : "A1-warm-dev-synthetic",
    ...(candidate === "bayes-warm" ? { devSequenceId: "dev-warm-v1", devSequenceSha256: DEV_SEQUENCE_HASH } : {})
  };
  const jsonl = (values: unknown[]) => values.map(canonicalJson).join("\n") + "\n";
  return { out: results.length ? jsonl(results.map(r => r.normalized)) : "", diagnostics: jsonl([header, ...results.map(r => r.diagnostics)]) };
}

function auditPythonParity(raw: string, rows: RoutingRow[]) {
  // Audit through the runner only. Python preserves input float types that JS cannot.
  const audit = spawnSync("python3", ["-B", "-c", "import json,sys; print(json.dumps([json.dumps(json.loads(line)['request'],sort_keys=True,separators=(',', ':'),ensure_ascii=False,allow_nan=False) for line in sys.stdin if line.strip()],ensure_ascii=False))"], { input: raw, encoding: "utf8" });
  if (audit.status !== 0) throw new Error("Python canonical parity audit failed");
  const pythonInputs: string[] = JSON.parse(audit.stdout);
  let divergentCases = 0;
  const spellings = new Map<string, { python: string; javascript: string; count: number }>();
  rows.forEach((row, i) => {
    const python = pythonInputs[i]!;
    const javascript = canonicalJson(row.request);
    if (!isDeepStrictEqual(JSON.parse(python), JSON.parse(javascript))) throw new Error(`Evidence parity failed: ${row.case_id}`);
    if (python !== javascript) divergentCases++;
    const numbers = (s: string) => (s.match(/"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g) ?? []).filter(s => !s.startsWith('"'));
    const a = numbers(python), b = numbers(javascript);
    a.forEach((n, j) => {
      if (n === b[j]) return;
      const key = `${n}:${b[j]}`;
      const entry = spellings.get(key) ?? { python: n, javascript: b[j]!, count: 0 };
      entry.count++;
      spellings.set(key, entry);
    });
  });
  return { decodedParity: true, divergentCases, numericSpellings: [...spellings.values()] };
}
function sourceMetadata() {
  const cwd = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../../..");
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd, encoding: "utf8" });
  const changes = spawnSync("git", ["status", "--porcelain", "--", "backend/gemini-agent/src/services/confidenceService.ts"], { cwd, encoding: "utf8" });
  if (head.status !== 0 || changes.status !== 0) throw new Error("Unable to record source commit and confidence service status");
  if (changes.stdout.trim()) throw new Error("confidenceService.ts has local changes; frozen source required");
  return { sourceGitCommit: head.stdout.trim(), confidenceServiceLocalChanges: false };
}
export function runRouting(args: string[]) {
  const options = new Map<string, string>();
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]!;
    if (!["--candidate", "--inputs", "--out", "--diagnostics"].includes(key) || !args[i + 1] || options.has(key)) throw new Error(`Invalid CLI option: ${key}`);
    options.set(key, args[i + 1]!);
  }
  if (options.size !== 4) throw new Error("Required: --candidate --inputs --out --diagnostics");
  const candidate = options.get("--candidate");
  validateCandidate(candidate);
  const inputs = options.get("--inputs")!, out = options.get("--out")!, diagnostics = options.get("--diagnostics")!;
  assertOutputPathsAvailable(inputs, out, diagnostics);
  const raw = readFileSync(inputs);
  const rows = parseRoutingInputs(raw.toString("utf8"));
  const rendered = renderRun(rows, candidate, {
    inputSha256: createHash("sha256").update(raw).digest("hex"),
    ...sourceMetadata(),
    utcTime: new Date().toISOString(),
    canonicalJsonParity: auditPythonParity(raw.toString("utf8"), rows)
  });
  writeFileSync(out, rendered.out, { flag: "wx" });
  writeFileSync(diagnostics, rendered.diagnostics, { flag: "wx" });
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runRouting(process.argv.slice(2)); }
  catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
}
