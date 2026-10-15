import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { COMPILE_ADMISSION, runReverseMeal, validateExecutionRecord, validateBuildRecord } from "../evaluation/runReverseMeal.js";

const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const ios = fileURLToPath(new URL("../../../../apps/ios/", import.meta.url));
const recordPath = "/tmp/fl-tc/reverse-meal/synthetic-build/build-record.json";
function fixture() {
  const sources = ["Platform/Persistence/Services/ConfidenceLearningService.swift", "Platform/Persistence/Database/Migrations.swift", "Tools/reverse-meal-eval/main.swift"].map(path => ios + path);
  const binaries = ["/tmp/fl-tc/reverse-meal/synthetic-build/reverse-meal-runner", "/tmp/fl-tc/reverse-meal/synthetic-build/grdb/libGRDB.dylib", "/tmp/fl-tc/reverse-meal/synthetic-build/grdb/GRDB.swiftmodule"];
  const files = new Map([...sources, ...binaries, ios + "Tools/reverse-meal-eval/run.sh"].map(path => [path, Buffer.from(`synthetic file ${path}`)]));
  const hashes = (paths: string[]) => Object.fromEntries(paths.map(path => [path, sha(files.get(path)!)]));
  const record = { sources: hashes(sources), binary_and_grdb: hashes(binaries), swift_version: "synthetic compiler", compile_admission: COMPILE_ADMISSION, build_script_sha256: sha(files.get(ios + "Tools/reverse-meal-eval/run.sh")!) };
  const read = (path: string) => { const bytes = files.get(path); if (!bytes) throw new Error(`unexpected read: ${path}`); return bytes; };
  return { record, read };
}

test("build record accepts exactly the current sources and the recorded build's executable and GRDB", () => {
  const f = fixture();
  expect(validateBuildRecord(f.record, recordPath, f.read)).toEqual(f.record);
});
for (const map of ["sources", "binary_and_grdb"] as const) {
  test(`${map} refuses empty maps, missing entries, extra entries and bad hashes`, () => {
    const f = fixture(), path = Object.keys(f.record[map])[0]!;
    const empty = structuredClone(f.record); empty[map] = {};
    expect(() => validateBuildRecord(empty, recordPath, f.read)).toThrow(`missing entry ${path}`);
    const missing = structuredClone(f.record); delete missing[map][path];
    expect(() => validateBuildRecord(missing, recordPath, f.read)).toThrow(`missing entry ${path}`);
    const extra = structuredClone(f.record); extra[map]["unexpected.swift"] = "a".repeat(64);
    expect(() => validateBuildRecord(extra, recordPath, f.read)).toThrow("extra entry unexpected.swift");
    for (const hash of ["", "not-a-hash", "a".repeat(64)]) {
      const mismatch = structuredClone(f.record); mismatch[map][path] = hash;
      expect(() => validateBuildRecord(mismatch, recordPath, f.read)).toThrow(hash.length === 64 ? `sha256 mismatch for ${path}` : `non-empty sha256 required for ${path}`);
    }
  });
}
test("build record refuses missing or extra top-level entries and invalid script/admission evidence", () => {
  const f = fixture();
  const { sources: _, ...missing } = f.record;
  expect(() => validateBuildRecord(missing, recordPath, f.read)).toThrow("missing entry sources");
  expect(() => validateBuildRecord({ ...f.record, extra: true }, recordPath, f.read)).toThrow("extra entry extra");
  expect(() => validateBuildRecord({ ...f.record, compile_admission: "" }, recordPath, f.read)).toThrow("compile_admission");
  expect(() => validateBuildRecord({ ...f.record, build_script_sha256: "" }, recordPath, f.read)).toThrow("non-empty sha256");
  expect(() => validateBuildRecord({ ...f.record, build_script_sha256: "a".repeat(64) }, recordPath, f.read)).toThrow("sha256 mismatch");
});
function executionRecord(bytes: Buffer, executable: string) {
  return { schema: "reverse-meal-execution-record-v1", executable_sha256: executable, result_sha256: sha(bytes), started_at: "2026-10-07T00:00:00.000Z", finished_at: "2026-10-07T00:00:01.000Z", argv: ["synthetic-runner", "states", "replay", "--result", "result.json"] };
}
test("synthetic execution record binds exact result bytes to the recorded executable", () => {
  const result = Buffer.from('{"synthetic":true}\n'), binary = sha(Buffer.from("synthetic executable"));
  const record = executionRecord(result, binary);
  expect(validateExecutionRecord(record, result, binary)).toEqual(record);
  expect(() => validateExecutionRecord(record, Buffer.concat([result, Buffer.from("\n")]), binary)).toThrow("result_sha256");
  expect(() => validateExecutionRecord(record, result, "a".repeat(64))).toThrow("executable_sha256");
  expect(() => validateExecutionRecord({ ...record, schema: "other" }, result, binary)).toThrow("schema");
  expect(() => validateExecutionRecord({ ...record, started_at: "not a date" }, result, binary)).toThrow("ISO-8601 UTC");
  expect(() => validateExecutionRecord({ ...record, finished_at: "2026-10-06T00:00:00Z" }, result, binary)).toThrow("precedes started_at");
  expect(() => validateExecutionRecord({ ...record, argv: [] }, result, binary)).toThrow("argv");
});
test("runner requires valid execution records beside both supplied Swift results", () => {
  const dir = mkdtempSync(join(tmpdir(), "swift-record-test-"));
  try {
    const build = join(dir, "build"), first = join(dir, "first"), second = join(dir, "second"), out = join(dir, "out");
    for (const path of [join(build, "grdb"), first, second]) mkdirSync(path, { recursive: true });
    const f = fixture();
    const binaryPaths = [join(build, "reverse-meal-runner"), join(build, "grdb/libGRDB.dylib"), join(build, "grdb/GRDB.swiftmodule")];
    for (const path of binaryPaths) writeFileSync(path, "synthetic binary");
    const record = { ...f.record, sources: Object.fromEntries(Object.keys(f.record.sources).map(path => [path, sha(readFileSync(path))])), binary_and_grdb: Object.fromEntries(binaryPaths.map(path => [path, sha(readFileSync(path))])), build_script_sha256: sha(readFileSync(ios + "Tools/reverse-meal-eval/run.sh")) };
    const path = join(build, "build-record.json"); writeFileSync(path, JSON.stringify(record));
    const bytes = Buffer.from('{"checks":{}}\n');
    for (const directory of [first, second]) writeFileSync(join(directory, "result.json"), bytes);
    const args = ["--out", out, "--swift-first", join(first, "result.json"), "--swift-second", join(second, "result.json"), "--build-record", path];
    expect(() => runReverseMeal(args)).toThrow("Required execution record for --swift-first");
    const execution = executionRecord(bytes, record.binary_and_grdb[binaryPaths[0]!]!);
    writeFileSync(join(first, "execution-record.json"), JSON.stringify(execution));
    expect(() => runReverseMeal(args)).toThrow("Required execution record for --swift-second");
    writeFileSync(join(second, "execution-record.json"), JSON.stringify({ ...execution, result_sha256: "a".repeat(64) }));
    expect(() => runReverseMeal(args)).toThrow("result_sha256");
    writeFileSync(join(second, "execution-record.json"), JSON.stringify({ ...execution, executable_sha256: "a".repeat(64) }));
    expect(() => runReverseMeal(args)).toThrow("executable_sha256");
    writeFileSync(join(second, "execution-record.json"), JSON.stringify(execution));
    expect(() => runReverseMeal(args)).toThrow("Swift acceptance checks missing");
    expect(existsSync(out)).toBe(false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
