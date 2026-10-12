/**
 * Unknown composition fails closed, and legacy allergen tags are unknown,
 * not clean (PR #104 review blocker 3, round three).
 *
 * Before the fix, a derived seam turned a missing axis into an empty known
 * set: barley and beef stock came out "allergen-free" because their
 * unreviewed allergen axes were dropped, and the gluten and diet axes were
 * lost entirely. The backend now loads the PUBLISHED FLIngredientFacts
 * dataset byte-for-byte (vendored under data/ingredient-facts/) and mirrors
 * its conformance evaluator:
 *
 *   - a missing axis stays UNKNOWN — never an empty known set;
 *   - UNKNOWN blocks every free-from claim AND every diet claim;
 *   - barley carries its gluten fact; beef stock carries its diet facts;
 *   - an ingredient surfaces as covered only when every axis in the tag
 *     namespace is reviewed in the published data;
 *   - the vendored conformance cases replay against the ported evaluator;
 *   - a drifted vendored copy never loads (its provenance pins fail).
 *
 * Likewise, a record without stored allergen tags reads as `null` — unknown
 * — so compound-allergen checks and approval cannot clear vacuously for
 * records the current gate never tagged.
 */
import { describe, expect, test } from "bun:test";
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { DocumentSnapshot } from "@google-cloud/firestore";
import { evaluateIngredient, loadFoodSafetyCatalog, type AllergenAxis, type DietAxis, type FoodSafetyCatalog } from "../../community/foodSafety/catalog.js";
import { compoundAllergenStage, deriveAllergenTagging } from "../../community/foodSafety/gate.js";
import { approvalRefusal, contentHashOf, parsePublicationDoc, screenablePublicationOf, type PublicationRecord } from "../../community/explore/publications.js";
import { FOOD_SAFETY_FIXTURE_DIR } from "./foodSafetyGate.js";

/** The vendored published package at the repo root, resolved from this file's location. */
const VENDORED_DIR = fileURLToPath(new URL("../../../data/ingredient-facts/", import.meta.url));
const VENDORED_FACTS_PATH = `${VENDORED_DIR}facts.json`;

function loadVendoredCatalog(): FoodSafetyCatalog {
  const catalog = loadFoodSafetyCatalog({
    canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
    facts: VENDORED_FACTS_PATH,
  });
  if (!catalog.loaded) {
    throw new Error(`vendored catalog did not load: ${catalog.reason}`);
  }
  return catalog;
}

