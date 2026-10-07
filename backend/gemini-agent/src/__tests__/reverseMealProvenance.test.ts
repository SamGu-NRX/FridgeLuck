import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { COMPILE_ADMISSION, validateBuildRecord } from "../evaluation/runReverseMeal.js";

const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const ios = fileURLToPath(new URL("../../../../apps/ios/", import.meta.url));
const recordPath = "/tmp/fl-tc/reverse-meal/synthetic-build/build-record.json";
function fixture() {
  const sources = ["Platform/Persistence/Services/ConfidenceLearningService.swift", "Platform/Persistence/Database/Migrations.swift", "Tools/reverse-meal-eval/main.swift"].map(path => ios + path);
  const binaries = ["/tmp/fl-tc/reverse-meal/synthetic-build/reverse-meal-runner", "/tmp/fl-tc/grdb/libGRDB.dylib", "/tmp/fl-tc/grdb/GRDB.swiftmodule"];
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
