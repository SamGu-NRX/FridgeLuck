/**
 * The food-safety gate for test setups. Loading the canon/ingredient-facts
 * fixture packages here is the expected and correct wiring: the fail-closed
 * default holds in production, and suites that publish prove legitimate
 * flows work with the gates ACTIVE — never around them.
 */
import { fileURLToPath } from "node:url";
import { createFoodSafetyGate, type FoodSafetyGate } from "../../community/foodSafety/gate.js";

/** The fixture packages, standing in for overhaul/food-safety-canon and overhaul/ingredient-facts. */
export const FOOD_SAFETY_FIXTURE_DIR = fileURLToPath(new URL("fixtures/food-safety", import.meta.url));

/** A gate opened on the fixture canon + ingredient facts (loaded in test setup). */
export function fixtureFoodSafetyGate(): FoodSafetyGate {
  return createFoodSafetyGate({
    canonPath: `${FOOD_SAFETY_FIXTURE_DIR}/canon.json`,
    factsPath: `${FOOD_SAFETY_FIXTURE_DIR}/ingredient-facts.json`,
  });
}

/** A gate that failed closed: the packages are not loadable at these paths. */
export function closedFoodSafetyGate(): FoodSafetyGate {
  return createFoodSafetyGate({
    canonPath: "/nonexistent/food-safety-canon.json",
    factsPath: "/nonexistent/ingredient-facts.json",
  });
}
