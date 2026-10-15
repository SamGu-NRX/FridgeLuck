/**
 * Manual validators for the contract shapes the modules accept as input
 * (contracts/requests.schema.json + recipe-content.schema.json). The
 * contract-round-trip tests validate live responses against the JSON Schemas
 * with Ajv, so drift here fails a test rather than a user.
 */

import { errValidation } from "./errors.js";
import type { RecipeContent, RecipeRef, IngredientLine, StepLine } from "./contract.js";

const UNITS = new Set(["g", "kg", "ml", "l", "tsp", "tbsp", "cup", "fl-oz", "piece", "clove", "pinch", "can"]);
const SOURCES = new Set(["catalog", "user", "community", "generated"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(raw: unknown): raw is string {
  return typeof raw === "string" && UUID.test(raw);
}

function isInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value);
}

function isNullOrString(value: unknown, max: number): value is string | null {
  return value === null || (typeof value === "string" && value.length <= max);
}

function bad(message: string): never {
  throw errValidation("validation", message);
}

export function validateRecipeRef(raw: unknown): RecipeRef {
  if (typeof raw !== "object" || raw === null) {
    bad("recipeRef must be an object");
  }
  const ref = raw as Record<string, unknown>;
  const source = ref["source"];
  const id = ref["id"];
  const revision = ref["revision"];
  if (typeof source !== "string" || !SOURCES.has(source)) {
    bad("recipeRef.source must be one of catalog|user|community|generated");
  }
  if (typeof id !== "string" || id.length < 1) {
    bad("recipeRef.id must be a non-empty string");
  }
  if (!isInt(revision) || revision < 1) {
    bad("recipeRef.revision must be an integer >= 1");
  }
  for (const key of Object.keys(ref)) {
    if (key !== "source" && key !== "id" && key !== "revision") {
      bad(`recipeRef.${key} is not part of the contract`);
    }
  }
  return { source: source as RecipeRef["source"], id, revision };
}

function validateIngredientLine(raw: unknown): IngredientLine {
  if (typeof raw !== "object" || raw === null) {
    bad("each ingredient line must be an object");
  }
  const line = raw as Record<string, unknown>;
  const name = line["name"];
  if (typeof name !== "string" || name.length < 1 || name.length > 80) {
    bad("ingredient line name must be a string of 1-80 characters");
  }
  const quantity = line["quantity"];
  if (quantity !== undefined && quantity !== null && (typeof quantity !== "number" || quantity <= 0)) {
    bad("ingredient quantity must be a positive number or null");
  }
  const unit = line["unit"];
  if (unit !== undefined && unit !== null && !(typeof unit === "string" && UNITS.has(unit))) {
    bad("ingredient unit must be a contract unit or null");
  }
  const preparation = line["preparation"];
  if (preparation !== undefined && !isNullOrString(preparation, 80)) {
    bad("ingredient preparation must be a string of at most 80 characters or null");
  }
  const fdcId = line["fdcId"];
  if (fdcId !== undefined && fdcId !== null && !isInt(fdcId)) {
    bad("fdcId must be an integer or null");
  }
  for (const key of Object.keys(line)) {
    if (!["name", "quantity", "unit", "preparation", "fdcId"].includes(key)) {
      bad(`ingredient line field ${key} is not part of the contract`);
    }
  }
  return {
    name,
    quantity: (quantity as number | null) ?? null,
    unit: (unit as IngredientLine["unit"]) ?? null,
    preparation: (preparation as string | null) ?? null,
    fdcId: (fdcId as number | null) ?? null,
  };
}

function validateStep(raw: unknown): StepLine {
  if (typeof raw !== "object" || raw === null) {
    bad("each step must be an object");
  }
  const step = raw as Record<string, unknown>;
  const text = step["text"];
  if (typeof text !== "string" || text.length < 1 || text.length > 500) {
    bad("step text must be a string of 1-500 characters");
  }
  const timer = step["timerMinutes"];
  if (timer !== undefined && timer !== null && (!isInt(timer) || timer < 0)) {
    bad("step timerMinutes must be a non-negative integer or null");
  }
  for (const key of Object.keys(step)) {
    if (!["text", "timerMinutes"].includes(key)) {
      bad(`step field ${key} is not part of the contract`);
    }
  }
  return { text, timerMinutes: (timer as number | null) ?? null };
}

export function validateRecipeContent(raw: unknown): RecipeContent {
  if (typeof raw !== "object" || raw === null) {
    bad("content must be an object");
  }
  const content = raw as Record<string, unknown>;
  const title = content["title"];
  if (typeof title !== "string" || title.length < 1 || title.length > 120) {
    bad("title must be a string of 1-120 characters");
  }
  const description = content["description"];
  if (description !== undefined && !isNullOrString(description, 280)) {
    bad("description must be a string of at most 280 characters or null");
  }
  const servings = content["servings"];
  if (!isInt(servings) || servings < 1 || servings > 24) {
    bad("servings must be an integer of 1-24");
  }
  const timeMinutes = content["timeMinutes"];
  if (timeMinutes !== undefined && timeMinutes !== null && (!isInt(timeMinutes) || timeMinutes < 1 || timeMinutes > 1440)) {
    bad("timeMinutes must be an integer of 1-1440 or null");
  }
  const ingredientRaw = content["ingredientLines"];
  if (!Array.isArray(ingredientRaw) || ingredientRaw.length < 1 || ingredientRaw.length > 64) {
    bad("ingredientLines must be an array of 1-64 lines");
  }
  const stepsRaw = content["steps"];
  if (!Array.isArray(stepsRaw) || stepsRaw.length < 1 || stepsRaw.length > 64) {
    bad("steps must be an array of 1-64 steps");
  }
  const equipment = content["equipment"];
  // Caps mirror schemas/recipe-content.schema.json (maxItems 16, item ≤ 40).
  if (!Array.isArray(equipment) || equipment.length > 16 || equipment.some((e) => typeof e !== "string" || e.length > 40)) {
    bad("equipment must be an array of at most 16 strings of at most 40 characters");
  }
  const dietaryTags = content["dietaryTags"];
  // Caps mirror schemas/recipe-content.schema.json (maxItems 12, item ≤ 24).
  if (!Array.isArray(dietaryTags) || dietaryTags.length > 12 || dietaryTags.some((t) => typeof t !== "string" || t.length > 24)) {
    bad("dietaryTags must be an array of at most 12 strings of at most 24 characters");
  }
  for (const key of Object.keys(content)) {
    if (!["title", "description", "servings", "timeMinutes", "ingredientLines", "steps", "equipment", "dietaryTags"].includes(key)) {
      bad(`content field ${key} is not part of the contract`);
    }
  }
  return {
    title,
    description: (description as string | null) ?? null,
    servings,
    timeMinutes: (timeMinutes as number | null) ?? null,
    ingredientLines: ingredientRaw.map(validateIngredientLine),
    steps: stepsRaw.map(validateStep),
    equipment: equipment as string[],
    dietaryTags: dietaryTags as string[],
  };
}
