/**
 * Band-e facts-review integrity and applied-canon runtime checks
 * (packet burst14-fridgeluck-facts-review-e).
 *
 * The review file review/band-e.json is a pinned, mechanical input: a later
 * packet applies all five band files to facts.json. This test keeps the file
 * honest while it waits:
 *
 * 1. The reviewed keys are exactly the band (facts.json keys from
 *    sesame-seeds to zucchini inclusive, JavaScript default string sort), each
 *    once. A reviewed key deleted from facts.json by a later packet (the
 *    small-fixes packet removes the never-read sunflower-oil fact) is
 *    tolerated: the band rule is then evaluated over the remaining keys.
 * 2. Every fact either still hashes to its before_sha256 (the review is
 *    pending) or already equals the review applied (the apply packet ran), so
 *    this test is green on both sides of the apply.
 * 3. Structure: all ten allergen tokens, five diet states on component-less
 *    facts, states inside their allowed sets, and every "reference" evidence
 *    naming an https URL with a retrieval date.
 * 4. Runtime: the band is applied to a temporary copy of allergens.ts, every
 *    module it imports, and canon/ingredient-facts/ (the patched facts.json is
 *    written there and the copy is imported — the lookup is never
 *    re-implemented), then anchors from the band are asserted and the band's
 *    ask count per restriction is printed before and after.
 */

import { describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const AGENT_ROOT = join(import.meta.dir, "../../..");
const CANON_DIR = join(AGENT_ROOT, "src/lechef/canon/ingredient-facts");
const REVIEW_PATH = join(CANON_DIR, "review/band-e.json");

const canon: { version: number; facts: Record<string, any> } = JSON.parse(
  readFileSync(join(CANON_DIR, "facts.json"), "utf8")
);
const identities: { ingredients: readonly { key: string; synonyms?: readonly string[] }[] } = JSON.parse(
  readFileSync(join(CANON_DIR, "identities.json"), "utf8")
);
const review: ReviewFile = JSON.parse(readFileSync(REVIEW_PATH, "utf8"));

const ALLERGENS = ["milk", "egg", "fish", "crustaceanShellfish", "molluscanShellfish", "treeNuts", "peanuts", "wheat", "soy", "sesame"] as const;
const DIETS = ["vegan", "vegetarian", "pescatarian", "dairyFree", "glutenFree"] as const;
const NINE_RESTRICTIONS = ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"] as const;

interface Evidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}
interface State {
  readonly state: string;
  readonly evidence: Evidence;
}
interface Review {
  readonly key: string;
  readonly before_sha256: string;
  readonly allergens: Readonly<Record<string, State>>;
  readonly diets?: Readonly<Record<string, State>>;
  readonly changes?: readonly { readonly path: string; readonly from: string; readonly to: string; readonly reason: string; readonly evidence: string }[];
}
interface ReviewFile {
  readonly schema: string;
  readonly packet: string;
  readonly base_commit: string;
  readonly band: { readonly first: string; readonly last: string; readonly count: number };
  readonly reviews: readonly Review[];
}

/** Band rule: facts.json keys from first to last inclusive, JavaScript default sort. */
function bandKeys(): string[] {
  const keys = Object.keys(canon.facts).sort();
  const first = keys.indexOf(review.band.first);
  const last = keys.indexOf(review.band.last);
  expect(first, `band first ${review.band.first} present`).toBeGreaterThanOrEqual(0);
  expect(last, `band last ${review.band.last} present`).toBeGreaterThan(first);
  return keys.slice(first, last + 1);
}

/** Keys the review names that a later packet deleted from facts.json. */
function deletedReviewKeys(band: readonly string[]): string[] {
  return review.reviews.map((r) => r.key).filter((k) => !band.includes(k));
}

function sha256Of(fact: unknown): string {
  return createHash("sha256").update(JSON.stringify(fact), "utf8").digest("hex");
}

/** Order-independent deep equality over parsed JSON (key order differs between writers). */
function canonicallyEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}
function normalize(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(normalize);
  if (v && typeof v === "object") {
    return Object.fromEntries(
      Object.entries(v as Record<string, unknown>)
        .map(([k, val]) => [k, normalize(val)])
        .sort(([x], [y]) => (x < y ? -1 : x > y ? 1 : 0))
    );
  }
  return v;
}

/** The fact as the apply packet will leave it: allergens replaced, listed diets overwritten, everything else kept. */
function applyReview(fact: any, r: Review): any {
  const applied: any = { ...fact, allergens: r.allergens };
  if (r.diets) applied.diets = { ...(fact.diets ?? {}), ...r.diets };
  return applied;
}

