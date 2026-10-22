/**
 * Applies the ingredient-facts review bands to the canon.
 *
 * Reads every review/band-*.json under canon/ingredient-facts/review/ (schema
 * fridgeluck/facts-review/v1, one per wave-A packet) and writes the reviewed
 * states into canon/ingredient-facts/facts.json. Mechanical, by design: the
 * judgement happened in the review packets; this script only transfers it.
 *
 * Refusal rules (each refusal leaves the fact exactly as it was and is listed
 * with its reason in the report):
 *
 * - a review whose `before_sha256` does not match the fact as it sits in
 *   facts.json — the fact changed since the review pinned it — UNLESS the fact
 *   already equals the review applied (the band tests' hash-or-already-applied
 *   contract), which is what makes a second run of this script a no-op;
 * - a key reviewed in two band files — the script refuses to pick a winner;
 * - a band file that misses a key of its band (facts.json keys from
 *   `band.first` to `band.last`, JavaScript default sort) or carries a key
 *   outside it — the whole file is refused, nothing from it is applied;
 * - a review whose fact key does not exist in facts.json.
 *
 * Output format: facts.json is written exactly in the canon's existing format
 * — JSON, two-space indent, no trailing newline, the canon's key order kept
 * (untouched facts and untouched fact fields keep their byte-identical
 * serialization; `allergens` is replaced wholesale with the reviewed order,
 * `diets` merges the reviewed states over the existing ones). Applying the
 * same files twice changes nothing, byte for byte.
 *
 * Usage: bun run src/run/apply-facts-review.ts [--write=false]
 * With --write=false the script reports what it would do without writing.
 */

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

interface FactEvidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}

interface ReviewState {
  readonly state: string;
  readonly evidence: FactEvidence;
}

export interface ReviewEntry {
  readonly key: string;
  readonly before_sha256: string;
  readonly allergens?: Readonly<Record<string, ReviewState>>;
  readonly diets?: Readonly<Record<string, ReviewState>>;
  readonly changes?: readonly unknown[];
}

export interface ReviewFile {
  readonly schema: string;
  readonly packet: string;
  readonly base_commit: string;
  readonly band: { readonly first: string; readonly last: string; readonly count: number };
  readonly reviews: readonly ReviewEntry[];
}

export interface Skip {
  readonly key: string | null;
  readonly packet: string;
  readonly reason: string;
}

export interface ApplyReport {
  /** Review files considered, in filename order. */
  readonly files: readonly string[];
  /** Facts the script changed (hash matched, review applied). */
  readonly applied: readonly { key: string; packet: string }[];
  /** Facts already equal to their review — the idempotence case. */
  readonly unchanged: readonly { key: string; packet: string }[];
  /** Reviews and whole files refused, each with the reason; facts left as they were. */
  readonly refused: readonly Skip[];
  /** Whether facts.json was rewritten on this run. */
  readonly wrote: boolean;
}

const sha256 = (s: string): string => createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

