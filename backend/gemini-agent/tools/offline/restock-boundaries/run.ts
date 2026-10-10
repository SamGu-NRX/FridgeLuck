// CLI entrypoint for the restock-boundaries matrix study.
//
// Usage (from backend/gemini-agent):
//   bun run tools/offline/restock-boundaries/run.ts --seed=20261010 [--out=<dir>]
//
// Writes manifest.json, records.jsonl, and summary.json into the output
// directory and prints SHA-256 digests for each file so any rerun can be
// compared byte-for-byte. The run is fully deterministic given the seed:
// same seed → same bytes, same digests. Generated outputs are reproducible
// and need not be committed; the report quotes the digests instead.

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { runPipeline } from "./pipeline.js";

function parseArgs(argv: string[]): { seed?: number; out?: string } {
  let seed: number | undefined;
  let out: string | undefined;
  for (const arg of argv) {
    if (arg.startsWith("--seed=")) {
      seed = Number(arg.slice("--seed=".length));
      if (!Number.isInteger(seed)) {
        throw new Error(`--seed must be an integer, got: ${arg}`);
      }
    } else if (arg.startsWith("--out=")) {
      out = arg.slice("--out=".length);
    } else {
      throw new Error(`unrecognized argument: ${arg}`);
    }
  }
  return { seed, out };
}

const { seed, out } = parseArgs(process.argv.slice(2));
const seedValue = seed ?? 20261010;
const outDir = resolve(out ?? "restock-boundaries-output");

const result = runPipeline(seedValue);
mkdirSync(outDir, { recursive: true });

const manifestPath = join(outDir, "manifest.json");
const recordsPath = join(outDir, "records.jsonl");
const summaryPath = join(outDir, "summary.json");

writeFileSync(manifestPath, JSON.stringify(result.manifest, null, 2) + "\n");
writeFileSync(
  recordsPath,
  result.records.map((r) => JSON.stringify(r)).join("\n") + "\n"
);
writeFileSync(summaryPath, JSON.stringify(result.summary, null, 2) + "\n");

const digest = (path: string): string =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

console.log(`restock-boundaries: seed=${seedValue} out=${outDir}`);
console.log(`  items=${result.manifest.itemCount} pinnedGeneratedAt=${result.manifest.pinISO}`);
for (const [name, path] of [
  ["manifest", manifestPath],
  ["records", recordsPath],
  ["summary", summaryPath],
] as const) {
  console.log(`  sha256(${name}) = ${digest(path)}`);
}
for (const check of result.summary.checks) {
  console.log(`  [${check.passed ? "PASS" : "FAIL"}] ${check.name} — ${check.detail}`);
}
const failed = result.summary.checks.filter((c) => !c.passed);
if (failed.length > 0) {
  console.error(`${failed.length} check(s) failed`);
  process.exit(1);
}
console.log("all checks passed");
