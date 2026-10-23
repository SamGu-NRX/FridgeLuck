/**
 * The food-safety publish stage as a thin adapter over the vendored canon
 * (PR #104 round 3 rescope). The gate's own heuristics are deleted; the
 * canon's conformance kit (replayed in full by foodSafety.canonConformance
 * .test.ts) pins the linter's semantics. These tests pin the ADAPTER: the
 * publication-to-canon field mapping, refusal on any finding or unknown,
 * hash-verified fail-closed loading, and a regression for each of the five
 * recurring heuristic defects the rescope named — every test derived from a
 * canon conformance case or the named defect.
 */
import { describe, expect, test } from "bun:test";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync, appendFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CopyLint, StepLinter } from "../../community/foodSafety/canonLinter.js";
import { defaultVendoredCanonDir, loadVendoredCanonPackage, type VendoredCanon, type VendoredCanonLoad } from "../../community/foodSafety/canonPackage.js";
import { createFoodSafetyGate, foodSafetyGateFromCatalog, foodSafetyLintStage, type FoodSafetyGate } from "../../community/foodSafety/gate.js";
import { loadFoodSafetyCatalog } from "../../community/foodSafety/catalog.js";
import { FOOD_SAFETY_FIXTURE_DIR } from "./foodSafetyGate.js";

const CANON_DIR = defaultVendoredCanonDir();

function loadedCanon(): VendoredCanon {
  const load = loadVendoredCanonPackage();
  if (!load.loaded) {
    throw new Error(`the vendored canon must load in tests: ${load.reason}`);
  }
  return load.canon;
}

function publication(overrides: Partial<{ title: string; summary: string | null; ingredientLines: readonly string[]; steps: readonly string[] }> = {}): Parameters<ReturnType<typeof foodSafetyLintStage>["run"]>[0] {
  return {
    title: overrides.title ?? "Roast chicken",
    summary: overrides.summary !== undefined ? overrides.summary : null,
    ingredientLines: overrides.ingredientLines ?? ["1 whole chicken, olive oil"],
    steps: overrides.steps ?? ["Insert an instant-read thermometer into the thickest part and cook to 165 °F (74 °C)."],
  };
}

async function verdictFor(overrides: Partial<{ title: string; summary: string | null; ingredientLines: readonly string[]; steps: readonly string[] }>): Promise<{ failed: boolean; reasons: readonly string[] }> {
  const verdict = await foodSafetyLintStage(loadedCanon()).run(publication(overrides));
  return verdict.outcome === "fail" ? { failed: true, reasons: verdict.reasons } : { failed: false, reasons: [] };
}

