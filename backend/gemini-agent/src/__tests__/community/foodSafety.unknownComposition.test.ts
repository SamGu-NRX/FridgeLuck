/**
 * Unknown composition fails closed, and legacy allergen tags are unknown,
 * not clean (PR #104 review blocker 3).
 *
 * Before the fix, an ingredient line the loaded facts did not cover fell
 * through the compound-allergen stage as if it carried no allergens — an
 * unknown composition was silently treated as allowed, and any allergen-free
 * claim over it passed vacuously. Likewise, a legacy record without stored
 * allergen tags read as `[]` — clean — so compound-allergen checks cleared
 * vacuously for records the gate never tagged.
 *
 * Now: an uncovered line FAILS the stage with the line cited verbatim; no
 * allergen-free claim can be supported over unknown composition; a known-free
 * ingredient (reviewed, empty allergen list) still passes; and a record with
 * unknown tags cannot be approved — it must be re-screened by the current
 * gate. The runtime-derived seam (data/food-safety/ingredient-facts.json,
 * derived from overhaul/ingredient-facts) is proven to load under the same
 * provenance + hash discipline blocker 2 gave the rulebook.
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { DocumentSnapshot } from "@google-cloud/firestore";
import { loadFoodSafetyCatalog, type FoodSafetyCatalog } from "../../community/foodSafety/catalog.js";
import { compoundAllergenStage, deriveAllergenTagging } from "../../community/foodSafety/gate.js";
import { approvalRefusal, contentHashOf, parsePublicationDoc, screenablePublicationOf, type PublicationRecord } from "../../community/explore/publications.js";
import { FOOD_SAFETY_FIXTURE_DIR } from "./foodSafetyGate.js";

/** The runtime seam at the repo root, resolved from this file's location. */
const RUNTIME_FACTS_PATH = fileURLToPath(new URL("../../../data/food-safety/ingredient-facts.json", import.meta.url));

