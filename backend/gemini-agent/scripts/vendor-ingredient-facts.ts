/**
 * Vendors the published FLIngredientFacts dataset byte-for-byte (PR #104,
 * round-three rescope of review blocker 3).
 *
 * The backend no longer DERIVES its ingredient facts. The previous derivation
 * turned a missing axis into an empty known set and dropped the gluten and
 * diet axes, so barley and beef stock reached the gate as if they were
 * reviewed allergen-free. This script copies the published files UNCHANGED
 * from a checkout of the `overhaul/ingredient-facts` branch (PR #127) into
 * the backend's vendored package and records the provenance the loader
 * re-verifies at load time (branch, commit, per-file SHA-256; drift or
 * missing data fails the gate closed).
 *
 * It performs NO semantic transformation: bytes in, bytes out — the only
 * judgment it makes is which commit the bytes came from. Interpretation
 * semantics (a missing axis stays UNKNOWN and unknown blocks every free-from
 * and diet claim) live in src/community/foodSafety/catalog.ts, mirroring the
 * dataset's own conformance runner.
 *
 * Usage:
 *   bun scripts/vendor-ingredient-facts.ts <published-data-dir> \
 *     --branch=overhaul/ingredient-facts --commit=<full-sha> [--out=<dest-dir>]
 *
 * <published-data-dir> holds the published package layout (facts.json,
 * identities.json, conformance/cases.json).
 */
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** The published files vendored, at their published relative paths. */
const VENDORED_FILES = ["facts.json", "identities.json", "conformance/cases.json"] as const;

/** Provenance records a full commit sha, never an abbreviation. */
const COMMIT_PATTERN = /^[0-9a-f]{40}$/;

function sha256Hex(bytes: Buffer): string {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function fail(message: string): never {
  console.error(`vendor-ingredient-facts: ${message}`);
  process.exit(1);
}

interface VendorArgs {
  readonly sourceDir: string;
  readonly outDir: string;
  readonly branch: string;
  readonly commit: string;
}

function parseArgs(): VendorArgs {
  const positional: string[] = [];
  let branch = "";
  let commit = "";
  let outDir = "";
  for (const arg of process.argv.slice(2)) {
    if (arg.startsWith("--branch=")) {
      branch = arg.slice("--branch=".length);
    } else if (arg.startsWith("--commit=")) {
      commit = arg.slice("--commit=".length);
    } else if (arg.startsWith("--out=")) {
      outDir = arg.slice("--out=".length);
    } else {
      positional.push(arg);
    }
  }
  if (positional.length !== 1 || branch.length === 0 || !COMMIT_PATTERN.test(commit)) {
    console.error("usage: bun scripts/vendor-ingredient-facts.ts <published-data-dir> --branch=<branch> --commit=<full-sha> [--out=<dest-dir>]");
    process.exit(2);
  }
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  return {
    sourceDir: resolve(positional[0] as string),
    outDir: outDir.length > 0 ? resolve(outDir) : resolve(scriptDir, "../data/ingredient-facts"),
    branch,
    commit,
  };
}

function readBytes(path: string): Buffer {
  try {
    return readFileSync(path);
  } catch (error) {
    return fail(`cannot read ${path} — the published package must contain ${VENDORED_FILES.join(", ")} (${error instanceof Error ? error.message : String(error)})`);
  }
}

function main(): void {
  const args = parseArgs();
  const copied: Array<{ path: string; sha256: string }> = [];
  for (const relativePath of VENDORED_FILES) {
    const bytes = readBytes(join(args.sourceDir, relativePath));
    const outPath = join(args.outDir, relativePath);
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, bytes);
    // Round-trip proof: the recorded hash must describe bytes that verifiably
    // landed, not bytes the writer merely intended to write.
    if (!readFileSync(outPath).equals(bytes)) {
      fail(`round-trip verification failed for ${outPath} — refusing to record provenance for bytes that did not copy intact`);
    }
    copied.push({ path: relativePath, sha256: sha256Hex(bytes) });
  }
  const manifest = {
    sourceBranch: args.branch,
    sourceCommit: args.commit,
    files: copied,
    extracted: `Vendored byte-for-byte from ${args.branch} at ${args.commit} (the published package at data/ingredient-facts, PR #127) by scripts/vendor-ingredient-facts.ts — no semantic transformation: facts.json and identities.json are the published bytes, and conformance/cases.json is the published conformance suite. The loader re-verifies every hash at load time and fails closed on drift or missing data; interpretation (a missing axis stays UNKNOWN and blocks every free-from and diet claim) lives in src/community/foodSafety/catalog.ts.`,
  };
  const manifestPath = join(args.outDir, "provenance.json");
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  for (const file of copied) {
    console.log(`${file.sha256}  ${file.path}`);
  }
  console.log(`provenance: ${manifestPath}`);
}

main();
