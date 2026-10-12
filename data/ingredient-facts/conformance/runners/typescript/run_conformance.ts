// Independent TypeScript conformance runner for data/ingredient-facts.
//
// Re-implements the evaluation semantics from
// packages/FLIngredientFacts/Sources/FLIngredientFacts on its own: it shares
// no code with the Swift package. Loads the dataset, validates it strictly,
// runs every case in conformance/cases.json and exits nonzero on any failure.
//
// Usage: bun run_conformance.ts [repo-root-or-data-dir] [cases.json]

import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ALLERGENS = [
  "milk", "egg", "fish", "crustaceanShellfish", "treeNuts",
  "peanuts", "wheat", "soy", "sesame",
] as const;
const DIETS = ["vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree"] as const;
const EVIDENCE_KINDS = ["usda", "label", "reference", "recipe", "standard"] as const;
const FACT_STATES = ["contains", "free", "unknown", "allowed", "violated"] as const;
const CERTAINTIES = ["certain", "typical", "variable", "unknown"] as const;

type Allergen = (typeof ALLERGENS)[number];
type Diet = (typeof DIETS)[number];
type Evidence = { kind: string; ref: string; note: string };
type FactObject = { state: string; evidence?: Evidence };
type Component = { key: string; certainty: string; evidence?: Evidence };
type FormOverride = {
  allergens?: Record<string, FactObject>;
  gluten?: FactObject;
  diets?: Record<string, FactObject>;
};
type FactEntry = {
  key: string;
  class?: string;
  components?: Component[];
  compositionComplete?: boolean;
  note?: string;
  allergens?: Record<string, FactObject>;
  gluten?: FactObject;
  diets?: Record<string, FactObject>;
  forms?: Record<string, FormOverride>;
};
type FormRecord = { key: string; display: string; synonyms?: string[] };
type Identity = {
  key: string;
  display: string;
  kind?: string;
  synonyms?: string[];
  usdaFdcId?: number;
  usdaRef?: string;
  usdaNote?: string;
  appLocalIds?: number[];
  forms?: FormRecord[];
  note?: string;
};

type FLRestriction = { allergen: Allergen } | { diet: Diet };
type Violation = { ingredient: string; restriction: FLRestriction; reason: string; evidence: Evidence[] };
type Unknown = { ingredient: string; restriction: FLRestriction; missing: string[]; reason: string };
type Evaluation =
  | { result: "allowed"; evidence: Evidence[] }
  | { result: "violated"; violation: Violation }
  | { result: "unknown"; unknown: Unknown };

class DatasetError extends Error {}

function fail(message: string): never {
  throw new DatasetError(message);
}

function normalized(raw: string): string {
  return raw.trim().toLowerCase();
}

function parseJsonFile(path: string): any {
  if (!existsSync(path)) fail(`missing dataset file: ${path}`);
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`invalid JSON in ${path}: ${error}`);
  }
}

// Absence never rests on catalog or recipe evidence.
function checkEvidenceState(state: string, evidence: Evidence | undefined, where: string): void {
  if (!FACT_STATES.includes(state as any)) fail(`${where}: bad state '${state}'`);
  if (!evidence) {
    if (state === "unknown") return;
    fail(`${where}: ${state} fact lacks evidence`);
  }
  if (!EVIDENCE_KINDS.includes(evidence.kind as any)) {
    fail(`${where}: bad evidence kind '${evidence.kind}'`);
  }
  if (typeof evidence.ref !== "string" || typeof evidence.note !== "string") {
    fail(`${where}: evidence must carry ref and note`);
  }
  if ((state === "free" || state === "allowed") &&
      (evidence.kind === "usda" || evidence.kind === "recipe")) {
    fail(`${where}: absence state '${state}' may not use '${evidence.kind}' evidence`);
  }
}

class Dataset {
  identities: Identity[];
  facts: Record<string, FactEntry>;
  displayName: Record<string, string>;
  nameIndex: Record<string, string> = {};
  formIndex: Record<string, { identity: string; form: string }> = {};

  constructor(dataDir: string) {
    const identitiesFile = parseJsonFile(join(dataDir, "identities.json"));
    const factsFile = parseJsonFile(join(dataDir, "facts.json"));
    this.identities = identitiesFile.ingredients;
    this.facts = factsFile.facts;
    if (!this.identities?.length) fail("identities.json is empty");
    if (!this.facts || !Object.keys(this.facts).length) fail("facts.json is empty");
    this.displayName = Object.fromEntries(this.identities.map((i) => [i.key, i.display]));
    this.validate();
  }

  private indexName(raw: string, key: string): void {
    const name = normalized(raw);
    const existing = this.nameIndex[name];
    if (existing !== undefined) {
      if (existing !== key) fail(`name '${raw}' maps to both ${existing} and ${key}`);
      return;
    }
    this.nameIndex[name] = key;
  }

