/**
 * Loader for the vendored food-safety canon package (source: FridgeLuck PR
 * #126, branch overhaul/food-safety-canon, pinned in PROVENANCE.json).
 *
 * Loading is fail closed by construction: every vendored file is re-read and
 * its SHA-256 must equal the manifest's recorded hash before anything
 * decodes; any absence, drift, or decode failure reports the package as not
 * loaded and the gate closes — a publication is never evaluated against
 * drifted or partially present canon data. The adapter's lint semantics are
 * the canon linter's (canonLinter.ts, a line-faithful port of the canon's
 * Swift sources), pinned by the vendored conformance kit, which the repo
 * tests replay in full (foodSafety.canonConformance.test.ts).
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { CopyLint, decodeRulebook, StepLinter } from "./canonLinter.js";

/** The decoded, ready-to-use canon linters. */
export interface VendoredCanon {
  /** Step linter over the canon rulebook (doneness contract, clauses 1–7). */
  readonly steps: StepLinter;
  /** Copy-pattern linter over the canon's banned-pattern table. */
  readonly copy: CopyLint;
}

export type VendoredCanonLoad =
  | { readonly loaded: true; readonly canon: VendoredCanon }
  | { readonly loaded: false; readonly reason: string };

interface ProvenanceFileEntry {
  readonly path: string;
  readonly sha256: string;
}

interface ProvenanceManifest {
  readonly schema: string;
  readonly sourceBranch: string;
  readonly sourceCommit: string;
  readonly files: readonly ProvenanceFileEntry[];
}

const PROVENANCE_SCHEMA = "fridgeluck/community-food-safety-canon-provenance@v1";

/** The vendored files whose integrity the manifest pins; the set must match exactly. */
const REQUIRED_FILES: readonly string[] = [
  "rules.json",
  "copy-lint-patterns.json",
  "conformance/README.md",
  "conformance/cases-copy-lint.json",
  "conformance/cases-fail-closed.json",
  "conformance/cases-review-and-legacy.json",
  "conformance/cases-temperature-errors.json",
  "conformance/replay-clean.json",
  "conformance/true-negatives.json",
];

/** The canon package vendored beside this module. */
export function defaultVendoredCanonDir(): string {
  return fileURLToPath(new URL("./canon", import.meta.url));
}

/** Loads and verifies the vendored canon package; reports a reason instead of throwing. */
export function loadVendoredCanonPackage(dir: string = defaultVendoredCanonDir()): VendoredCanonLoad {
  try {
    return { loaded: true, canon: loadCanonOrThrow(dir) };
  } catch (error) {
    return { loaded: false, reason: `food-safety canon package not loaded: ${error instanceof Error ? error.message : String(error)}` };
  }
}

function loadCanonOrThrow(dir: string): VendoredCanon {
  const manifest = readManifest(dir);
  verifyFileHashes(dir, manifest);

  let rulesData: string;
  let patternsData: string;
  try {
    rulesData = readVendoredFile(dir, "rules.json");
    patternsData = readVendoredFile(dir, "copy-lint-patterns.json");
  } catch (error) {
    throw new Error(`vendored canon files could not be read: ${error instanceof Error ? error.message : String(error)}`);
  }
  try {
    return { steps: new StepLinter(decodeRulebook(rulesData)), copy: new CopyLint(patternsData) };
  } catch (error) {
    throw new Error(`vendored canon data could not be decoded: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function readManifest(dir: string): ProvenanceManifest {
  let raw: string;
  try {
    raw = readVendoredFile(dir, "PROVENANCE.json");
  } catch (error) {
    throw new Error(`the provenance manifest is missing: ${error instanceof Error ? error.message : String(error)}`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`the provenance manifest is not parsable JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("the provenance manifest is not a JSON object");
  }
  const dict = parsed as Record<string, unknown>;
  if (dict["schema"] !== PROVENANCE_SCHEMA) {
    throw new Error(`the provenance manifest schema is ${JSON.stringify(dict["schema"] ?? null)}, expected "${PROVENANCE_SCHEMA}"`);
  }
  for (const key of ["sourceBranch", "sourceCommit"] as const) {
    if (typeof dict[key] !== "string" || (dict[key] as string).length === 0) {
      throw new Error(`the provenance manifest is missing its ${key} record`);
    }
  }
  if (!Array.isArray(dict["files"])) {
    throw new Error("the provenance manifest lists no files");
  }
  const files: ProvenanceFileEntry[] = [];
  for (const entry of dict["files"]) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error("the provenance manifest has a malformed file entry");
    }
    const row = entry as Record<string, unknown>;
    const path = row["path"];
    const sha256 = row["sha256"];
    if (typeof path !== "string" || path.length === 0 || typeof sha256 !== "string" || sha256.length !== 64 || /[^0-9a-f]/.test(sha256)) {
      throw new Error(`the provenance manifest has a malformed hash entry for ${JSON.stringify(path ?? null)}`);
    }
    files.push({ path, sha256 });
  }
  return { schema: dict["schema"] as string, sourceBranch: dict["sourceBranch"] as string, sourceCommit: dict["sourceCommit"] as string, files };
}

/**
 * The manifest must cover exactly the required files: a missing entry leaves
 * a file unpinned, an extra entry means the manifest no longer describes the
 * package — both are drift.
 */
function verifyFileHashes(dir: string, manifest: ProvenanceManifest): void {
  const recorded = new Map(manifest.files.map((entry) => [entry.path, entry.sha256]));
  const missing = REQUIRED_FILES.filter((path) => !recorded.has(path));
  if (missing.length > 0) {
    throw new Error(`the provenance manifest does not pin: ${missing.join(", ")}`);
  }
  const extra = [...recorded.keys()].filter((path) => !REQUIRED_FILES.includes(path));
  if (extra.length > 0) {
    throw new Error(`the provenance manifest pins files outside the package: ${extra.join(", ")}`);
  }
  for (const path of REQUIRED_FILES) {
    const expected = recorded.get(path);
    if (expected === undefined) {
      throw new Error(`the provenance manifest does not pin: ${path}`);
    }
    let actual: string;
    try {
      actual = createHash("sha256").update(readVendoredFile(dir, path)).digest("hex");
    } catch (error) {
      throw new Error(`vendored canon file ${path} is missing or unreadable: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (actual !== expected.toLowerCase()) {
      throw new Error(`vendored canon file ${path} drifted from its pinned hash (expected ${expected}, found ${actual})`);
    }
  }
}

function readVendoredFile(dir: string, path: string): string {
  return readFileSync(join(dir, path), "utf8");
}
