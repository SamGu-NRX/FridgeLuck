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
  FOOD_SAFETY_CLASSES,
  loadFoodSafetyCatalog,
  resolveFoodSafetyCatalogPaths,
  type FoodSafetyCatalog,
  type FoodSafetyCatalogPaths,
  type FoodSafetyClass,
  type FoodSafetyRulebook,
  type IngredientFacts,
  type MinCookingTempRule,
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
        } else if (rule.kind === "min-cooking-temp") {
          // The evidence rule above checks the FORM of a doneness claim;
          // this rule checks the VALUE: a stated internal temperature must
          // reach the reviewed minimum for its food class (blocker 2).
          for (const reason of minCookingTempReasons(rule, fields)) {
            reasons.push(reason);
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

/** A numeric temperature stated in recipe text, normalized to °F. */
export interface StatedTemperature {
  /** The matched text, e.g. "74°C" — quoted in failure reasons. */
  readonly raw: string;
  /** The stated value converted to °F (Celsius converts exactly: ×9/5+32). */
  readonly valueF: number;
  /** The unit as stated. */
  readonly unit: "F" | "C";
}

/**
 * Unit-bearing temperature statements, e.g. "165°F", "74 °C", "160 degrees
 * F". Boundaries on both ends so a digit inside a larger number or a unit
 * letter inside a word never matches. Fahrenheit is matched with or
 * without the degree marker ("165F" is a real doneness claim); Celsius
 * requires the marker ("74°C", "74 degrees C") — a bare "74 c" is far more
 * likely cup shorthand than Celsius, and a false temperature claim would
 * wrongly fail honest recipes.
 */
const TEMPERATURE_F_PATTERN = /(?<![a-z0-9])(\d{1,3})(?:\.\d+)?\s*(?:°\s*|deg(?:rees)?\s+)?f(?:ahrenheit)?(?![a-z0-9])/gi;
const TEMPERATURE_C_PATTERN = /(?<![a-z0-9])(\d{1,3})(?:\.\d+)?\s*(?:°\s*|deg(?:rees)?\s+)c(?:elsius)?(?![a-z0-9])/gi;

/**
 * Sentences whose topic is cooling, thawing or storage — a different
 * rulebook topic with no class floors ("chill to 40°F" is correct guidance,
 * not a doneness claim).
 */
const COOLING_CONTEXT =
  /(?<![a-z0-9])(cool(?:ed|er|ing|s)?|chill(?:ed|s|ing)?|refrigerat(?:e|ed|es|ing|ion)|fridge|freez(?:e|es|ed|ing|er)|thaw(?:ed|ing|s)?|defrost(?:ed|ing|s)?|marinat(?:e|ed|es|ing)|stor(?:e|es|ed|ing|age)|room temperature)(?![a-z0-9])/i;

/**
 * Doneness-domain stated temperatures in a text: unit-bearing values below
 * 200°F. At 200°F and above the number is a cooking-appliance setting
 * ("preheat the oven to 425°F"), not an internal-temperature claim — and
 * every reviewed class minimum sits far below it anyway.
 */
export function statedCookingTemperatures(text: string): readonly StatedTemperature[] {
  const stated: StatedTemperature[] = [];
  for (const pattern of [TEMPERATURE_F_PATTERN, TEMPERATURE_C_PATTERN]) {
    for (const match of text.matchAll(pattern)) {
      const value = Number.parseFloat(match[1] ?? "");
      const celsius = match[0].toLowerCase().includes("c");
      const valueF = celsius ? (value * 9) / 5 + 32 : value;
      if (Number.isFinite(valueF) && valueF < 200) {
        stated.push({ raw: match[0].trim(), valueF, unit: celsius ? "C" : "F" });
      }
    }
  }
  return stated;
}

/** One keyword hit in text, as a character span over the lowercased text. */
interface ClassHit {
  readonly cls: FoodSafetyClass;
  readonly start: number;
  readonly end: number;
}

/** A keyword matched as a whole token/phrase: boundaries, spaces flex. */
function keywordPattern(keyword: string): RegExp {
  const literal = keyword
    .replace(/[.*+?^${}()|[\]\\]/g, (ch) => `\\${ch}`)
    .replace(/\s+/g, "\\s+");
  return new RegExp(`(?<![a-z0-9])${literal}(?![a-z0-9])`, "gi");
}

/**
 * The food classes the text names, per the reviewed keywords. A longer
 * keyword shadows a shorter one it contains — the rulebook is explicit
 * that "ground poultry"/"turkey mince" keep the 165°F poultry minimum and
 * must not fall into the 160°F ground-meat class via their "mince".
 */
export function attributedClasses(text: string, rule: MinCookingTempRule): ReadonlySet<FoodSafetyClass> {
  const lower = text.toLowerCase();
  const hits: ClassHit[] = [];
  for (const cls of FOOD_SAFETY_CLASSES) {
    for (const keyword of rule.classKeywords[cls]) {
      for (const match of lower.matchAll(keywordPattern(keyword))) {
        const start = match.index ?? 0;
        hits.push({ cls, start, end: start + match[0].length });
      }
    }
  }
  const classes = new Set<FoodSafetyClass>();
  for (const hit of hits) {
    const shadowed = hits.some(
      (other) => other.cls !== hit.cls && other.start <= hit.start && other.end >= hit.end && other.end - other.start > hit.end - hit.start,
    );
    if (!shadowed) {
      classes.add(hit.cls);
    }
  }
  return classes;
}

/** Sentence pieces of a field: split after sentence enders and newlines. */
function sentences(text: string): readonly string[] {
  return text
    .split(/[.!?;\n]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** Checkable label for a stated temperature, with the °F conversion for Celsius. */
function statedLabel(temperature: StatedTemperature): string {
  return temperature.unit === "C" ? `"${temperature.raw}" (=${temperature.valueF.toFixed(1)}°F)` : `"${temperature.raw}"`;
}

/**
 * The numeric cooking-temperature check. Each stated doneness temperature
 * is attributed the classes named in its own sentence, or, when the
 * sentence names no food, the classes named anywhere in the publication; a
 * class is satisfied when ONE stated temperature in the scope reaches its
 * minimum ("the chicken to 165 and the steak to 145" passes; "the chicken
 * to 145" does not). A stated temperature with no attributable class
 * anywhere must still reach the lowest reviewed minimum — no canonical
 * class is safe below it. Boundary stated honestly: this is a text lint;
 * genuinely raw preparations (tartare, cured fish) fail into human review
 * rather than publish silently.
 */
export function minCookingTempReasons(rule: MinCookingTempRule, fields: ReadonlyArray<readonly [string, string]>): readonly string[] {
  const reasons: string[] = [];
  const publicationClasses = new Set<FoodSafetyClass>();
  for (const [, text] of fields) {
    for (const cls of attributedClasses(text, rule)) {
      publicationClasses.add(cls);
    }
  }
  const lowestFloor = Math.min(...FOOD_SAFETY_CLASSES.map((cls) => rule.minimumsF[cls]));
  for (const [field, text] of fields) {
    for (const sentence of sentences(text)) {
      if (COOLING_CONTEXT.test(sentence)) {
        continue;
      }
      const stated = statedCookingTemperatures(sentence);
      if (stated.length === 0) {
        continue;
      }
      const sentenceClasses = attributedClasses(sentence, rule);
      const scope = sentenceClasses.size > 0 ? sentenceClasses : publicationClasses;
      if (scope.size === 0) {
        for (const temperature of stated) {
          if (temperature.valueF < lowestFloor) {
            reasons.push(`${rule.id}: stated ${statedLabel(temperature)} is below the lowest reviewed class minimum of ${lowestFloor}°F (${statedLabel(temperature)} in ${field})`);
          }
        }
        continue;
      }
      for (const cls of FOOD_SAFETY_CLASSES) {
        if (!scope.has(cls)) {
          continue;
        }
        const minimum = rule.minimumsF[cls];
        if (!stated.some((temperature) => temperature.valueF >= minimum)) {
          const statedList = stated.map(statedLabel).join(", ");
          reasons.push(`${rule.id}: no stated temperature reaches the reviewed ${cls} minimum of ${minimum}°F from the canonical rulebook (stated ${statedList} in ${field})`);
        }
      }
    }
  }
  return reasons;
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