  private indexFormName(raw: string, identity: string, form: string): void {
    const name = normalized(raw);
    if (this.formIndex[name] !== undefined || this.nameIndex[name] !== undefined) {
      fail(`match name '${raw}' is not unique (identity ${identity}, form ${form})`);
    }
    this.formIndex[name] = { identity, form };
    this.nameIndex[name] = identity;
  }

  private validate(): void {
    const keys = new Set<string>();
    for (const ing of this.identities) {
      if (keys.has(ing.key)) fail(`duplicate identity key '${ing.key}'`);
      keys.add(ing.key);
      if (this.facts[ing.key] === undefined && ing.key !== "artisan-granola-bar") {
        fail(`identity '${ing.key}' has no fact entry`);
      }
      this.indexName(ing.key, ing.key);
      this.indexName(ing.display, ing.key);
      for (const syn of ing.synonyms ?? []) this.indexName(syn, ing.key);
      for (const form of ing.forms ?? []) {
        for (const syn of form.synonyms ?? []) {
          this.indexFormName(syn, ing.key, form.key);
        }
        const factEntry = this.facts[ing.key];
        if (factEntry?.forms?.[form.key] === undefined) {
          fail(`identity '${ing.key}' form '${form.key}' has no fact override`);
        }
      }
    }

    for (const [key, entry] of Object.entries(this.facts)) {
      if (entry.key !== key) fail(`fact entry key mismatch: ${key} vs ${entry.key}`);
      for (const [allergen, fact] of Object.entries(entry.allergens ?? {})) {
        if (!ALLERGENS.includes(allergen as Allergen)) fail(`${key}: unknown allergen '${allergen}'`);
        checkEvidenceState(fact.state, fact.evidence, `${key}.allergens.${allergen}`);
      }
      for (const [diet, fact] of Object.entries(entry.diets ?? {})) {
        if (!DIETS.includes(diet as Diet)) fail(`${key}: unknown diet '${diet}'`);
        checkEvidenceState(fact.state, fact.evidence, `${key}.diets.${diet}`);
      }
      if (entry.gluten) checkEvidenceState(entry.gluten.state, entry.gluten.evidence, `${key}.gluten`);
      for (const [formName, override] of Object.entries(entry.forms ?? {})) {
        for (const [allergen, fact] of Object.entries(override.allergens ?? {})) {
          if (!ALLERGENS.includes(allergen as Allergen)) {
            fail(`${key}.forms.${formName}: unknown allergen '${allergen}'`);
          }
          checkEvidenceState(fact.state, fact.evidence, `${key}.forms.${formName}.allergens.${allergen}`);
        }
        for (const [diet, fact] of Object.entries(override.diets ?? {})) {
          if (!DIETS.includes(diet as Diet)) fail(`${key}.forms.${formName}: unknown diet '${diet}'`);
          checkEvidenceState(fact.state, fact.evidence, `${key}.forms.${formName}.diets.${diet}`);
        }
        if (override.gluten) {
          checkEvidenceState(override.gluten.state, override.gluten.evidence, `${key}.forms.${formName}.gluten`);
        }
      }
      for (const component of entry.components ?? []) {
        if (this.facts[component.key] === undefined) {
          fail(`${key}: component key '${component.key}' does not resolve`);
        }
        if (!CERTAINTIES.includes(component.certainty as any)) {
          fail(`${key}: bad certainty '${component.certainty}'`);
        }
        if (component.certainty !== "unknown" && !component.evidence) {
          fail(`${key}: component '${component.key}' lacks evidence`);
        }
      }
    }
  }

  resolveFactKey(name: string): { key: string; form: string | null } | null {
    const folded = normalized(name);
    const key = this.nameIndex[folded];
    if (key === undefined) return null;
    const form = this.formIndex[folded];
    if (form) return { key: form.identity, form: form.form };
    return { key, form: null };
  }
}

function orderedRestrictions(rs: { allergens: Set<Allergen>; diets: Set<Diet> }): FLRestriction[] {
  return ALLERGENS.filter((a) => rs.allergens.has(a)).map((a) => ({ allergen: a }) as FLRestriction)
    .concat(DIETS.filter((d) => rs.diets.has(d)).map((d) => ({ diet: d }) as FLRestriction));
}