function loadFixtureCatalog(): FoodSafetyCatalog {
  const catalog = loadFoodSafetyCatalog({
    canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
    facts: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`,
  });
  if (!catalog.loaded) {
    throw new Error(`fixture catalog did not load: ${catalog.reason}`);
  }
  return catalog;
}

function screenable(overrides: Partial<{ title: string; summary: string | null; ingredientLines: string[]; steps: string[] }> = {}) {
  return {
    title: "Test stew",
    summary: null,
    ingredientLines: ["200 g rice", "2 tbsp soy sauce"],
    steps: ["Cook it."],
    ...overrides,
  };
}

describe("unknown composition fails closed (blocker 3)", () => {
  const catalog = loadFixtureCatalog();
  const stage = compoundAllergenStage(catalog.facts, catalog.rulebook);

  test("an ingredient unrecognized by the loaded facts fails the stage, cited verbatim — not silently allowed", async () => {
    const verdict = await stage.run(screenable({ ingredientLines: ["200 g rice", "1 cup flurb"] }));
    expect(verdict.outcome).toBe("fail");
    expect(verdict.stage).toBe("compound-allergens");
    const reasons = verdict.outcome === "fail" ? verdict.reasons : [];
    expect(reasons.some((r) => r.includes("ingredient line 2") && r.includes("1 cup flurb") && r.includes("unknown"))).toBe(true);
  });

  test("an allergen-free claim cannot be supported while composition is unknown", async () => {
    const verdict = await stage.run(screenable({
      title: "Totally gluten free flurb bowl",
      ingredientLines: ["1 cup flurb"],
    }));
    expect(verdict.outcome).toBe("fail");
    const reasons = verdict.outcome === "fail" ? verdict.reasons : [];
    expect(reasons.some((r) => r.includes("1 cup flurb") && r.includes("fail closed"))).toBe(true);
  });

  test("a known-free ingredient (reviewed, empty allergen list) still passes unchanged — no over-blocking", async () => {
    const verdict = await stage.run(screenable({ ingredientLines: ["200 g rice", "1 cucumber"] }));
    expect(verdict.outcome).toBe("pass");
    expect(verdict.outcome === "pass" && verdict.tags).toEqual([]);
  });

  test("covered composition tags exactly as before the fix", () => {
    const { tags, unknownLines } = deriveAllergenTagging(catalog.facts, ["200 g rice", "2 tbsp soy sauce", "1 tbsp tahini"]);
    expect(unknownLines).toEqual([]);
    expect(tags).toEqual(["allergen-sesame", "allergen-soy", "allergen-wheat-gluten"]);
  });

  test("a covered claim contradiction still fails as before — the fail-closed default is not weakened", async () => {
    const verdict = await stage.run(screenable({
      title: "Totally gluten free noodles",
      ingredientLines: ["200 g rice noodles", "2 tbsp soy sauce"],
    }));
    expect(verdict.outcome).toBe("fail");
    const reasons = verdict.outcome === "fail" ? verdict.reasons : [];
    expect(reasons.some((r) => r.includes("wheat-gluten"))).toBe(true);
  });
});

describe("legacy allergen tags are unknown, not clean (blocker 3)", () => {
  /** A full pre-gate document, with `allergenTags` omitted by default. */
  function docFixture(withTags: boolean): DocumentSnapshot {
    const data: Record<string, unknown> = {
      revisionId: "rev_legacy_1",
      authorId: "acc_legacy",
      sourceRecipeId: "recipes/legacy",
      sourceRecipeRevision: "rev-000001",
      title: "Legacy stew",
      summary: null,
      note: null,
      ingredientLines: ["300 g beef"],
      steps: ["Stew it."],
      tags: [],
      campus: "legacy",
      status: "queued",
      screeningFailures: [],
      createdAtIso: "2026-10-12T00:00:00.000Z",
      publishedAtIso: null,
      withdrawnAtIso: null,
      rejectedAtIso: null,
      optedInCooks: {},
    };
    if (withTags) {
      data["allergenTags"] = [];
    }
    return { exists: true, id: "pub_legacy_1", data: () => data } as unknown as DocumentSnapshot;
  }

  test("a record with no allergenTags field reads as UNKNOWN (null), never as an empty-clean list", () => {
    const record = parsePublicationDoc(docFixture(false));
    expect(record).not.toBeNull();
    expect(record?.allergenTags).toBeNull();
  });

  test("a record with a present (empty) allergenTags list still reads as that list", () => {
    const record = parsePublicationDoc(docFixture(true));
    expect(record?.allergenTags).toEqual([]);
  });
});

describe("approval refuses unknown allergen tags (blocker 3)", () => {
  function recordFixture(overrides: Partial<PublicationRecord> = {}): PublicationRecord {
    const base: PublicationRecord = {
      publicationId: "pub_b3_fixture" as PublicationRecord["publicationId"],
      revisionId: "rev_b3_fixture" as PublicationRecord["revisionId"],
      authorId: "acc_b3_fixture" as PublicationRecord["authorId"],
      sourceRecipeId: "recipes/b3-fixture",
      sourceRecipeRevision: "rev-000009",
      title: "Fixture stew",
      summary: "A fixture.",
      note: null,
      ingredientLines: ["300 g beef"],
      steps: ["Stew it."],
      tags: [],
      allergenTags: [],
      campus: "b3-fixture",
      status: "queued",
      screeningFailures: [],
      createdAtIso: "2026-10-12T00:00:00.000Z",
      publishedAtIso: null,
      withdrawnAtIso: null,
      rejectedAtIso: null,
      optedInCooks: {},
      screenedEvaluation: null,
    };
    return { ...base, ...overrides };
  }

  function passingEvaluationFor(record: PublicationRecord): NonNullable<PublicationRecord["screenedEvaluation"]> {
    return {
      contentHash: contentHashOf(screenablePublicationOf(record)),
      stages: [
        { name: "text-hygiene", passed: true },
        { name: "food-safety-lint", passed: true },
        { name: "compound-allergens", passed: true },
      ],
    };
  }

  test("a record whose allergen tags are unknown cannot be approved even with a recorded passing evaluation", () => {
    const legacy = recordFixture({ screenedEvaluation: passingEvaluationFor(recordFixture()), allergenTags: null });
    const refusal = approvalRefusal(legacy);
    expect(refusal).not.toBeNull();
    expect(refusal).toContain("compound-allergen tags are unknown");
  });

  test("a record with known (possibly empty) tags and a passing evaluation still approves — no over-blocking", () => {
    const clean = recordFixture({ screenedEvaluation: passingEvaluationFor(recordFixture()) });
    expect(approvalRefusal(clean)).toBeNull();
  });
});

describe("the derived runtime seam loads with verified provenance (blocker 3)", () => {
  test("data/food-safety/ingredient-facts.json validates under the loader's hash recheck", () => {
    // The fixture canon's allergen-claim references use the fixture's
    // vocabulary; map them onto the runtime seam's canonical slugs so the
    // canon is compatible and the FACTS file is what gets proven.
    const canonRaw = JSON.parse(readFileSync(`${FOOD_SAFETY_FIXTURE_DIR}/canon.json`, "utf8")) as { rules: Array<Record<string, unknown>> };
    const slugMap: Record<string, string> = {
      "wheat-gluten": "wheat",
      "tree-nut": "tree-nuts",
      peanut: "peanuts",
      shellfish: "crustacean-shellfish",
    };
    for (const rule of canonRaw.rules) {
      if (rule["kind"] === "allergen-claim" && Array.isArray(rule["claims"])) {
        for (const claim of rule["claims"] as Array<Record<string, unknown>>) {
          if (typeof claim["allergen"] === "string" && slugMap[claim["allergen"]] !== undefined) {
            claim["allergen"] = slugMap[claim["allergen"]];
          }
        }
      }
    }
    const dir = mkdtempSync(join(tmpdir(), "fl-b3-seam-"));
    const canonPath = join(dir, "canon.json");
    writeFileSync(canonPath, JSON.stringify(canonRaw), "utf8");
    try {
      const catalog = loadFoodSafetyCatalog({ canon: canonPath, facts: RUNTIME_FACTS_PATH });
      expect(catalog.loaded).toBe(true);
      if (catalog.loaded) {
        expect(catalog.facts.provenance.sourceBranch).toBe("overhaul/ingredient-facts");
        expect(catalog.facts.ingredients.length).toBeGreaterThan(100);
        // Unknown stays representable: the dataset's unfactored or
        // unknown-axis ingredients must NOT be present as clean entries.
        const ids = catalog.facts.ingredients.map((entry) => entry.id);
        expect(ids).not.toContain("curry-paste");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a drifted runtime facts copy never loads — the provenance hash is rechecked at load", () => {
    const seam = JSON.parse(readFileSync(RUNTIME_FACTS_PATH, "utf8")) as Record<string, unknown>;
    const ingredients = seam["ingredients"] as Array<Record<string, unknown>>;
    // Drop one reviewed allergen: exactly the loosening a drifted copy would
    // smuggle in. The recomputed blob hash no longer matches the provenance.
    const firstTagged = ingredients.find((entry) => Array.isArray(entry["allergens"]) && (entry["allergens"] as string[]).length > 0);
    expect(firstTagged).toBeDefined();
    firstTagged["allergens"] = [];
    const dir = mkdtempSync(join(tmpdir(), "fl-b3-drift-"));
    const driftedPath = join(dir, "ingredient-facts.json");
    writeFileSync(driftedPath, JSON.stringify(seam), "utf8");
    try {
      const catalog = loadFoodSafetyCatalog({ canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`, facts: driftedPath });
      expect(catalog.loaded).toBe(false);
      if (!catalog.loaded) {
        expect(catalog.reason).toContain("ingredient facts");
        expect(catalog.reason).toContain("provenance hash");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