/** Deep equality on parsed JSON, insensitive to property insertion order. */
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  const ka = Object.keys(a as object).sort();
  const kb = Object.keys(b as object).sort();
  if (ka.length !== kb.length || !ka.every((k, i) => k === kb[i])) return false;
  return ka.every((k) => deepEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

/** What facts.json holds for `fact` once its review is applied. */
export function applied(fact: Record<string, unknown>, rev: ReviewEntry): Record<string, unknown> {
  const next: Record<string, unknown> = { ...fact, allergens: rev.allergens };
  if (rev.diets) next.diets = { ...((fact.diets as object) ?? {}), ...rev.diets };
  return next;
}

const REVIEW_SCHEMA = "fridgeluck/facts-review/v1";

export interface ApplyPaths {
  readonly factsPath: string;
  readonly reviewDir: string;
}

export function defaultPaths(): ApplyPaths {
  return {
    factsPath: new URL("../lechef/canon/ingredient-facts/facts.json", import.meta.url).pathname,
    reviewDir: new URL("../lechef/canon/ingredient-facts/review", import.meta.url).pathname,
  };
}

/**
 * Apply every review/band-*.json in `paths.reviewDir` to `paths.factsPath`.
 * With `write` false the canon is analyzed but not rewritten (dry run).
 */
export function applyFactsReview(paths: ApplyPaths = defaultPaths(), write = true): ApplyReport {
  const canon = JSON.parse(readFileSync(paths.factsPath, "utf8")) as {
    version: number;
    facts: Record<string, Record<string, unknown>>;
  };
  const facts = canon.facts;
  const fileNames = readdirSync(paths.reviewDir).filter((f) => /^band-.*\.json$/.test(f)).sort();

  const appliedList: { key: string; packet: string }[] = [];
  const unchangedList: { key: string; packet: string }[] = [];
  const refused: Skip[] = [];

  // Pass 1: parse every file, refuse broken files up front, and collect
  // cross-file duplicate keys (refused in every file that carries them).
  type Parsed = { file: string; review: ReviewFile; entries: Map<string, ReviewEntry> };
  const parsed: Parsed[] = [];
  for (const file of fileNames) {
    const review = JSON.parse(readFileSync(`${paths.reviewDir}/${file}`, "utf8")) as ReviewFile;
    if (review.schema !== REVIEW_SCHEMA) {
      refused.push({ key: null, packet: review.packet ?? file, reason: `schema ${review.schema} is not ${REVIEW_SCHEMA}` });
      continue;
    }
    const bandKeys = Object.keys(facts).sort().filter((k) => k >= review.band.first && k <= review.band.last);
    const entries = new Map<string, ReviewEntry>();
    let fileBroken = false;
    for (const entry of review.reviews) {
      if (entries.has(entry.key)) {
        refused.push({ key: entry.key, packet: review.packet, reason: `reviewed twice in the same file (${file})` });
        fileBroken = true;
      }
      entries.set(entry.key, entry);
    }
    const missing = bandKeys.filter((k) => !entries.has(k));
    const extra = [...entries.keys()].filter((k) => !bandKeys.includes(k));
    if (missing.length > 0 || extra.length > 0) {
      refused.push({
        key: null,
        packet: review.packet,
        reason:
          `file ${file} does not cover its band ${review.band.first}..${review.band.last}` +
          (missing.length ? `; missing: ${missing.join(", ")}` : "") +
          (extra.length ? `; outside the band: ${extra.join(", ")}` : ""),
      });
      continue;
    }
    if (fileBroken) continue;
    parsed.push({ file, review, entries });
  }

  const seenWhere = new Map<string, string[]>();
  for (const p of parsed) for (const key of p.entries.keys()) seenWhere.set(key, [...(seenWhere.get(key) ?? []), p.review.packet]);

  // Pass 2: apply what can be applied.
  for (const p of parsed) {
    for (const [key, rev] of p.entries) {
      const where = seenWhere.get(key) ?? [];
      if (where.length > 1) {
        refused.push({ key, packet: p.review.packet, reason: `key reviewed in two files: ${where.join(", ")}` });
        continue;
      }
      const fact = facts[key];
      if (!fact) {
        refused.push({ key, packet: p.review.packet, reason: "no such fact in facts.json" });
        continue;
      }
      if (!rev.allergens) {
        refused.push({ key, packet: p.review.packet, reason: "review carries no allergens block" });
        continue;
      }
      const next = applied(fact, rev);
      if (deepEqual(next, fact)) {
        unchangedList.push({ key, packet: p.review.packet }); // already applied: leave the fact byte-identical
        continue;
      }
      if (sha256(JSON.stringify(fact)) !== rev.before_sha256) {
        refused.push({
          key,
          packet: p.review.packet,
          reason: `before_sha256 mismatch: fact changed since the review pinned it (expected ${rev.before_sha256}, got ${sha256(JSON.stringify(fact))})`,
        });
        continue;
      }
      facts[key] = next;
      appliedList.push({ key, packet: p.review.packet });
    }
  }

  if (write && appliedList.length > 0) {
    // The canon's format: two-space indent, no trailing newline, key order kept
    // (facts keep their insertion positions; only the replaced fact values change).
    writeFileSync(paths.factsPath, JSON.stringify(canon, null, 2));
  }
  return { files: fileNames, applied: appliedList, unchanged: unchangedList, refused, wrote: write && appliedList.length > 0 };
}

function main(): void {
  const write = !process.argv.includes("--write=false");
  const report = applyFactsReview(defaultPaths(), write);
  const lines: string[] = [];
  lines.push(`apply-facts-review: ${report.files.length} band file(s) (${report.files.join(", ")})`);
  lines.push(`  applied:   ${report.applied.length} (facts.json ${report.wrote ? "rewritten" : "unchanged — nothing to write"})`);
  lines.push(`  unchanged: ${report.unchanged.length} (already equal to their review)`);
  if (report.refused.length > 0) {
    lines.push(`  refused:   ${report.refused.length} — fact left as it was for each:`);
    for (const r of report.refused) lines.push(`    - [${r.packet}] ${r.key ?? "(file)"}: ${r.reason}`);
  }
  console.log(lines.join("\n"));
}

if (import.meta.main) main();
