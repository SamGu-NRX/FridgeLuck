import { Type, type GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import {
  RecipeRejectedError,
  type RecipeGenerationRequest,
  type RecipeGenerationResponse
} from "../types/contracts.js";

/**
 * Staple allowances the model may use even when they were not in the scan.
 * Frozen set: water, salt, black pepper, cooking oil.
 *
 * Allowances are NOT assertions that the Kitchen currently stocks them:
 * they are never validated against inventory and never reported as scanned
 * foods. Explicit exclusions (avoidIngredients) override these allowances.
 */
export const RECIPE_STAPLE_INGREDIENTS: readonly string[] = [
  "water",
  "salt",
  "black pepper",
  "cooking oil"
];

/**
 * Limited recognized-food lexicon for the lexical text screen over
 * ingredientsUsed entries, the title, and the instructions.
 *
 * What this screen covers (exactly):
 * - Whole-word, case-insensitive mentions of these foods, with simple
 *   plural forms (egg -> eggs, tomato -> tomatoes), anywhere in the model's
 *   ingredientsUsed entries, title, or instructions text.
 * - It exists for the observed failure mode where the model omits an
 *   unlisted food (e.g. chicken) from ingredientsUsed but still names it
 *   in the instructions or title.
 * - Independent of the lexicon, every DECLARED ingredientsUsed entry must
 *   still be covered by a supplied food or staple.
 *
 * What this screen does NOT cover:
 * - Foods outside this frozen lexicon (e.g. mango, miso, bok choy) are
 *   only screened when the model declares them in ingredientsUsed.
 * - Synonyms, slang, brand names, compounds and hyphenations ("free-range"),
 *   derived forms beyond simple plurals ("berries" vs "berry"), and
 *   transliterations.
 * - `ingredientsUsed` is a model assertion, not independent evidence of
 *   what is actually in the dish.
 * - This is NOT an allergy-safety or complete grounding guarantee.
 */
export const RECIPE_RECOGNIZED_FOOD_LEXICON: readonly string[] = [
  "chicken", "beef", "pork", "fish", "salmon", "tuna", "shrimp", "tofu",
  "egg", "milk", "cheese", "butter", "yogurt", "rice", "pasta", "noodles",
  "bread", "potato", "onion", "garlic", "tomato", "carrot", "spinach",
  "mushroom", "broccoli", "bacon", "ham", "beans", "lentils", "quinoa",
  "oats", "corn", "cucumber", "zucchini", "eggplant", "cauliflower",
  "lettuce", "cabbage", "kale", "peas"
];

/**
 * Sensible ranges for model-provided numerics. Values outside the range
 * are rejected during decoding — never clamped, never defaulted.
 */
const SENSIBLE_LIMITS = {
  timeMinutes: { min: 0, minExclusive: true, max: 1440 },
  servings: { min: 1, minExclusive: false, max: 100 },
  estimatedCaloriesPerServing: { min: 0, minExclusive: true, max: 10000 }
} as const;

type SensibleField = keyof typeof SENSIBLE_LIMITS;

function decodeError(detail: string): Error {
  // Static, public-safe message: field names only — never values, never
  // generated text, request contents/photos, or provider messages.
  return new Error(`Malformed recipe response from model: ${detail}.`);
}

function normalizeTerm(term: string): string {
  return term.trim().toLowerCase().replace(/\s+/g, " ");
}

function escapeRegex(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Word-boundary, case-insensitive matcher with simple plural forms.
 * "egg" matches "eggs" but never "eggplant"; "beans" also matches "bean";
 * "tomatoes" also matches "tomato".
 */
function termMatcher(term: string): RegExp {
  const normalized = normalizeTerm(term);
  if (normalized.length === 0) return /(?!)/;
  const base = normalized.split(" ").map(escapeRegex).join("\\s+");
  const alternatives = [`${base}(?:es|s)?`];
  if (base.endsWith("es")) {
    alternatives.push(`${base.slice(0, -2)}(?:es|s)?`);
  } else if (base.endsWith("s")) {
    alternatives.push(`${base.slice(0, -1)}(?:es|s)?`);
  }
  return new RegExp(`\\b(?:${alternatives.join("|")})\\b`, "i");
}

interface IngredientPolicy {
  avoided: string[];
  allowed: string[];
}

/**
 * Builds the policy from the request. The request itself is typed, but the
 * HTTP layer forwards client JSON, so string filtering stays defensive.
 * Exclusions override staples and supplied foods: the avoided list is
 * screened independently of the allowed list.
 */
function ingredientPolicyFor(request: RecipeGenerationRequest): IngredientPolicy {
  const rawAvoided = Array.isArray(request.avoidIngredients)
    ? request.avoidIngredients
    : [];
  const avoided = rawAvoided
    .filter((term): term is string => typeof term === "string")
    .map(normalizeTerm)
    .filter((term) => term.length > 0);

  const rawSupplied = Array.isArray(request.ingredientNames)
    ? request.ingredientNames
    : [];
  const supplied = rawSupplied
    .filter((name): name is string => typeof name === "string")
    .map(normalizeTerm)
    .filter((name) => name.length > 0);

  return {
    avoided,
    allowed: [...supplied, ...RECIPE_STAPLE_INGREDIENTS.map(normalizeTerm)]
  };
}

/**
 * Whether a food mention is covered by the allowed set: equal to an allowed
 * term, an allowed term's word inside it ("chicken" within allowed
 * "chicken breast"), or an allowed term within its words ("bell pepper"
 * covering the entry "red bell peppers").
 */
function isAllowedFood(food: string, policy: IngredientPolicy): boolean {
  return policy.allowed.some((allowed) => {
    if (allowed === food) return true;
    return (
      termMatcher(allowed).test(food) || termMatcher(food).test(allowed)
    );
  });
}

function firstAvoidedMention(
  text: string,
  policy: IngredientPolicy
): string | undefined {
  return policy.avoided.find((term) => termMatcher(term).test(text));
}

function firstUnlistedFoodMention(
  text: string,
  policy: IngredientPolicy
): string | undefined {
  return RECIPE_RECOGNIZED_FOOD_LEXICON.find(
    (food) => termMatcher(food).test(text) && !isAllowedFood(food, policy)
  );
}

/**
 * Ingredient-policy screen over every text surface the model returns:
 * each ingredientsUsed entry, the title, and the instructions.
 * 1. Any avoided mention -> uses_avoided_ingredient (exclusions override).
 * 2. Any declared entry not covered by supplied foods/staples
 *    -> uses_unlisted_ingredient.
 * 3. Limited recognized-food text screen -> uses_unlisted_ingredient.
 */
function screenIngredientPolicy(
  recipe: RecipeGenerationResponse,
  policy: IngredientPolicy
): void {
  const surfaces: string[] = [
    ...recipe.ingredientsUsed,
    recipe.title,
    recipe.instructions
  ];

  for (const text of surfaces) {
    if (firstAvoidedMention(text, policy)) {
      throw new RecipeRejectedError("uses_avoided_ingredient");
    }
  }
  for (const entry of recipe.ingredientsUsed) {
    if (!isAllowedFood(entry, policy)) {
      throw new RecipeRejectedError("uses_unlisted_ingredient");
    }
  }
  for (const text of surfaces) {
    if (firstUnlistedFoodMention(text, policy)) {
      throw new RecipeRejectedError("uses_unlisted_ingredient");
    }
  }
}

function requiredNonEmptyString(
  field: Record<string, unknown>,
  key: string
): string {
  const value = field[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw decodeError(`'${key}' must be a non-empty string`);
  }
  return value;
}

function requiredStringArray(
  field: Record<string, unknown>,
  key: string
): string[] {
  const value = field[key];
  if (!Array.isArray(value)) {
    throw decodeError(`'${key}' must be an array of strings`);
  }
  const entries: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") {
      throw decodeError(`'${key}' must be an array of strings`);
    }
    const normalized = item.trim();
    if (normalized.length > 0) entries.push(normalized);
  }
  return entries;
}

