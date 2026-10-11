/**
 * The mandatory food-safety publish gate (SPEC 3.1, 3.5: "Rights, safety lint
 * and allergen tagging apply to user recipes exactly as to the catalog";
 * PR #104 review blocker 1).
 *
 * Two screening stages are REQUIRED on the publication path — the canonical
 * rulebook lint and compound-allergen tagging derived from the ingredient
 * facts — before anything leaves the author's private view. The gate is
 * fail-closed: while the canon/ingredient-facts packages are not loaded
 * (absent, empty, unparsable, or off-schema), `requiredStages` is null and
 * the publish route must refuse with an error envelope — never queue, never
 * publish. There is no mode in which a publication is created unevaluated.
 */
import type { ScreenablePublication, ScreeningStage, ScreeningVerdict } from "../shared/contracts.js";
import {
  loadFoodSafetyCatalog,
  resolveFoodSafetyCatalogPaths,
  type FoodSafetyCatalog,
  type FoodSafetyCatalogPaths,
  type FoodSafetyRulebook,
  type IngredientFacts,
} from "./catalog.js";

export interface FoodSafetyGate {
  /**
   * The two mandatory stages when the catalog is loaded; null when closed
   * (fail closed — the publish route refuses with an error envelope).
   */
  readonly requiredStages: readonly ScreeningStage[] | null;
  /** Why the gate is closed; null when open. Goes into logs and error envelopes. */
  readonly closedReason: string | null;
}

export interface CreateFoodSafetyGateOptions {
  /** Explicit package paths; win over env and default locations. */
  readonly canonPath?: string;
  readonly factsPath?: string;
  /** Environment for path overrides (default process.env). */
  readonly env?: Record<string, string | undefined>;
  /** Working directory for default-location resolution (default process.cwd()). */
  readonly cwd?: string;
  /** Explicit data root overriding env/ancestor discovery. */
  readonly dataRoot?: string;
}

/**
 * Builds the gate by loading both packages once, at wiring time. A restart
 * after the packages land re-opens the gate; there is no lazy reopen, because
 * an unevaluated publish must never be possible.
 */
export function createFoodSafetyGate(options: CreateFoodSafetyGateOptions = {}): FoodSafetyGate {
  const resolved: FoodSafetyCatalogPaths = resolveFoodSafetyCatalogPaths({
    ...(options.env !== undefined ? { env: options.env } : {}),
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
    ...(options.dataRoot !== undefined ? { dataRoot: options.dataRoot } : {}),
  });
  const paths: FoodSafetyCatalogPaths = {
    canon: options.canonPath ?? resolved.canon,
    facts: options.factsPath ?? resolved.facts,
  };
  return gateFromCatalog(loadFoodSafetyCatalog(paths));
}

/** Builds the gate from an already-decided catalog state (tests, caller-loaded data). */
export function foodSafetyGateFromCatalog(catalog: FoodSafetyCatalog): FoodSafetyGate {
  return gateFromCatalog(catalog);
}

function gateFromCatalog(catalog: FoodSafetyCatalog): FoodSafetyGate {
  if (!catalog.loaded) {
    return { requiredStages: null, closedReason: catalog.reason };
  }
  return {
    requiredStages: [foodSafetyLintStage(catalog.rulebook), compoundAllergenStage(catalog.facts, catalog.rulebook)],
    closedReason: null,
  };
}

/** One text field of a publication with its display name, for failure reasons. */
function screenableFields(publication: ScreenablePublication): ReadonlyArray<readonly [string, string]> {
  return [
    ["title", publication.title],
    ...(publication.summary !== null ? [["summary", publication.summary] as const] : []),
    ...publication.ingredientLines.map((line, i) => [`ingredient line ${i + 1}`, line] as const),
    ...publication.steps.map((step, i) => [`step ${i + 1}`, step] as const),
  ];
}

function tokens(text: string): readonly string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 0);
}

/**
 * Consecutive token n-gram containment: phrase tokens must appear in order
 * with nothing between. Token matching (not substring) so "peanut free"
 * never implies the "nut free" claim.
 */
function phraseHits(fieldTokens: readonly string[], phrase: string): boolean {
  const phraseTokens = tokens(phrase);
  if (phraseTokens.length === 0 || phraseTokens.length > fieldTokens.length) {
    return false;
  }
  outer: for (let i = 0; i <= fieldTokens.length - phraseTokens.length; i++) {
    for (let j = 0; j < phraseTokens.length; j++) {
      if (fieldTokens[i + j] !== phraseTokens[j]) {
        continue outer;
      }
    }
    return true;
  }
  return false;
}

