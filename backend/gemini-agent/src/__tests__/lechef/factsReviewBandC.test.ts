/**
 * Review-packet test for the band-c ingredient-facts review
 * (src/lechef/canon/ingredient-facts/review/band-c.json).
 *
 * Asserts the review file is well-formed and pinned to the band's keys, that
 * every reviewed fact either still matches its recorded before_sha256 or has
 * already had the review applied (so the test stays green after
 * burst14-fridgeluck-facts-apply runs), and — by applying the band to a
 * temporary copy of the real lookup (allergens.ts, its imports, and the canon)
 * — that anchors hold and the band's confirmation asks drop.
 */

import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const agentRoot = resolve(here, "../../..");
const canonDir = join(agentRoot, "src/lechef/canon/ingredient-facts");
const factsPath = join(canonDir, "facts.json");
const reviewPath = join(canonDir, "review/band-c.json");

const canon = JSON.parse(readFileSync(factsPath, "utf8")) as {
  facts: Record<string, Record<string, unknown>>;
};
const review = JSON.parse(readFileSync(reviewPath, "utf8")) as {
  schema: string;
  packet: string;
  base_commit: string;
  band: { first: string; last: string; count: number };
  reviews: ReviewEntry[];
};

interface Evidence {
  kind: string;
  ref: string;
  note: string;
}
interface ReviewEntry {
  key: string;
  before_sha256: string;
  allergens: Record<string, { state: string; evidence: Evidence }>;
  diets?: Record<string, { state: string; evidence: Evidence }>;
  changes?: { path: string; from: string; to: string; reason: string; evidence: string }[];
}

const TOKENS = ["milk", "egg", "fish", "crustaceanShellfish", "molluscanShellfish", "treeNuts", "peanuts", "wheat", "soy", "sesame"];
const DIETS = ["vegan", "vegetarian", "pescatarian", "dairyFree", "glutenFree"];
const RESTRICTIONS = ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"];

/** The band rule: facts.json keys from gnocchi to mustard inclusive, default string sort. */
const bandKeys = Object.keys(canon.facts).sort().filter((k) => k >= "gnocchi" && k <= "mustard");

const sha256 = (fact: unknown): string =>
  createHash("sha256").update(JSON.stringify(fact), "utf8").digest("hex");

/** Apply a review entry the way burst14-fridgeluck-facts-apply does: replace allergens, overwrite listed diets. */
function applyReview(fact: Record<string, unknown>, entry: ReviewEntry): Record<string, unknown> {
  return {
    ...fact,
    allergens: entry.allergens,
    diets: { ...((fact.diets as object) ?? {}), ...(entry.diets ?? {}) },
  };
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null) return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === "object") {
    const ka = Object.keys(a as object);
    const kb = Object.keys(b as object);
    if (ka.length !== kb.length) return false;
    return ka.every((k) => deepEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
  }
  return false;
}

function expectSourced(evidence: Evidence): void {
  expect(["standard", "reference"]).toContain(evidence.kind);
  expect(evidence.ref.length).toBeGreaterThan(0);
  expect(evidence.note.length).toBeGreaterThan(0);
  if (evidence.kind === "reference") {
    expect(evidence.ref).toMatch(/https:\/\/\S+/);
    expect(`${evidence.ref} ${evidence.note}`).toMatch(/retrieved \d{4}-\d{2}-\d{2}/);
  }
}

interface AllergensModule {
  allergenViolations: (ingredient: string, eaters: readonly { name?: string; restrictions: readonly string[] }[]) => readonly string[];
}

/** Copy the real lookup — allergens.ts, every module it imports, and the canon — into a temp tree. */
async function makeTempLookup(patchedFacts: object): Promise<AllergensModule> {
  const tmp = mkdtempSync(join(tmpdir(), "fridgeluck-band-c-"));
  const lechef = join(tmp, "src/lechef");
  mkdirSync(join(lechef, "canon"), { recursive: true });
  cpSync(join(agentRoot, "src/lechef/allergens.ts"), join(lechef, "allergens.ts"));
  const typesTs = join(agentRoot, "src/lechef/types.ts");
  if (existsSync(typesTs)) cpSync(typesTs, join(lechef, "types.ts"));
  cpSync(canonDir, join(lechef, "canon/ingredient-facts"), { recursive: true });
  if (patchedFacts) {
    writeFileSync(join(lechef, "canon/ingredient-facts/facts.json"), JSON.stringify(patchedFacts));
  }
  const mod = (await import(join(lechef, "allergens.ts"))) as unknown as AllergensModule;
  return mod;
}