function sensibleNumber(
  field: Record<string, unknown>,
  key: SensibleField
): number {
  const value = field[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw decodeError(`'${key}' must be a finite number`);
  }
  const limits = SENSIBLE_LIMITS[key];
  const aboveMin = limits.minExclusive ? value > limits.min : value >= limits.min;
  if (!aboveMin || value > limits.max) {
    throw decodeError(`'${key}' is outside the sensible range`);
  }
  return value;
}

/**
 * Decodes the model's JSON as UNTRUSTED INPUT: required strings, a required
 * string array, and finite, sensible numerics are all validated before any
 * use. There are no fallbacks and no clamping — a missing, mistyped,
 * non-finite, or out-of-range field fails closed with a static,
 * public-safe error (field name only, never the value).
 */
function decodeRecipeJson(raw: string | undefined): RecipeGenerationResponse {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw decodeError("no text content in response");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw decodeError("response is not valid JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw decodeError("response is not a JSON object");
  }
  const field = parsed as Record<string, unknown>;

  const title = requiredNonEmptyString(field, "title");
  const instructions = requiredNonEmptyString(field, "instructions");
  const ingredientsUsed = requiredStringArray(field, "ingredientsUsed");

  return {
    title: title.trim(),
    timeMinutes: sensibleNumber(field, "timeMinutes"),
    servings: sensibleNumber(field, "servings"),
    instructions,
    estimatedCaloriesPerServing: sensibleNumber(
      field,
      "estimatedCaloriesPerServing"
    ),
    ingredientsUsed
  };
}