function evaluate(
  dataset: Dataset,
  entry: FactEntry,
  form: string | null,
  restrictions: { allergens: Set<Allergen>; diets: Set<Diet> },
  ingredientLabel: string,
  depth: number,
): Evaluation {
  const violations: Violation[] = [];
  const unknownMissing: string[] = [];
  const unknownAllergens = new Set<Allergen>();
  const unknownDiets = new Set<Diet>();
  let unknownRestriction: FLRestriction | null = null;
  const allowedEvidence: Evidence[] = [];

  function factFor(restriction: FLRestriction): FactObject | undefined {
    const override = form ? entry.forms?.[form] : undefined;
    if ("allergen" in restriction) {
      return override?.allergens?.[restriction.allergen] ?? entry.allergens?.[restriction.allergen];
    }
    return override?.diets?.[restriction.diet] ?? entry.diets?.[restriction.diet];
  }

  function recordUnknown(restriction: FLRestriction, note?: string): void {
    if (!unknownRestriction) unknownRestriction = restriction;
    if ("allergen" in restriction) unknownAllergens.add(restriction.allergen);
    else unknownDiets.add(restriction.diet);
    const what = "allergen" in restriction
      ? `allergen '${restriction.allergen}' fact for '${entry.key}' is missing or unknown`
      : `diet '${restriction.diet}' fact for '${entry.key}' is missing or unknown`;
    unknownMissing.push(note ? `${what} — ${note}` : what);
  }

  function violationReason(restriction: FLRestriction): string {
    return "allergen" in restriction
      ? `'${ingredientLabel}' contains the allergen '${restriction.allergen}'`
      : `'${ingredientLabel}' is not compatible with the ${restriction.diet} diet`;
  }

  for (const restriction of orderedRestrictions(restrictions)) {
    const fact = factFor(restriction);
    const state = fact?.state;
    if (state === "contains" || state === "violated") {
      if (fact?.evidence) {
        violations.push({
          ingredient: ingredientLabel,
          restriction,
          reason: violationReason(restriction),
          evidence: [fact.evidence],
        });
      }
    } else if (state === "free" || state === "allowed") {
      if (fact?.evidence) allowedEvidence.push(fact.evidence);
    } else if (state === "unknown") {
      recordUnknown(restriction, fact?.evidence?.note);
    } else {
      recordUnknown(restriction);
    }
  }

  if (violations.length) return { result: "violated", violation: violations[0] };

  const components = entry.components ?? [];
  if (unknownMissing.length && depth < 8 && components.length) {
    const componentUnknowns: string[] = [];
    for (const component of components) {
      const label = `'${component.key}' in '${entry.key}'`;
      const componentEntry = dataset.facts[component.key];
      if (!componentEntry) {
        componentUnknowns.push(`composition of ${label} is unrecorded`);
        continue;
      }
      if (component.certainty === "certain" || component.certainty === "typical") {
        const sub = evaluate(dataset, componentEntry, null, restrictions, component.key, depth + 1);
        if (sub.result === "violated") {
          const evidence = [...sub.violation.evidence];
          if (component.evidence) evidence.push(component.evidence);
          return {
            result: "violated",
            violation: {
              ingredient: ingredientLabel,
              restriction: sub.violation.restriction,
              reason: `component ${sub.violation.reason}`,
              evidence,
            },
          };
        }
        if (sub.result === "unknown") {
          componentUnknowns.push(`component ${component.key}: ${sub.unknown.missing.join("; ")}`);
        } else {
          allowedEvidence.push(...sub.evidence);
        }
      } else if (component.certainty === "variable") {
        // Presence varies: a violation only means SOME products carry it,
        // which is unknown, not violated.
        const sub = evaluate(dataset, componentEntry, null, restrictions, component.key, depth + 1);
        if (sub.result === "violated") {
          componentUnknowns.push(
            `whether ${label} is present varies by product; when present it ${sub.violation.reason}`);
        } else if (sub.result === "unknown") {
          componentUnknowns.push(
            `component ${component.key} (presence varies): ${sub.unknown.missing.join("; ")}`);
        } else {
          allowedEvidence.push(...sub.evidence);
        }
      } else {
        componentUnknowns.push(`composition of ${label} is unverified (certainty unknown)`);
      }
    }
    const fallbackRestriction = unknownRestriction
      ?? orderedRestrictions(restrictions)[0]
      ?? ({ allergen: "milk" } as FLRestriction);
    if (componentUnknowns.length) {
      return {
        result: "unknown",
        unknown: {
          ingredient: ingredientLabel,
          restriction: fallbackRestriction,
          missing: [...unknownMissing, ...componentUnknowns],
          reason: "compound composition leaves restrictions undecided",
        },
      };
    }
    if (!unknownAllergens.size || entry.compositionComplete === true) {
      return { result: "allowed", evidence: allowedEvidence };
    }
    return {
      result: "unknown",
      unknown: {
        ingredient: ingredientLabel,
        restriction: fallbackRestriction,
        missing: [...unknownMissing, `composition of '${entry.key}' is incomplete`],
        reason: "composition is not known to be complete",
      },
    };
  }

  if (!unknownMissing.length) return { result: "allowed", evidence: allowedEvidence };
  return {
    result: "unknown",
    unknown: {
      ingredient: ingredientLabel,
      restriction: unknownRestriction
        ?? orderedRestrictions(restrictions)[0]
        ?? ({ allergen: "milk" } as FLRestriction),
      missing: unknownMissing,
      reason: "facts do not settle the restricted properties",
    },
  };
}

