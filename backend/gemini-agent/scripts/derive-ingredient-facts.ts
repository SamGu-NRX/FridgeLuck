/**
 * Derives the backend ingredient-facts seam (fridgeluck/ingredient-facts@v1)
 * from the canonical FLIngredientFacts dataset on `overhaul/ingredient-facts`
 * (PR #104 review blocker 3).
 *
 * The canonical dataset is richer than the backend seam: it records evidence,
 * gluten/diet axes, compound composition and per-form overrides. This script
 * is the derivation, not a hand-edit: it validates the source (mirroring the
 * dataset's own conformance checks), keeps only entries whose allergen
 * knowledge is reviewed, and writes the @v1 seam with provenance the loader
 * rechecks at load time.
 *
 * What is INCLUDED: an ingredient whose asserted allergen facts are all
 * `contains`/`free` (no `unknown`), whose compound composition is closed
 * (`compositionComplete: true`) when it is a compound, and whose names
 * resolve in identities.json. Its `allergens` list is the allergens it
 * CONTAINS (compound contributions already resolved by the dataset).
 *
 * What stays UNKNOWN (excluded — the gate fails closed on it): ingredients
 * with any explicit `unknown` allergen fact (stock cubes, bouillon, generic
 * tamari's wheat status, …) and compounds with an open component list.
 * An ingredient absent from the derived seam is unknown at the gate too —
 * "unresolved ingredient: evaluation fails closed", per the dataset's own
 * conformance semantics.
 *
 * Boundary (recorded in the seam's provenance): the @v1 seam asserts
 * PRESENCE only — an allergen missing from an entry's list is not a reviewed
 * absence. The dataset's reviewed `free` facts and their evidence discipline
 * live upstream; absence claims are governed by the rulebook's allergen-claim
 * rules plus the fail-closed unknown-composition check in the gate.
 *
 * Usage:
 *   bun scripts/derive-ingredient-facts.ts <canonical-data-dir> <output-json>
 *   bun scripts/derive-ingredient-facts.ts /tmp/fl-canon/data/ingredient-facts data/food-safety/ingredient-facts.json
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { sha256Hex, stableIngredientFactsString } from "../src/community/foodSafety/catalog.js";

const CANON_BRANCH = "overhaul/ingredient-facts";
const CANON_COMMIT = "b0deecce36bf6ee91e6f5933e746d75466165288";
const CANON_FACTS_FILE = "data/ingredient-facts/facts.json";
const CANON_IDENTITIES_FILE = "data/ingredient-facts/identities.json";

/** The nine FDA major allergens, as canonical keys and backend seam slugs. */
const ALLERGEN_SLUGS: Record<string, string> = {
  milk: "milk",
  egg: "egg",
  fish: "fish",
  crustaceanShellfish: "crustacean-shellfish",
  treeNuts: "tree-nuts",
  peanuts: "peanuts",
  wheat: "wheat",
  soy: "soy",
  sesame: "sesame",
};

const EVIDENCE_KINDS = new Set(["usda", "label", "reference", "recipe", "standard"]);
const ABSENCE_KINDS = new Set(["label", "reference", "standard"]);
const STATES = new Set(["contains", "free", "unknown"]);

interface CanonicalEvidence {
  kind?: unknown;
  ref?: unknown;
  note?: unknown;
}
interface CanonicalFactObject {
  state?: unknown;
  evidence?: CanonicalEvidence;
}
interface CanonicalFactEntry {
  key?: unknown;
  components?: unknown;
  compositionComplete?: unknown;
  allergens?: Record<string, CanonicalFactObject>;
}
interface CanonicalIdentity {
  key?: unknown;
  display?: unknown;
  synonyms?: unknown;
  forms?: Array<{ key?: unknown; display?: unknown; synonyms?: unknown }>;
}