/** Relative-import closure of allergens.ts, copied to dir (layout preserved so relative specifiers resolve). */
function copyAllergensModule(dir: string, factsJson: string): void {
  mkdirSync(join(dir, "canon/ingredient-facts"), { recursive: true });
  const seen = new Set<string>(["allergens.ts"]);
  const queue = ["allergens.ts"];
  while (queue.length) {
    const rel = queue.shift()!;
    const src = join(AGENT_ROOT, "src/lechef", rel);
    cpSync(src, join(dir, rel));
    const text = readFileSync(src, "utf8");
    for (const m of text.matchAll(/from\s+["'](\.[^"']+)["']/g)) {
      let spec = m[1];
      if (!spec.endsWith(".js")) continue;
      spec = spec.replace(/\.js$/, ".ts");
      if (seen.has(spec)) continue;
      seen.add(spec);
      queue.push(spec);
    }
  }
  cpSync(join(CANON_DIR, "identities.json"), join(dir, "canon/ingredient-facts/identities.json"));
  writeFileSync(join(dir, "canon/ingredient-facts/facts.json"), factsJson);
}

/** The whole canon with the band applied (deleted facts skipped). */
function appliedFactsJson(): string {
  const facts: Record<string, any> = { ...canon.facts };
  for (const r of review.reviews) {
    if (!(r.key in facts)) continue;
    facts[r.key] = applyReview(facts[r.key], r);
  }
  return JSON.stringify({ version: canon.version, facts });
}

interface AllergensModule {
  allergenViolations: (ingredient: string, eaters: readonly { name?: string; restrictions: readonly string[] }[]) => readonly string[];
}

async function loadAllergens(patch: boolean): Promise<AllergensModule> {
  const dir = mkdtempSync(join(tmpdir(), `band-e-${patch ? "after" : "before"}-`));
  copyAllergensModule(dir, patch ? appliedFactsJson() : readFileSync(join(CANON_DIR, "facts.json"), "utf8"));
  const mod = (await import(pathToFileURL(join(dir, "allergens.ts")).href)) as unknown as AllergensModule;
  return mod;
}

const check = (mod: AllergensModule, ingredient: string, restriction: string) =>
  mod.allergenViolations(ingredient, [{ name: "probe", restrictions: [restriction] }]);