function loadFixtureCatalog(): FoodSafetyCatalog {
  const catalog = loadFoodSafetyCatalog({
    canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
    facts: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts/facts.json`,
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

describe("the vendored published dataset loads as published (blocker 3, round three)", () => {
  const catalog = loadVendoredCatalog();

  test("the vendored package loads with its provenance pins verified", () => {
    expect(catalog.facts.schema).toBe("fridgeluck/ingredient-facts@v2");
    expect(catalog.facts.provenance.sourceBranch).toBe("overhaul/ingredient-facts");
    expect(catalog.facts.provenance.sourceCommit).toBe("b0deecce36bf6ee91e6f5933e746d75466165288");
    const paths = catalog.facts.provenance.files.map((f) => f.path);
    expect(paths).toContain("facts.json");
    expect(paths).toContain("identities.json");
    expect(paths).toContain("conformance/cases.json");
    for (const file of catalog.facts.provenance.files) {
      expect(file.sha256).toMatch(/^sha256:[0-9a-f]{64}$/);
    }
    // The projection surfaces the ingredients the published data fully reviews.
    expect(catalog.facts.ingredients.length).toBeGreaterThanOrEqual(36);
    const ids = catalog.facts.ingredients.map((entry) => entry.id);
    expect(ids).toContain("soy-sauce");
  });

  test("a missing axis never becomes a covered ingredient", () => {
    const ids = catalog.facts.ingredients.map((entry) => entry.id);
    // Published truth: barley, beef stock and rice carry no reviewed allergen
    // axes, and tamari's gluten axis is unknown — none may surface as a
    // covered ingredient with an (empty) known set.
    for (const absent of ["barley", "beef-stock", "rice", "tamari"]) {
      expect(ids).not.toContain(absent);
    }
  });

  test("the gate-facing projection carries compound allergens (soy sauce: soy + wheat + gluten)", () => {
    const soySauce = catalog.facts.ingredients.find((entry) => entry.id === "soy-sauce");
    expect(soySauce).toBeDefined();
    expect(soySauce?.allergens).toContain("soy");
    expect(soySauce?.allergens).toContain("wheat");
    expect(soySauce?.allergens).toContain("gluten");
  });
});

describe("the published facts block unknown on every claim path (blocker 3, round three)", () => {
  const catalog = loadVendoredCatalog();
  const dataset = catalog.facts.dataset;

  test("barley carries its gluten fact and a violated gluten-free diet fact", () => {
    const barley = dataset.facts["barley"];
    expect(barley).toBeDefined();
    expect(barley?.gluten?.state).toBe("contains");
    expect(barley?.diets?.glutenFree?.state).toBe("violated");
  });

  test("beef stock carries its violated diet facts while its allergen axes stay missing", () => {
    const stock = dataset.facts["beef-stock"];
    expect(stock).toBeDefined();
    expect(stock?.allergens).toBeUndefined();
    expect(stock?.diets?.vegetarian?.state).toBe("violated");
    expect(stock?.diets?.vegan?.state).toBe("violated");
    expect(stock?.diets?.pescatarian?.state).toBe("violated");
  });

  test("a missing axis stays unknown — never an empty known set", () => {
    for (const name of ["barley", "pearl barley", "beef stock", "beef broth"]) {
      const evaluation = evaluateIngredient(dataset, name, { allergens: new Set(["soy"] as AllergenAxis[]), diets: new Set() });
      expect(evaluation.result).toBe("unknown");
      if (evaluation.result === "unknown") {
        expect(evaluation.unknown.missing.join(" ").toLowerCase()).toContain("unknown");
      }
    }
  });

  test("an unknown axis blocks the free-from claim at the gate (barley salad)", async () => {
    const stage = compoundAllergenStage(catalog.facts, catalog.rulebook);
    const verdict = await stage.run(screenable({
      title: "Totally gluten free barley salad",
      ingredientLines: ["1 cup pearl barley"],
    }));
    expect(verdict.outcome).toBe("fail");
    const reasons = verdict.outcome === "fail" ? verdict.reasons : [];
    expect(reasons.some((r) => r.includes("1 cup pearl barley") && r.includes("unknown"))).toBe(true);
  });

  test("an unknown axis blocks the diet claim (tamari gluten-free status)", () => {
    const evaluation = evaluateIngredient(dataset, "tamari", { allergens: new Set(), diets: new Set(["glutenFree"] as DietAxis[]) });
    expect(evaluation.result).toBe("unknown");
  });

  test("a reviewed violated diet fact blocks the diet claim (barley is not gluten-free)", () => {
    const evaluation = evaluateIngredient(dataset, "barley", { allergens: new Set(), diets: new Set(["glutenFree"] as DietAxis[]) });
    expect(evaluation.result).toBe("violated");
    if (evaluation.result === "violated") {
      expect(evaluation.violation.reason.toLowerCase()).toContain("glutenfree");
    }
  });
});

describe("the vendored conformance cases replay against the ported evaluator (blocker 3)", () => {
  const catalog = loadVendoredCatalog();
  const cases = (JSON.parse(readFileSync(join(VENDORED_DIR, "conformance", "cases.json"), "utf8")) as {
    cases: Array<{
      id: string;
      ingredient: string;
      restrictions: { allergens?: string[]; diets?: string[] };
      expected: { result: string; reasonContains?: string[]; missingMention?: string[]; evidenceMention?: string[] };
    }>;
  })["cases"];

  test("every published case reproduces its expected evaluation", () => {
    expect(cases.length).toBeGreaterThanOrEqual(40);
    const failures: string[] = [];
    for (const c of cases) {
      const restrictions = {
        allergens: new Set((c.restrictions.allergens ?? []) as AllergenAxis[]),
        diets: new Set((c.restrictions.diets ?? []) as DietAxis[]),
      };
      const evaluation = evaluateIngredient(catalog.facts.dataset, c.ingredient, restrictions);
      const expected = c.expected;
      if (expected.result === "violated") {
        if (evaluation.result !== "violated") {
          failures.push(`${c.id}: expected violated, got ${evaluation.result}`);
          continue;
        }
        for (const needle of expected.reasonContains ?? []) {
          if (!evaluation.violation.reason.toLowerCase().includes(needle.toLowerCase())) {
            failures.push(`${c.id}: reason '${evaluation.violation.reason}' does not mention '${needle}'`);
          }
        }
      } else if (expected.result === "unknown") {
        if (evaluation.result !== "unknown") {
          failures.push(`${c.id}: expected unknown, got ${evaluation.result}`);
          continue;
        }
        const missing = evaluation.unknown.missing.join(" ; ").toLowerCase();
        for (const needle of expected.missingMention ?? []) {
          if (!missing.includes(needle.toLowerCase())) {
            failures.push(`${c.id}: missing '${missing}' does not mention '${needle}'`);
          }
        }
      } else if (expected.result === "allowed") {
        if (evaluation.result !== "allowed") {
          const detail = evaluation.result === "unknown" ? ` (${evaluation.unknown.missing.join("; ")})` : "";
          failures.push(`${c.id}: expected allowed, got ${evaluation.result}${detail}`);
          continue;
        }
        const evidence = evaluation.evidence.map((e) => `${e.kind} ${e.ref} ${e.note}`).join(" ").toLowerCase();
        for (const needle of expected.evidenceMention ?? []) {
          if (!evidence.includes(needle.toLowerCase())) {
            failures.push(`${c.id}: evidence '${evidence}' does not mention '${needle}'`);
          }
        }
      } else {
        failures.push(`${c.id}: unknown expected result '${expected.result}'`);
      }
    }
    expect(failures).toEqual([]);
  });
});

describe("a drifted vendored copy never loads (blocker 3)", () => {
  test("a one-byte change to a vendored file fails its pin", () => {
    const dir = mkdtempSync(join(tmpdir(), "fl-b3-drift-"));
    try {
      cpSync(VENDORED_DIR, dir, { recursive: true });
      const factsPath = join(dir, "facts.json");
      appendFileSync(factsPath, " ", "utf8");
      const catalog = loadFoodSafetyCatalog({ canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`, facts: factsPath });
      expect(catalog.loaded).toBe(false);
      if (!catalog.loaded) {
        expect(catalog.reason).toContain("does not match the pinned");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a vendored package missing a pinned file does not load", () => {
    const dir = mkdtempSync(join(tmpdir(), "fl-b3-missing-"));
    try {
      cpSync(VENDORED_DIR, dir, { recursive: true });
      rmSync(join(dir, "identities.json"));
      const catalog = loadFoodSafetyCatalog({ canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`, facts: join(dir, "facts.json") });
      expect(catalog.loaded).toBe(false);
      if (!catalog.loaded) {
        expect(catalog.reason).toContain("vendored identities.json is missing");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

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

  test("covered composition tags exactly as published (soy sauce: soy, wheat, gluten)", () => {
    const { tags, unknownLines } = deriveAllergenTagging(catalog.facts, ["200 g rice", "2 tbsp soy sauce", "1 tbsp tahini"]);
    expect(unknownLines).toEqual([]);
    expect(tags).toEqual(["allergen-gluten", "allergen-sesame", "allergen-soy", "allergen-wheat"]);
  });

  test("an ingredient whose gluten axis is unknown fails the stage even though its other allergens are reviewed", async () => {
    // Tamari: soy reviewed, gluten unknown — the line must stay uncovered.
    const { tags, unknownLines } = deriveAllergenTagging(catalog.facts, ["3 tbsp tamari"]);
    expect(unknownLines).toEqual(["3 tbsp tamari"]);
    expect(tags).toEqual([]);
    const verdict = await stage.run(screenable({ ingredientLines: ["3 tbsp tamari"] }));
    expect(verdict.outcome).toBe("fail");
  });

  test("a covered claim contradiction still fails as before — the fail-closed default is not weakened", async () => {
    const verdict = await stage.run(screenable({
      title: "Totally gluten free noodles",
      ingredientLines: ["200 g rice noodles", "2 tbsp soy sauce"],
    }));
    expect(verdict.outcome).toBe("fail");
    const reasons = verdict.outcome === "fail" ? verdict.reasons : [];
    expect(reasons.some((r) => r.includes("gluten"))).toBe(true);
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