const eater = (restrictions: string[]) => [{ name: "cook", restrictions }];
const asks = (mod: AllergensModule, keys: readonly string[]): Record<string, number> => {
  const per: Record<string, number> = {};
  let total = 0;
  for (const restriction of RESTRICTIONS) {
    per[restriction] = keys.filter((key) =>
      mod.allergenViolations(key, eater([restriction])).some((m) => m.includes("confirmation required"))
    ).length;
    total += per[restriction];
  }
  per.total = total;
  return per;
};

describe("facts review band c (gnocchi..mustard)", () => {
  test("review header is pinned to this packet and band", () => {
    expect(review.schema).toBe("fridgeluck/facts-review/v1");
    expect(review.packet).toBe("burst14-fridgeluck-facts-review-c");
    expect(review.band.first).toBe("gnocchi");
    expect(review.band.last).toBe("mustard");
    expect(review.band.count).toBe(bandKeys.length);
  });

  test("reviewed keys are exactly the band's keys, each once", () => {
    const seen = new Set<string>();
    for (const entry of review.reviews) {
      expect(seen.has(entry.key)).toBe(false);
      seen.add(entry.key);
    }
    expect([...seen].sort()).toEqual(bandKeys);
  });

  test("every review has all ten allergen states in vocabulary, sourced; singles have all five diets", () => {
    for (const entry of review.reviews) {
      for (const token of TOKENS) {
        const state = entry.allergens[token];
        expect(state).toBeDefined();
        expect(["contains", "free", "unknown"]).toContain(state.state);
        expectSourced(state.evidence);
      }
      const fact = canon.facts[entry.key];
      if (!fact.components) {
        for (const diet of DIETS) {
          const state = entry.diets?.[diet];
          expect(state).toBeDefined();
          expect(["allowed", "violated", "unknown"]).toContain(state!.state);
          expectSourced(state!.evidence);
        }
      }
      for (const change of entry.changes ?? []) {
        expect(change.reason.length).toBeGreaterThan(0);
        expect(change.evidence.length).toBeGreaterThan(0);
      }
    }
  });

  test("each fact either still hashes to before_sha256 or already has the review applied", () => {
    for (const entry of review.reviews) {
      const fact = canon.facts[entry.key];
      expect(fact).toBeDefined();
      if (sha256(fact) === entry.before_sha256) continue;
      expect(deepEqual(fact, applyReview(fact, entry))).toBe(true);
    }
  });

  test("applied band: anchors hold and confirmation asks drop", async () => {
    const before = (await import(join(agentRoot, "src/lechef/allergens.ts"))) as unknown as AllergensModule;
    const patched = { ...canon, facts: { ...canon.facts } };
    for (const entry of review.reviews) {
      patched.facts[entry.key] = applyReview(patched.facts[entry.key], entry);
    }
    const after = await makeTempLookup(patched);

    // contains: a mollusc fact hard-violates the app's shellfish restriction.
    expect(after.allergenViolations("mussel", eater(["shellfish"])).some((m) => m.includes("carries"))).toBe(true);
    // contains through composition: gnocchi's wheat still flows from its wheat-flour component
    // even though the compound's own state is now unknown.
    expect(after.allergenViolations("gnocchi", eater(["wheat"])).some((m) => m.includes("carries"))).toBe(true);
    // free: grapes ask about shellfish before the band (no molluscanShellfish state) and clear after.
    expect(before.allergenViolations("grapes", eater(["shellfish"])).some((m) => m.includes("confirmation required"))).toBe(true);
    expect(after.allergenViolations("grapes", eater(["shellfish"]))).toEqual([]);
    // unknown: the hydrolysed-plant-protein source plant varies by brand, so it still asks.
    expect(
      after.allergenViolations("hydrolysed-plant-protein", eater(["soy"])).some((m) => m.includes("confirmation required"))
    ).toBe(true);

    const beforeCounts = asks(before, bandKeys);
    const afterCounts = asks(after, bandKeys);
    console.log("[facts-review band c] asks before:", JSON.stringify(beforeCounts));
    console.log("[facts-review band c] asks after:", JSON.stringify(afterCounts));
    expect(afterCounts.total).toBeLessThan(beforeCounts.total);
  });
});
