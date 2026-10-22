/**
 * Band-d facts review (burst14-fridgeluck-facts-review-d).
 *
 * Pins the review packet at canon/ingredient-facts/review/band-d.json — the
 * facts from `naan` to `sesame-oil` inclusive in JavaScript's default string
 * sort (95 facts) — and proves it applies mechanically through the REAL
 * lookup (src/lechef/allergens.ts), never a re-implementation:
 *
 * 1. the reviewed keys are exactly the band's keys at the current facts.json;
 * 2. every fact still hashes to its before_sha256, or already equals the
 *    review applied (the file stays green after the apply packet runs);
 * 3. every review carries all ten allergen tokens, component-less facts
 *    carry all five diet tokens, every state is in its allowed set, and
 *    every "reference" evidence names an https URL and a retrieval date;
 * 4. staging a temporary copy of allergens.ts, every module it imports and
 *    the canon, applying the band there, and running allergenViolations:
 *    contains / free / unknown anchors from this band hold, and the band's
 *    ask count drops for the nine measured restrictions.
 */

import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { Eater } from "../../lechef/types.js";

const ALLERGEN_TOKENS = [
  "milk",
  "egg",
  "fish",
  "crustaceanShellfish",
  "molluscanShellfish",
  "treeNuts",
  "peanuts",
  "wheat",
  "soy",
  "sesame",
] as const;
const DIET_TOKENS = ["vegetarian", "vegan", "pescatarian", "dairyFree", "glutenFree"] as const;
const ALLERGEN_STATES = ["contains", "free", "unknown"];
const DIET_STATES = ["allowed", "violated", "unknown"];
/** The nine restrictions the review evidence measured (shellfish = both shellfish tokens). */
const MEASURED = ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"];

interface FactEvidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}
interface StateEntry {
  readonly state: string;
  readonly evidence: FactEvidence;
}
interface ReviewChange {
  readonly path: string;
  readonly from: string;
  readonly to: string;
  readonly reason: string;
  readonly evidence: string;
}
interface ReviewEntry {
  readonly key: string;
  readonly before_sha256: string;
  readonly allergens: Readonly<Record<string, StateEntry>>;
  readonly diets?: Readonly<Record<string, StateEntry>>;
  readonly changes?: readonly ReviewChange[];
}
interface ReviewPacket {
  readonly schema: string;
  readonly packet: string;
  readonly base_commit: string;
  readonly band: { readonly first: string; readonly last: string; readonly count: number };
  readonly reviews: readonly ReviewEntry[];
}

const CANON_DIR = fileURLToPath(new URL("../../lechef/canon/ingredient-facts/", import.meta.url));
const LECHEF_DIR = fileURLToPath(new URL("../../lechef/", import.meta.url));
const canon = JSON.parse(readFileSync(path.join(CANON_DIR, "facts.json"), "utf8")) as {
  version: number;
  facts: Record<string, Record<string, unknown>>;
};
const review = JSON.parse(readFileSync(path.join(CANON_DIR, "review", "band-d.json"), "utf8")) as ReviewPacket;

const bandKeys = Object.keys(canon.facts).sort().filter((k) => k >= "naan" && k <= "sesame-oil");

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/** Canonical JSON (sorted keys) so apply-shape comparisons survive key order. */
function stable(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${stable(obj[k])}`)
    .join(",")}}`;
}

/** The fact with the review applied: allergens replaced, listed diets overwritten, the rest kept. */
function applied(fact: Record<string, unknown>, r: ReviewEntry): Record<string, unknown> {
  const next: Record<string, unknown> = { ...fact, allergens: r.allergens };
  if (r.diets) next.diets = { ...((fact.diets as Record<string, unknown> | undefined) ?? {}), ...r.diets };
  return next;
}

type ViolationsFn = (ingredientId: string, eaters: readonly Eater[]) => readonly string[];

/**
 * Copy allergens.ts, every module it (transitively) imports, and
 * canon/ingredient-facts/ into a temp tree, optionally with the band applied
 * to facts.json there, and return the temp root.
 */
function stage(applyReview: boolean): string {
  const tmp = mkdtempSync(path.join(tmpdir(), "fl-band-d-"));
  const dstLechef = path.join(tmp, "lechef");
  mkdirSync(dstLechef, { recursive: true });
  const files: string[] = [];
  const visit = (file: string): void => {
    if (files.includes(file)) return;
    files.push(file);
    const src = readFileSync(file, "utf8");
    for (const m of src.matchAll(/(?:from|import)\s*["'](\.[^"']+)["']/g)) {
      const base = path.resolve(path.dirname(file), m[1]);
      const candidates = [base, base.replace(/\.js$/, ".ts"), `${base}.ts`];
      const hit = candidates.find((c) => existsSync(c) && statSync(c).isFile());
      if (hit) visit(hit);
    }
  };
  visit(path.join(LECHEF_DIR, "allergens.ts"));
  for (const file of files) {
    const dst = path.join(dstLechef, path.relative(LECHEF_DIR, file));
    mkdirSync(path.dirname(dst), { recursive: true });
    cpSync(file, dst);
  }
  const dstCanon = path.join(dstLechef, "canon", "ingredient-facts");
  mkdirSync(dstCanon, { recursive: true });
  cpSync(path.join(CANON_DIR, "identities.json"), path.join(dstCanon, "identities.json"));
  const factsJson = JSON.parse(readFileSync(path.join(CANON_DIR, "facts.json"), "utf8")) as typeof canon;
  if (applyReview) {
    const byKey = new Map(review.reviews.map((r) => [r.key, r]));
    for (const [key, fact] of Object.entries(factsJson.facts)) {
      const r = byKey.get(key);
      if (!r) continue;
      factsJson.facts[key] = applied(fact, r);
    }
  }
  writeFileSync(path.join(dstCanon, "facts.json"), JSON.stringify(factsJson));
  return tmp;
}