function toInlineImagePart(photoBase64JPEG?: string) {
  if (!photoBase64JPEG) return [];
  return [
    {
      inlineData: {
        mimeType: "image/jpeg",
        data: photoBase64JPEG
      }
    }
  ];
}

export async function generateRecipe(
  ai: GoogleGenAI,
  config: AppConfig,
  request: RecipeGenerationRequest
): Promise<RecipeGenerationResponse> {
  const dietaryRestrictions = request.dietaryRestrictions ?? [];
  const restrictionsText = dietaryRestrictions.length > 0 ? dietaryRestrictions.join(", ") : "none";

  const rawAvoided = Array.isArray(request.avoidIngredients)
    ? request.avoidIngredients
    : [];
  const avoidIngredients = rawAvoided
    .filter((term): term is string => typeof term === "string")
    .map((term) => term.trim())
    .filter((term) => term.length > 0);
  const avoidText = avoidIngredients.length > 0 ? avoidIngredients.join(", ") : "none";

  const staplesText = RECIPE_STAPLE_INGREDIENTS.join(", ");

  const contents = [
    {
      role: "user",
      parts: [
        {
          text:
            `You are a practical smart-fridge cooking assistant. Use ONLY the supplied foods from ingredients_from_scan, plus these staple allowances: ${staplesText}. ` +
            "Staple allowances mean you may use these staples; they do not assert that the kitchen currently stocks them. " +
            "The avoid_ingredients list overrides staple allowances and supplied foods: never use an avoided ingredient in any form. " +
            "Do not invent, add, or imply any other ingredients. Be concise and keep calories realistic. " +
            "List every ingredient you actually use, including staples and seasonings, in ingredients_used."
        },
        {
          text: `ingredients_from_scan: ${request.ingredientNames.join(", ")}`
        },
        {
          text: `dietary_restrictions: ${restrictionsText}`
        },
        {
          text: `avoid_ingredients: ${avoidText}`
        },
        {
          text: `scan_confidence_score: ${request.scanConfidenceScore ?? 0.0}`
        },
        ...toInlineImagePart(request.photoBase64JPEG)
      ]
    }
  ];

  const response = await ai.models.generateContent({
    model: config.recipeModel,
    contents,
    config: {
      responseMimeType: "application/json",
      responseSchema: {
        type: Type.OBJECT,
        properties: {
          title: { type: Type.STRING },
          timeMinutes: { type: Type.INTEGER },
          servings: { type: Type.INTEGER },
          instructions: { type: Type.STRING },
          estimatedCaloriesPerServing: { type: Type.INTEGER },
          ingredientsUsed: { type: Type.ARRAY, items: { type: Type.STRING } }
        },
        required: [
          "title",
          "timeMinutes",
          "servings",
          "instructions",
          "estimatedCaloriesPerServing",
          "ingredientsUsed"
        ]
      }
    }
  });

  const recipe = decodeRecipeJson(response.text);
  screenIngredientPolicy(recipe, ingredientPolicyFor(request));
  return recipe;
}