/**
 * Stage 1 — the mandatory food-safety lint against the canonical rulebook.
 * Every rule is a deterministic function of the recipe text; a hit fails the
 * publication into the human queue with the rule's explanation.
 */
export function foodSafetyLintStage(rulebook: FoodSafetyRulebook): ScreeningStage {
  return {
    name: "food-safety-lint",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      const fields = screenableFields(publication);
      const wholeRecipe = fields.map(([, text]) => text).join("\n");
      const wholeTokens = tokens(wholeRecipe);
      const reasons: string[] = [];
      for (const rule of rulebook.rules) {
        if (rule.kind === "forbidden-terms") {
          for (const [field, text] of fields) {
            const fieldTokens = tokens(text);
            for (const term of rule.terms) {
              if (phraseHits(fieldTokens, term)) {
                reasons.push(`${rule.id}: ${rule.message} ("${term}" in ${field})`);
              }
            }
          }
        } else if (rule.kind === "claim-requires-evidence") {
          // Doneness evidence counts wherever the recipe states it, not only
          // in the field that triggered — steps are split freely.
          for (const trigger of rule.triggers) {
            if (!phraseHits(wholeTokens, trigger)) {
              continue;
            }
            const evidenced = rule.requireAny.some((source) => new RegExp(source, "i").test(wholeRecipe));
            if (!evidenced) {
              reasons.push(`${rule.id}: ${rule.message} ("${trigger}" without thermometer evidence)`);
            }
          }
        }
        // allergen-claim rules need the derived tags — enforced by the
        // compound-allergens stage below, which owns tag truth.
      }
      if (reasons.length > 0) {
        return { outcome: "fail", stage: "food-safety-lint", reasons };
      }
      return { outcome: "pass", stage: "food-safety-lint", tags: [] };
    },
  };
}

/** Canonical tag for an allergen slug, matching the catalog's tag format. */
function allergenTag(canonical: string): string {
  return `allergen-${canonical}`;
}

/**
 * Compound-allergen tagging derived from the ingredient facts: every line is
 * matched against the facts' names (multi-word compounds matched as phrases,
 * single words as tokens) and the matched entries' full allergen sets —
 * compound contributions included — are unioned into tags.
 */
export function deriveAllergenTags(facts: IngredientFacts, ingredientLines: readonly string[]): readonly string[] {
  const tags = new Set<string>();
  for (const line of ingredientLines) {
    const lineLower = line.toLowerCase();
    const lineTokens = new Set(tokens(line));
    for (const entry of facts.ingredients) {
      const hit = entry.match.some((phrase) => {
        const phraseLower = phrase.toLowerCase();
        return phraseLower.includes(" ") ? lineLower.includes(phraseLower) : lineTokens.has(phraseLower);
      });
      if (hit) {
        for (const allergen of entry.allergens) {
          tags.add(allergenTag(allergen));
        }
      }
    }
  }
  return [...tags].sort();
}

/**
 * Stage 2 — mandatory compound-allergen tagging from the ingredient facts.
 * Tagging annotates every clean publication; an allergen-free CLAIM the
 * derived tags contradict is an unsupported claim and fails the publication
 * (PLAN C: "0 unchecked allergen or diet claims").
 */
export function compoundAllergenStage(facts: IngredientFacts, rulebook: FoodSafetyRulebook): ScreeningStage {
  return {
    name: "compound-allergens",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      const tags = deriveAllergenTags(facts, publication.ingredientLines);
      const wholeTokens = tokens([publication.title, publication.summary ?? "", ...publication.ingredientLines, ...publication.steps].join("\n"));
      const reasons: string[] = [];
      for (const rule of rulebook.rules) {
        if (rule.kind !== "allergen-claim") {
          continue;
        }
        for (const claim of rule.claims) {
          const claimed = claim.phrases.some((phrase) => phraseHits(wholeTokens, phrase));
          const tagged = tags.includes(allergenTag(claim.allergen));
          if (claimed && tagged) {
            reasons.push(`${rule.id}: ${rule.message} ("${claim.phrases.join('"/"')}" claimed while ${claim.allergen} is present via ingredient facts)`);
          }
        }
      }
      if (reasons.length > 0) {
        return { outcome: "fail", stage: "compound-allergens", reasons };
      }
      return { outcome: "pass", stage: "compound-allergens", tags };
    },
  };
}
