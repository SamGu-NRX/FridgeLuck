/**
 * Ingredient-facts conformance seam.
 *
 * The recipe screen must decide whether an ingredient may be used given the
 * household's exclusions (avoided substances) and dietary restrictions.
 * Name matching alone cannot do this: an ingredient whose COMPOSITION
 * contains an excluded substance ("satay sauce" contains peanut; generic
 * tamari contains soy and wheat) is excluded even though its name never
 * mentions the substance, and a dietary restriction ("vegetarian") excludes
 * ingredients no literal list names.
 *
 * That knowledge lives in the `data/ingredient-facts` dataset and its
 * evaluator (branch `overhaul/ingredient-facts`, FLIngredientFacts). Until
 * that package lands, this module is the single seam it drops into:
 *
 * - `IngredientFactsEvaluator` is the contract the package implements
 *   (`evaluate` returning allowed | violated | unknown).
 * - `ingredientFactsEvaluator` is the ONE binding call sites use. Swapping
 *   in the package-backed evaluator is a one-line change here; no call site
 *   changes.
 * - `failClosedIngredientFactsEvaluator` is the placeholder: it carries NO
 *   composition data, so whenever any restriction is active it answers
 *   `unknown` — and unknown is NEVER allowed. Callers must fail closed.
 */

/** Active exclusions for one evaluation. Both sets hold normalized terms. */
export interface Restrictions {
  /**
   * Substances that must not be present in any form, including inside
   * compounds. Carries explicit avoid-ingredients plus any allergen-class
   * restrictions the client sends.
   */
  readonly allergens: ReadonlySet<string>;
  /**
   * Dietary restrictions. Until the FLRestrictions vocabulary is available,
   * tokens stay verbatim: an unrecognized token must remain active rather
   * than be silently ignored — it fails closed in the evaluator.
   */
  readonly diets: ReadonlySet<string>;
}

/**
 * Combines restriction sets (e.g. every eater's restrictions for a household
 * session): an ingredient must satisfy the UNION of all restrictions.
 */
export function unionRestrictions(rs: readonly Restrictions[]): Restrictions {
  const allergens = new Set<string>();
  const diets = new Set<string>();
  for (const r of rs) {
    for (const allergen of r.allergens) allergens.add(allergen);
    for (const diet of r.diets) diets.add(diet);
  }
  return { allergens, diets };
}

/**
 * Builds the restrictions for one request from defensively filtered terms.
 * Explicit avoid terms are allergen-class exclusions (a substance that must
 * not appear, in compound form or otherwise); dietary-restriction tokens are
 * diet-class. Without the FLRestrictions vocabulary a restriction token
 * cannot be classified further — keeping it in `diets` keeps it active, so
 * an unrecognized token fails closed instead of being ignored.
 */
export function parseRestrictions(
  avoidTerms: readonly string[],
  dietaryRestrictions: readonly string[]
): Restrictions {
  return {
    allergens: new Set(avoidTerms),
    diets: new Set(dietaryRestrictions)
  };
}

/**
 * Verdict for one ingredient against active restrictions. The `unknown`
 * state is load-bearing: a missing, unsourced, or variable property means we
 * do not know — callers must treat it as violating, never as allowed.
 */
export type IngredientFactsEvaluation =
  | {
      kind: "allowed";
      /** What the clearance is based on (dataset keys, label evidence). */
      evidence: readonly string[];
    }
  | {
      kind: "violated";
      /** Which restriction class fired: allergen exclusions or diets. */
      by: "allergen" | "diet";
      /** Static, public-safe explanation (no request content). */
      reason: string;
      /** The excluded substance or restriction that the ingredient conflicts with. */
      component: string;
    }
  | {
      kind: "unknown";
      /** What is missing before the ingredient can be evaluated. */
      missing: readonly string[];
    };

/** Provider seam: answers ingredient conformance against restrictions. */
export interface IngredientFactsEvaluator {
  /**
   * MUST be total and pure: no I/O, no throwing on any (ingredient,
   * restrictions) pair. `unknown` NEVER counts as allowed.
   */
  evaluate(ingredient: string, restrictions: Restrictions): IngredientFactsEvaluation;
}

/**
 * Placeholder evaluator used until `data/ingredient-facts` lands. It has NO
 * composition data, so:
 * - no active restrictions -> vacuously allowed (nothing to enforce);
 * - any active restriction -> `unknown`: the composition of any ingredient
 *   cannot be verified, so it must be treated as excluded, never served.
 */
export const failClosedIngredientFactsEvaluator: IngredientFactsEvaluator = {
  evaluate(
    ingredient: string,
    restrictions: Restrictions
  ): IngredientFactsEvaluation {
    if (restrictions.allergens.size === 0 && restrictions.diets.size === 0) {
      return { kind: "allowed", evidence: [] };
    }
    return {
      kind: "unknown",
      missing: [
        `ingredient-facts dataset (composition of "${ingredient}" is not resolvable yet)`
      ]
    };
  }
};

/**
 * The binding call sites use. Until the package lands this is the fail-closed
 * placeholder; when `data/ingredient-facts` lands, assign the package-backed
 * evaluator here. No call site changes.
 */
export const ingredientFactsEvaluator: IngredientFactsEvaluator =
  failClosedIngredientFactsEvaluator;