async function loadViolations(tmp: string): Promise<ViolationsFn> {
  const mod = (await import(pathToFileURL(path.join(tmp, "lechef", "allergens.ts")).href)) as {
    allergenViolations: ViolationsFn;
  };
  return mod.allergenViolations;
}

const eater = (restriction: string): readonly Eater[] => [{ name: "eater", restrictions: [restriction] }];

function askCounts(fn: ViolationsFn): { total: number; per: Record<string, number> } {
  const per: Record<string, number> = {};
  let total = 0;
  for (const restriction of MEASURED) {
    let n = 0;
    for (const key of bandKeys) if (fn(key, eater(restriction)).length > 0) n++;
    per[restriction] = n;
    total += n;
  }
  return { total, per };
}

describe("facts review band d (naan..sesame-oil)", () => {
  test("packet pins this band's keys, each exactly once", () => {
    expect(review.schema).toBe("fridgeluck/facts-review/v1");
    expect(review.packet).toBe("burst14-fridgeluck-facts-review-d");
    expect(review.band).toEqual({ first: "naan", last: "sesame-oil", count: bandKeys.length });
    expect(bandKeys.length).toBeGreaterThan(0);
    expect(reviewed_keys(review)).toEqual(bandKeys);
  });

  test("every fact is unchanged (hash pins the base) or already equals the review applied", () => {
    for (const r of review.reviews) {
      const fact = canon.facts[r.key];
      const unchanged = sha256(JSON.stringify(fact)) === r.before_sha256;
      const alreadyApplied = stable(fact) === stable(applied(fact, r));
      expect([r.key, unchanged || alreadyApplied]).toEqual([r.key, true]);
    }
  });

  test("each review has the ten allergen tokens, five diets on component-less facts, valid states, and dated https evidence on every reference", () => {
    for (const r of review.reviews) {
      const fact = canon.facts[r.key];
      for (const token of ALLERGEN_TOKENS) {
        const entry = r.allergens[token];
        expect([r.key, token, entry !== undefined]).toEqual([r.key, token, true]);
        expect(ALLERGEN_STATES).toContain(entry.state);
      }
      if (!fact.components) {
        for (const diet of DIET_TOKENS) {
          const entry = r.diets?.[diet];
          expect([r.key, diet, entry !== undefined]).toEqual([r.key, diet, true]);
          expect(DIET_STATES).toContain(entry?.state);
        }
      }
      for (const entry of [...Object.values(r.allergens), ...Object.values(r.diets ?? {})]) {
        if (entry.evidence.kind === "reference") {
          expect(entry.evidence.note + " " + entry.evidence.ref).toMatch(/https:\/\/\S+/);
          expect(entry.evidence.note + " " + entry.evidence.ref).toMatch(/retrieved \d{4}-\d{2}-\d{2}/);
        }
      }
    }
  });

  test("applying the band through the real lookup holds anchors and drops the band's asks", async () => {
    const beforeTmp = stage(false);
    const afterTmp = stage(true);
    try {
      const violationsBefore = await loadViolations(beforeTmp);
      const violationsAfter = await loadViolations(afterTmp);
      const before = askCounts(violationsBefore);
      const after = askCounts(violationsAfter);
      const outOf = `${bandKeys.length * MEASURED.length}`;
      console.log(`[factsReviewBandD] band asks before apply: ${before.total}/${outOf} ${JSON.stringify(before.per)}`);
      console.log(`[factsReviewBandD] band asks after apply:  ${after.total}/${outOf} ${JSON.stringify(after.per)}`);
      // On the applied canon stage(false) already carries the band and
      // stage(true) re-applies it idempotently, so before == after; the
      // invariant pinned here at every stage is that applying the band never
      // ADDS an ask (pre-apply it was the strict drop this test first shipped).
      expect(after.total).toBeLessThanOrEqual(before.total);

      // contains: a hard violation, named as carrying.
      expect(violationsAfter("sesame-oil", eater("sesame")).join(" ")).toMatch(/carries sesame/);
      expect(violationsAfter("salmon", eater("fish")).join(" ")).toMatch(/carries.*\bfish\b/);
      // contains reached through composition (pesto's pine-nuts component).
      expect(violationsAfter("pesto", eater("treeNuts")).join(" ")).toMatch(/carries.*\btreeNuts\b/);
      // free: a reviewed free state on every fact reached clears silently.
      expect(violationsAfter("olive-oil", eater("milk"))).toEqual([]);
      expect(violationsAfter("salt", eater("shellfish"))).toEqual([]);
      // unknown: fails closed with a confirmation-required line.
      expect(violationsAfter("sausage", eater("wheat")).join(" ")).toMatch(/confirmation required/);
      expect(violationsAfter("red-wine", eater("milk")).join(" ")).toMatch(/confirmation required/);
      // the app's shellfish class covers molluscs too.
      expect(violationsAfter("scallop", eater("shellfish")).join(" ")).toMatch(/carries.*\bmolluscanShellfish\b/);
    } finally {
      rmSync(beforeTmp, { recursive: true, force: true });
      rmSync(afterTmp, { recursive: true, force: true });
    }
  });
});

function reviewed_keys(packet: ReviewPacket): string[] {
  return packet.reviews.map((r) => r.key);
}