function evaluateIngredient(
  dataset: Dataset,
  name: string,
  restrictions: { allergens: Set<Allergen>; diets: Set<Diet> },
): Evaluation {
  const resolved = dataset.resolveFactKey(name);
  const fallback = orderedRestrictions(restrictions)[0] ?? ({ allergen: "milk" } as FLRestriction);
  if (!resolved) {
    return {
      result: "unknown",
      unknown: {
        ingredient: name,
        restriction: fallback,
        missing: [`ingredient '${name}' is not in the dataset`],
        reason: "unresolved ingredient: evaluation fails closed",
      },
    };
  }
  const entry = dataset.facts[resolved.key];
  if (!entry) {
    return {
      result: "unknown",
      unknown: {
        ingredient: name,
        restriction: fallback,
        missing: [`no facts exist for '${resolved.key}'`],
        reason: "unfactored ingredient: evaluation fails closed",
      },
    };
  }
  const label = dataset.displayName[resolved.key] ?? name;
  return evaluate(dataset, entry, resolved.form, restrictions, label, 0);
}

function main(): number {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  // script lives at <root>/data/ingredient-facts/conformance/runners/typescript/
  const defaultDataDir = resolve(scriptDir, "../../..");
  let dataDir = defaultDataDir;
  let casesPath = join(defaultDataDir, "conformance", "cases.json");
  if (process.argv[2]) {
    const arg = resolve(process.argv[2]);
    dataDir = existsSync(join(arg, "identities.json")) ? arg : join(arg, "data/ingredient-facts");
  }
  if (process.argv[3]) casesPath = resolve(process.argv[3]);

  let dataset: Dataset;
  try {
    dataset = new Dataset(dataDir);
  } catch (error) {
    console.error(`dataset load failed: ${(error as Error).message}`);
    return 2;
  }

  const casesFile = parseJsonFile(casesPath);
  const cases: Array<{
    id: string; ingredient: string;
    restrictions: { allergens?: string[]; diets?: string[] };
    expected: { result: string; reasonContains?: string[]; missingMention?: string[]; evidenceMention?: string[] };
    note?: string;
  }> = casesFile.cases;

  let failures = 0;
  console.log(`running ${cases.length} conformance cases against ${dataDir}`);
  for (const c of cases) {
    const restrictions = {
      allergens: new Set((c.restrictions.allergens ?? []).filter((a): a is Allergen =>
        ALLERGENS.includes(a as Allergen))),
      diets: new Set((c.restrictions.diets ?? []).filter((d): d is Diet =>
        DIETS.includes(d as Diet))),
    };
    const evaluation = evaluateIngredient(dataset, c.ingredient, restrictions);
    const problems: string[] = [];
    if (evaluation.result !== c.expected.result) {
      problems.push(`expected ${c.expected.result}, got ${evaluation.result}`);
    }
    if (evaluation.result === c.expected.result) {
      const reason = evaluation.result === "violated"
        ? evaluation.violation.reason.toLowerCase()
        : evaluation.result === "unknown" ? evaluation.unknown.reason.toLowerCase() : "";
      for (const needle of c.expected.reasonContains ?? []) {
        if (!reason.includes(needle.toLowerCase())) {
          problems.push(`reason does not mention '${needle}': ${reason}`);
        }
      }
      const missing = evaluation.result === "unknown"
        ? evaluation.unknown.missing.map((m) => m.toLowerCase()).join("; ") : "";
      for (const needle of c.expected.missingMention ?? []) {
        if (!missing.includes(needle.toLowerCase())) {
          problems.push(`missing list does not mention '${needle}': ${missing}`);
        }
      }
      const evidence = evaluation.result === "allowed"
        ? evaluation.evidence.map((e) => `${e.kind} ${e.ref} ${e.note}`.toLowerCase()).join(" | ") : "";
      for (const needle of c.expected.evidenceMention ?? []) {
        if (!evidence.includes(needle.toLowerCase())) {
          problems.push(`evidence does not mention '${needle}': ${evidence}`);
        }
      }
    }
    if (problems.length) {
      failures += 1;
      console.log(`  FAIL ${c.id}: ${problems.join("; ")}`);
    } else {
      console.log(`  PASS ${c.id}: ${evaluation.result}`);
    }
  }

  if (failures === 0) {
    console.log(`all ${cases.length} cases passed`);
    return 0;
  }
  console.log(`${failures} of ${cases.length} cases failed`);
  return 1;
}

process.exit(main());