describe("the adapter maps a publication onto the canon's record model", () => {
  test("a recipe the canon's own true-negative passes passes the stage", async () => {
    // The canon kit's tn-poultry-check-complete, verbatim through the adapter.
    const result = await verdictFor({
      steps: ["Insert an instant-read thermometer into the thickest part and cook to 165 °F (74 °C)."],
    });
    expect(result.failed).toBe(false);
  });

  test("a step split across two publication steps is still evaluated — the checkless cooking step fails closed", async () => {
    // The canon evaluates each numbered step separately: a cooking step
    // without its own check is a finding even when the next step carries
    // one — the check binds to the step, not to the recipe. This also pins
    // that both publication steps reach the linter (numbering them keeps
    // the first from vanishing into prose).
    const result = await verdictFor({
      steps: ["Cook the chicken", "to 165 °F with an instant-read thermometer in the thickest part."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("missingInternalTemperature") && r.includes("step 1"))).toBe(true);
  });

  test("a finding cites the canon rule id and the failing step", async () => {
    // The canon kit's appearance-based-doneness case, through the adapter.
    const result = await verdictFor({
      title: "Crispy chicken thighs",
      ingredientLines: ["4 chicken thighs, oil"],
      steps: ["Roast the chicken thighs until golden and crisp."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("appearanceDoneness") && r.includes("thermometer-only-reliable") && r.includes("step 1"))).toBe(true);
  });

  test("the canon's copy patterns run over the publication's prose fields", async () => {
    // The kit's fish-curing-rescue copy case, as a publication summary.
    const result = await verdictFor({
      title: "Ceviche",
      summary: "The raw salmon is fine — the lime juice effectively cooks the fish and makes it safe to eat.",
      ingredientLines: ["raw salmon", "lime juice"],
      steps: ["Fold the lime juice through the salmon."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("fish-curing-rescue") && r.includes("summary"))).toBe(true);
  });
});

describe("each recurring heuristic defect is structurally gone", () => {
  test("defect 1 — an ingredient line is never a class source: '1 cup chicken stock' does not bind poultry", async () => {
    // The old gate attributed food classes from whole ingredient lines; the
    // canon classifies per step and excludes cooked objects like stock.
    // Kit-derived from tn-no-protein-no-check-needed, with the poultry word
    // planted in the ingredients the old heuristics misread.
    const result = await verdictFor({
      title: "Beef stew",
      ingredientLines: ["1 cup chicken stock", "onions", "flour"],
      steps: ["Browning the onions for the stew."],
    });
    expect(result.failed).toBe(false);
  });

  test("defect 2 — a cooling word does not exempt the sentence's temperature claim", async () => {
    // The old gate skipped any sentence containing a cooling word; the canon
    // checks the claim wherever it stands. Kit-derived from
    // ground-poultry-at-160-is-below-minimum (160 °F < the 165 °F ground
    // poultry minimum), with the cooling language in the same step: the
    // claim still fails the publication.
    const result = await verdictFor({
      title: "Turkey burgers",
      ingredientLines: ["500 g ground turkey"],
      steps: ["Chill the leftover patties first, then cook the ground turkey to 160 °F with a thermometer."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("belowMinimumTemperature") && r.includes("ground-poultry-165"))).toBe(true);
  });

  test("defect 3 — a thermometer mention with no number is a finding, never evidence", async () => {
    // The canon kit's thermometer-named-but-no-temperature case, verbatim.
    const result = await verdictFor({
      title: "Braised chicken thighs",
      ingredientLines: ["4 chicken thighs, stock"],
      steps: ["Insert a thermometer into the chicken thigh and cook until done."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("missingInternalTemperature") && r.includes("165"))).toBe(true);
  });

  test("defect 4 — an unclassifiable food flags for review; no lowest-floor pass exists", async () => {
    // The canon kit's unclassifiable-protein-flags-for-review case: the old
    // gate would have checked rabbit against the lowest reviewed floor; the
    // canon refuses the publication to a human reviewer instead.
    const result = await verdictFor({
      title: "Farmhouse rabbit stew",
      ingredientLines: ["1 rabbit, root vegetables"],
      steps: ["Braise the rabbit until tender."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("flagForReview") && r.includes("rabbit"))).toBe(true);
  });

  test("defect 4b — an unclassifiable food fails review even with a stated temperature above the old lowest floor", async () => {
    // The old lowest-floor fallback would pass 150 °F rabbit (above 145 °F);
    // the canon has no rule for rabbit, so the step is UNKNOWN and refuses.
    const result = await verdictFor({
      title: "Rabbit confit",
      ingredientLines: ["1 rabbit"],
      steps: ["Cook the rabbit to 150 °F with a thermometer."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("flagForReview"))).toBe(true);
  });

  test("defect 5 — each food's own stated temperature must reach its own minimum", async () => {
    // The old gate let one temperature in scope satisfy every food in the
    // sentence: chicken stated at 145 °F passed because the burger's 160 °F
    // reached the poultry floor's neighbour. The canon pools the step's
    // internal temperatures per matched rule: 145 °F is below the poultry
    // minimum, so the step refuses.
    const result = await verdictFor({
      title: "Surf and turf burgers",
      ingredientLines: ["1 chicken breast", "500 g ground beef"],
      steps: ["Cook the chicken to 145 °F and the beef burger to 160 °F, each checked with a thermometer."],
    });
    expect(result.failed).toBe(true);
    expect(result.reasons.some((r) => r.includes("belowMinimumTemperature") && r.includes("poultry"))).toBe(true);
  });

  test("defect 5 contrast — a step whose internal temperatures all meet the strictest applicable minimum passes", async () => {
    // The canon's pinned semantic (Swift verify: every internal temperature
    // in the step must meet the matched rule's minimum): 165 °F is the
    // strictest minimum in the step, so both foods pass; 145 °F next to a
    // poultry match does not (the defect-5 test above).
    const result = await verdictFor({
      title: "Surf and turf burgers",
      ingredientLines: ["1 chicken breast", "500 g ground beef"],
      steps: ["Cook the chicken to 165 °F and the beef burger to 165 °F, each checked with a thermometer."],
    });
    expect(result.failed).toBe(false);
  });
});

describe("the stage refuses on every canon verdict class", () => {
  test("any finding fails the stage into the human queue — never a silent pass", async () => {
    for (const recipe of [
      { title: "Time only", steps: ["Simmer the chicken soup for 25 minutes."] }, // timeOnlyCooking
      { title: "Counter thaw", steps: ["Thaw the chicken breasts on the counter."] }, // ambientThawing
      { title: "Raw egg", steps: ["Blend a raw egg into the dressing."] }, // rawEggNoWarning
    ]) {
      const result = await verdictFor({ title: recipe.title, ingredientLines: ["chicken"], steps: recipe.steps });
      expect(result.failed).toBe(true);
    }
  });

  test("an unusable rulebook at runtime fails the stage closed", async () => {
    // Belt for the load-time suspenders: a linter built without a rulebook
    // (clause 7) refuses every publication instead of passing anything.
    const closedCanon: VendoredCanon = {
      steps: new StepLinter(null),
      copy: new CopyLint(readFileSync(join(CANON_DIR, "copy-lint-patterns.json"), "utf8")),
    };
    const verdict = await foodSafetyLintStage(closedCanon).run(publication());
    expect(verdict.outcome).toBe("fail");
    if (verdict.outcome === "fail") {
      expect(verdict.reasons.some((r) => r.includes("failClosed") && r.includes("no rules data"))).toBe(true);
    }
  });
});

describe("the canon package loader is fail closed by construction", () => {
  /** A writable copy of the vendored canon to tamper with. */
  function canonCopy(): string {
    const dir = mkdtempSync(join(tmpdir(), "fl-canon-drift-"));
    cpSync(CANON_DIR, dir, { recursive: true });
    return dir;
  }

  function expectClosed(load: VendoredCanonLoad, needle: string): void {
    expect(load.loaded).toBe(false);
    if (load.loaded) {
      throw new Error("expected a closed load");
    }
    expect(load.reason).toContain(needle);
  }

  test("an intact copy loads", () => {
    const dir = canonCopy();
    try {
      expect(loadVendoredCanonPackage(dir).loaded).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a one-byte change to the rulebook is drift", () => {
    const dir = canonCopy();
    try {
      appendFileSync(join(dir, "rules.json"), " ");
      expectClosed(loadVendoredCanonPackage(dir), "drifted from its pinned hash");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a missing conformance fixture is drift", () => {
    const dir = canonCopy();
    try {
      unlinkSync(join(dir, "conformance", "true-negatives.json"));
      expectClosed(loadVendoredCanonPackage(dir), "missing or unreadable");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a manifest that stops pinning a file is drift", () => {
    const dir = canonCopy();
    try {
      const manifest = JSON.parse(readFileSync(join(dir, "PROVENANCE.json"), "utf8")) as { files: Array<{ path: string }> };
      manifest.files = manifest.files.filter((entry) => entry.path !== "conformance/README.md");
      writeFileSync(join(dir, "PROVENANCE.json"), JSON.stringify(manifest), "utf8");
      expectClosed(loadVendoredCanonPackage(dir), "does not pin");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("an unknown manifest schema is drift", () => {
    const dir = canonCopy();
    try {
      const manifest = JSON.parse(readFileSync(join(dir, "PROVENANCE.json"), "utf8")) as { schema: string };
      manifest.schema = "someone-else@v9";
      writeFileSync(join(dir, "PROVENANCE.json"), JSON.stringify(manifest), "utf8");
      expectClosed(loadVendoredCanonPackage(dir), "schema");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a missing manifest is drift", () => {
    const dir = canonCopy();
    try {
      unlinkSync(join(dir, "PROVENANCE.json"));
      expectClosed(loadVendoredCanonPackage(dir), "manifest is missing");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the gate closes (no stages, stated reason) on a drifted canon package", () => {
    const dir = canonCopy();
    try {
      appendFileSync(join(dir, "rules.json"), " ");
      const gate: FoodSafetyGate = createFoodSafetyGate({
        canonDir: dir,
        canonPath: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
        factsPath: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`,
      });
      expect(gate.requiredStages).toBeNull();
      expect(gate.closedReason).toContain("drifted from its pinned hash");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the gate opens on the vendored canon and the valid fixture catalog", () => {
    const catalog = loadFoodSafetyCatalog({
      canon: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
      facts: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`,
    });
    const gate = foodSafetyGateFromCatalog(catalog);
    expect(gate.closedReason).toBeNull();
    expect(gate.requiredStages?.map((stage) => stage.name)).toEqual(["food-safety-lint", "compound-allergens"]);
  });
});