/** Mirrors the dataset's load-time checks (see conformance/runners). Fails loudly on drift. */
function validateEntry(key: string, entry: CanonicalFactEntry, where: string): void {
  if (entry.key !== key) {
    throw new Error(`${where}: fact entry key mismatch: ${key} vs ${String(entry.key)}`);
  }
  const allergens = entry.allergens ?? {};
  for (const [allergen, fact] of Object.entries(allergens)) {
    if (!(allergen in ALLERGEN_SLUGS)) {
      throw new Error(`${where}.${allergen}: unknown allergen '${allergen}'`);
    }
    if (!fact || typeof fact !== "object") {
      throw new Error(`${where}.${allergen}: fact must be an object`);
    }
    if (typeof fact.state !== "string" || !STATES.has(fact.state)) {
      throw new Error(`${where}.${allergen}: bad state '${String(fact.state)}'`);
    }
    if (fact.state === "unknown") {
      continue; // unknown facts carry no evidence obligation
    }
    const evidence = fact.evidence;
    if (!evidence || typeof evidence !== "object") {
      throw new Error(`${where}.${allergen}: ${fact.state} fact lacks evidence`);
    }
    if (typeof evidence.kind !== "string" || !EVIDENCE_KINDS.has(evidence.kind) || typeof evidence.ref !== "string" || evidence.ref.trim().length === 0 || typeof evidence.note !== "string" || evidence.note.trim().length === 0) {
      throw new Error(`${where}.${allergen}: incomplete evidence`);
    }
    if (fact.state === "free" && !ABSENCE_KINDS.has(evidence.kind)) {
      throw new Error(`${where}.${allergen}: absence state 'free' may not use '${evidence.kind}' evidence`);
    }
  }
}

function normalizeName(value: unknown, where: string): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 ? normalized : null;
}