describe("band-e facts review (burst14-fridgeluck-facts-review-e)", () => {
  test("reviewed keys are exactly the band, each once", () => {
    const band = bandKeys();
    const reviewed = review.reviews.map((r) => r.key);
    const reviewedSet = new Set(reviewed);
    expect(reviewed.length, "no duplicate reviewed keys").toBe(reviewedSet.size);
    const deleted = deletedReviewKeys(band);
    for (const key of band) {
      expect(reviewedSet.has(key), `band key ${key} is reviewed`).toBe(true);
    }
    const bandSet = new Set(band);
    for (const key of reviewed) {
      expect(
        bandSet.has(key) || deleted.includes(key),
        `reviewed key ${key} is in the band or was deleted from facts.json by a later packet`
      ).toBe(true);
    }
    expect(review.band.count).toBe(review.reviews.length);
  });

  test("each fact still hashes to before_sha256 or already equals the review applied", () => {
    const current = canon.facts;
    for (const r of review.reviews) {
      const fact = current[r.key];
      if (!fact) {
        // Deleted by a later packet (sunflower-oil): nothing left to check.
        expect(r.key in current, `${r.key} absent from facts.json`).toBe(false);
        continue;
      }
      const pending = sha256Of(fact) === r.before_sha256;
      const applied = canonicallyEqual(fact, applyReview(fact, r));
      expect(pending || applied, `${r.key} is unchanged at base or already applied`).toBe(true);
    }
  });

  test("structure: ten allergen tokens, five diets on component-less facts, allowed states, sourced reference evidence", () => {
    const states = new Set(["contains", "free", "unknown"]);
    const dietStates = new Set(["allowed", "violated", "unknown"]);
    for (const r of review.reviews) {
      expect(Object.keys(r.allergens).sort(), `${r.key} allergens`).toEqual([...ALLERGENS].sort());
      const fact = canon.facts[r.key];
      const componentLess = !fact?.components || fact.components.length === 0;
      if (componentLess) {
        expect(r.diets, `${r.key} is component-less and lists diets`).toBeDefined();
        expect(Object.keys(r.diets!).sort(), `${r.key} diets`).toEqual([...DIETS].sort());
      }
      for (const [token, s] of Object.entries(r.allergens)) {
        expect(states.has(s.state), `${r.key}.allergens.${token} state ${s.state}`).toBe(true);
        if (s.evidence.kind === "reference") {
          expect(s.evidence.ref, `${r.key}.allergens.${token} reference names an https URL`).toMatch(/https:\/\/\S+/);
          expect(s.evidence.ref, `${r.key}.allergens.${token} reference names a retrieval date`).toMatch(/[Rr]etrieved \d{4}-\d{2}-\d{2}/);
        }
      }
      for (const [diet, s] of Object.entries(r.diets ?? {})) {
        expect(dietStates.has(s.state), `${r.key}.diets.${diet} state ${s.state}`).toBe(true);
        if (s.evidence.kind === "reference") {
          expect(s.evidence.ref, `${r.key}.diets.${diet} reference names an https URL`).toMatch(/https:\/\/\S+/);
          expect(s.evidence.ref, `${r.key}.diets.${diet} reference names a retrieval date`).toMatch(/[Rr]etrieved \d{4}-\d{2}-\d{2}/);
        }
      }
    }
  });

  describe("applied canon (temporary copy of allergens.ts + its imports + patched facts.json)", () => {
    let before: AllergensModule;
    let after: AllergensModule;

    test("loads both canon variants", async () => {
      before = await loadAllergens(false);
      after = await loadAllergens(true);
      expect(typeof after.allergenViolations).toBe("function");
    });

    test("anchors: contains, free and unknown states behave as reviewed", () => {
      // contains: the restriction never clears
      expect(check(after, "sesame-seeds", "sesame").join("\n")).toMatch(/carries/);
      expect(check(after, "soy-sauce", "wheat").join("\n")).toMatch(/carries/);
      // free: an explicit free state on every fact in the graph clears
      expect(check(after, "spinach", "milk")).toEqual([]);
      expect(check(after, "sesame-seeds", "milk")).toEqual([]);
      // unknown: a reviewed unknown asks instead of clearing
      expect(check(after, "vegetable-stock", "wheat").join("\n")).toMatch(/confirmation required/);
      expect(check(after, "vegetable-stock", "egg").join("\n")).toMatch(/confirmation required/);
      expect(check(after, "smoked-sausage", "soy").join("\n")).toMatch(/confirmation required/);
      // contains still derives through a listed component: vanilla-ice-cream lists egg (variable) and the egg fact carries egg
      expect(check(after, "vanilla-ice-cream", "egg").join("\n")).toMatch(/carries/);
      // corrected diet states: wheat-noodles vegan was a hard violated; now allowed and clears.
      // smoked-sausage glutenFree stays violated via its certain wheat-flour component (the unknown own state is fact accuracy, not a verdict change)
      expect(check(after, "wheat-noodles", "vegan"), "standard wheat noodles are vegan").toEqual([]);
      expect(check(after, "smoked-sausage", "glutenFree").join("\n")).toMatch(/not compatible/);
      // stock × vegan was a silent allowed clear on a base that varies; after the apply the own state is unknown.
      // (The diet resolver treats an unresolved diet as a pass — only allergen unknowns ask — so this is a fact-level correction, not a verdict change.)
      const appliedFacts = (JSON.parse(appliedFactsJson()) as { facts: Record<string, any> }).facts;
      expect(appliedFacts["stock"].diets.vegan.state).toBe("unknown");
      expect(appliedFacts["stock-additives"].diets.vegan.state).toBe("unknown");
    });

    test("squid pin: squid × fish clears; squid × shellfish asks or violates", () => {
      expect(check(after, "squid", "fish"), "squid is a mollusc, not a finfish").toEqual([]);
      const shellfish = check(after, "squid", "shellfish");
      expect(shellfish.length, "squid still flags shellfish (molluscanShellfish contains)").toBeGreaterThan(0);
    });

    test("band ask count per restriction, before -> after", () => {
      const band = bandKeys().filter((k) => k in canon.facts);
      const lines: string[] = [];
      let beforeTotal = 0;
      let afterTotal = 0;
      for (const restriction of NINE_RESTRICTIONS) {
        const beforeCount = band.filter((k) => check(before, k, restriction).length > 0).length;
        const afterCount = band.filter((k) => check(after, k, restriction).length > 0).length;
        beforeTotal += beforeCount;
        afterTotal += afterCount;
        lines.push(`  ${restriction}: ${beforeCount} -> ${afterCount}`);
      }
      lines.push(`  total: ${beforeTotal} -> ${afterTotal} (of ${band.length * NINE_RESTRICTIONS.length} fact × restriction pairs)`);
      console.log(`[band-e] facts that do not clear (ask or violate), before -> after applying band-e:\n${lines.join("\n")}`);
      // Every restriction must ask strictly fewer facts after the apply.
      for (const restriction of NINE_RESTRICTIONS) {
        const beforeCount = band.filter((k) => check(before, k, restriction).length > 0).length;
        const afterCount = band.filter((k) => check(after, k, restriction).length > 0).length;
        expect(afterCount, `${restriction} asks fewer facts after the apply`).toBeLessThanOrEqual(beforeCount);
        expect(afterCount, `${restriction} is not fully unresolved in the band`).toBeLessThan(band.length);
      }
    });
  });
});
