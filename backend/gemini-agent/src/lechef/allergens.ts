/**
 * Allergen recheck for substitutions (SPEC 3.1).
 *
 * Every substitution rechecks ALL eaters' restrictions, including compound
 * ingredients — soy sauce contains wheat, pesto contains nuts. The compound
 * map below is a small reviewed interim set so the ALWAYS-recheck rule is
 * exercisable on alpha; a future data/substitutions rulebook supersedes it
 * (see substitutions.ts).
 */

import type { Eater } from "./types.js";

/** Compound ingredients → the restriction tokens they carry. Reviewed interim set. */
const COMPOUND_INGREDIENTS: ReadonlyMap<string, readonly string[]> = new Map([
  ["soy-sauce", ["wheat", "gluten", "soy"]],
  ["teriyaki-sauce", ["wheat", "gluten", "soy"]],
  ["worcestershire-sauce", ["fish", "soy"]],
  ["pesto", ["tree nuts", "milk"]],
  ["hummus", ["sesame"]],
  ["marzipan", ["tree nuts", "egg"]],
  ["mayonnaise", ["egg"]],
  ["sriracha", ["soy"]],
  ["hoisin-sauce", ["soy", "wheat"]],
  ["fish-sauce", ["fish"]]
]);

/** Direct restriction tokens an ingredient itself carries (dairy-adjacent staples etc.). */
const DIRECT_INGREDIENT_RESTRICTIONS: ReadonlyMap<string, readonly string[]> = new Map([
  ["flour", ["wheat", "gluten"]],
  ["bread", ["wheat", "gluten"]],
  ["pasta", ["wheat", "gluten"]],
  ["milk", ["milk"]],
  ["butter", ["milk"]],
  ["parmesan", ["milk"]],
  ["peanuts", ["peanuts"]],
  ["peanut-butter", ["peanuts"]],
  ["almonds", ["tree nuts"]],
  ["walnuts", ["tree nuts"]],
  ["cashews", ["tree nuts"]],
  ["shrimp", ["shellfish"]],
  ["salmon", ["fish"]],
  ["cod", ["fish"]],
  ["egg", ["egg"]],
  ["eggs", ["egg"]],
  ["tofu", ["soy"]],
  ["sesame-oil", ["sesame"]]
]);

function normalize(token: string): string {
  return token.trim().toLowerCase();
}

/** The restriction tokens an ingredient carries, direct plus via compound composition. */
export function restrictionTokensFor(ingredientId: string): readonly string[] {
  const id = normalize(ingredientId);
  const direct = DIRECT_INGREDIENT_RESTRICTIONS.get(id) ?? [];
  const compound = COMPOUND_INGREDIENTS.get(id) ?? [];
  const seen = new Set<string>();
  for (const token of [...direct, ...compound]) seen.add(normalize(token));
  return [...seen];
}

/**
 * Recheck one ingredient against all eaters' explicit restrictions.
 * A violation is reported when a restriction token matches an ingredient
 * token in either direction (e.g. "nuts" matches "tree nuts").
 */
export function allergenViolations(
  ingredientId: string,
  eaters: readonly Eater[]
): readonly string[] {
  const carried = restrictionTokensFor(ingredientId).map(normalize);
  if (carried.length === 0) return [];
  const violations: string[] = [];
  for (const eater of eaters) {
    for (const restriction of eater.restrictions) {
      const r = normalize(restriction);
      const hit = carried.some(
        (token) => token.includes(r) || r.includes(token)
      );
      if (hit) {
        violations.push(
          `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} carries ${carried.join(", ")}`
        );
      }
    }
  }
  return violations;
}

/**
 * Recheck a swap (from → to) against all eaters. BOTH sides are rechecked:
 * dropping the original can matter as much as adding the substitute when a
 * restriction relies on its absence.
 */
export function recheckSwapAllergens(
  from: string,
  to: string,
  eaters: readonly Eater[]
): readonly string[] {
  return [...allergenViolations(to, eaters), ...allergenViolations(from, eaters)];
}