function main(): void {
  const [dataDir, outputPath] = process.argv.slice(2);
  if (!dataDir || !outputPath) {
    console.error("usage: bun scripts/derive-ingredient-facts.ts <canonical-data-dir> <output-json>");
    process.exit(2);
  }

  const factsPath = `${dataDir}/facts.json`;
  const identitiesPath = `${dataDir}/identities.json`;
  const factsBytes = readFileSync(factsPath);
  const factsSourceHash = sha256Hex(factsBytes.toString("utf8"));

  const identitiesRaw = JSON.parse(readFileSync(identitiesPath, "utf8")) as { ingredients?: CanonicalIdentity[] };
  const factsRaw = JSON.parse(factsBytes.toString("utf8")) as { facts?: Record<string, CanonicalFactEntry> };
  const identities = identitiesRaw.ingredients ?? [];
  const facts = factsRaw.facts ?? {};
  if (identities.length === 0 || Object.keys(facts).length === 0) {
    throw new Error("canonical dataset is empty — refusing to derive from it");
  }

  // Names: identity keys/displays/synonyms and form keys/displays/synonyms,
  // mirroring the conformance runner's name index.
  const namesByKey = new Map<string, Set<string>>();
  const addName = (key: string, value: unknown, where: string): void => {
    const name = normalizeName(value, where);
    if (name === null) {
      throw new Error(`${where}: blank name`);
    }
    const set = namesByKey.get(key) ?? new Set<string>();
    set.add(name);
    namesByKey.set(key, set);
  };
  for (const [i, identity] of identities.entries()) {
    const key = identity.key;
    if (typeof key !== "string" || key.length === 0) {
      throw new Error(`identities[${i}]: missing key`);
    }
    addName(key, identity.display, `identities[${i}].display`);
    if (Array.isArray(identity.synonyms)) {
      identity.synonyms.forEach((synonym, j) => addName(key, synonym, `identities[${i}].synonyms[${j}]`));
    }
    if (Array.isArray(identity.forms)) {
      for (const [j, form] of identity.forms.entries()) {
        if (typeof form.key !== "string" || form.key.length === 0) {
          throw new Error(`identities[${i}].forms[${j}]: missing key`);
        }
        addName(form.key, form.display, `identities[${i}].forms[${j}].display`);
        if (Array.isArray(form.synonyms)) {
          form.synonyms.forEach((synonym, k) => addName(form.key, synonym, `identities[${i}].forms[${j}].synonyms[${k}]`));
        }
      }
    }
  }
  // The identity key itself is always a usable name (the runner indexes it too).
  for (const identity of identities) {
    if (typeof identity.key === "string" && !namesByKey.has(identity.key)) {
      namesByKey.set(identity.key, new Set([identity.key]));
    }
  }

  let openCompounds = 0;
  let unknownAxisExcluded = 0;
  let unresolvableKeys = 0;
  const derived: Array<{ id: string; match: string[]; allergens: string[] }> = [];

  for (const [key, entry] of Object.entries(facts)) {
    if (entry === null || typeof entry !== "object") {
      throw new Error(`facts.${key}: entry must be an object`);
    }
    validateEntry(key, entry, `facts.${key}`);

    const names = namesByKey.get(key);
    if (names === undefined || names.size === 0) {
      // Component-only facts (anchovy, soybeans, wheat-flour, …) are reached
      // by key inside compound composition, never by name — the canonical
      // evaluator treats a line naming them as unresolved and fails closed.
      // The seam mirrors that: no identity, no entry.
      unresolvableKeys += 1;
      continue;
    }

    const isCompound = Array.isArray(entry.components);
    if (isCompound && entry.compositionComplete !== true) {
      openCompounds += 1;
      continue;
    }

    const allergenFacts = entry.allergens ?? {};
    const hasUnknownAxis = Object.values(allergenFacts).some((fact) => fact.state === "unknown");
    if (hasUnknownAxis) {
      unknownAxisExcluded += 1;
      continue;
    }

    const contains = new Set<string>();
    for (const [allergen, fact] of Object.entries(allergenFacts)) {
      if (fact.state === "contains") {
        contains.add(ALLERGEN_SLUGS[allergen] as string);
      }
    }
    derived.push({ id: key, match: [...names].sort(), allergens: [...contains].sort() });
  }

  derived.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const seam = {
    schema: "fridgeluck/ingredient-facts@v1",
    source: `derived from the canonical FLIngredientFacts dataset (${CANON_BRANCH}); allergen presence per ingredient, compound contributions already resolved`,
    allergens: Object.values(ALLERGEN_SLUGS).sort(),
    ingredients: derived,
    provenance: {
      sourceBranch: CANON_BRANCH,
      sourceFile: CANON_FACTS_FILE,
      sourceCommit: CANON_COMMIT,
      sourceFileHash: `sha256:${factsSourceHash}`,
      copiedBlobHash: `sha256:${sha256Hex(stableIngredientFactsString(derived))}`,
      extracted: `Derived by scripts/derive-ingredient-facts.ts from ${CANON_FACTS_FILE} and ${CANON_IDENTITIES_FILE} at ${CANON_COMMIT}: ${derived.length} ingredients kept; left out — ${openCompounds} open compounds, ${unknownAxisExcluded} ingredients with an unknown allergen axis, ${unresolvableKeys} component-only facts without an identity (they stay unknown at the gate and fail closed, as do ingredients absent from this file). The seam asserts presence only: an allergen missing from an entry is not a reviewed absence — absence claims are governed by the rulebook's allergen-claim rules and the gate's fail-closed unknown-composition check.`,
    },
  };

  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(seam, null, 2)}\n`, "utf8");
  console.log(`derived ${derived.length} entries from ${Object.keys(facts).length} facts`);
  console.log(`excluded: ${openCompounds} open compounds, ${unknownAxisExcluded} unknown-allergen-axis ingredients, ${unresolvableKeys} component-only facts`);
  console.log(`copiedBlobHash: ${seam.provenance.copiedBlobHash}`);
  console.log(`wrote ${outputPath}`);
}

main();
