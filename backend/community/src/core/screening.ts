/**
 * Automated screening (SPEC §6.5): three deterministic checks run on every
 * publish. No LLM anywhere in the moderation path; every stage is a function
 * of text. A blocking result sends the publication to the human queue —
 * overridable only by an operator, never by resubmission spam.
 *
 * Ported in spirit from PR #104 `explore/screening.ts` (personal-data
 * patterns, fail-closed pipeline shape); the food-safety lint and allergen
 * stages are re-implemented here because PR #126/#127's data packages are not
 * on this base branch. The pipeline therefore runs a self-contained rule set
 * and stays fail-closed: when `screeningPackagesLoaded` is false the publish
 * route refuses with 503 rather than publishing unlinted (SPEC §2.3, PR #104
 * behaviour kept).
 */

import { createHash } from "node:crypto";
import type { AllergenTag, RecipeContent, ScreeningCheck, ScreeningVerdictKind } from "./contract.js";

export interface ScreeningOutcomeResult {
  readonly check: ScreeningCheck;
  readonly verdict: ScreeningVerdictKind;
  readonly detail: string | null;
}

export interface ScreeningResult {
  /** Any blocking verdict → publication goes to the human queue. */
  readonly blocked: boolean;
  /** A non-blocking note pending confirmation (e.g. unresolved allergen). */
  readonly flagged: boolean;
  readonly flaggedTag: AllergenTag | null;
  readonly outcomes: readonly ScreeningOutcomeResult[];
  readonly allergenTags: readonly AllergenTag[];
}

/** A stable hash of the exact content a pipeline run judged; approval consults it (PR #104's content-hash-bound approvals). */
export function contentHashOf(content: RecipeContent): string {
  return createHash("sha256").update(JSON.stringify(content)).digest("hex");
}

/** Stage names the spec lists (contracts/moderation-case.schema.json). */
export const SCREENING_CHECKS = ["food-safety-lint", "compound-allergens", "personal-data"] as const;

/**
 * The mandatory stages no human decision may overrule (the food-safety gate
 * is fail-closed, SPEC §2.3). Approval of a queued publication requires a
 * passing lint at the exact content hash.
 */
export const MANDATORY_STAGES: readonly ScreeningCheck[] = ["food-safety-lint"];

interface IngredientFact {
  readonly allergens: readonly AllergenTag[];
}

/** Small deterministic ingredient-facts table (burst5 stand-in for PR #127's package). */
const INGREDIENT_FACTS: Readonly<Record<string, IngredientFact>> = {
  milk: { allergens: ["milk"] },
  "whole milk": { allergens: ["milk"] },
  butter: { allergens: ["milk"] },
  cheese: { allergens: ["milk"] },
  yogurt: { allergens: ["milk"] },
  cream: { allergens: ["milk"] },
  egg: { allergens: ["eggs"] },
  eggs: { allergens: ["eggs"] },
  flour: { allergens: ["wheat"] },
  wheat: { allergens: ["wheat"] },
  bread: { allergens: ["wheat"] },
  pasta: { allergens: ["wheat"] },
  peanut: { allergens: ["peanuts"] },
  peanuts: { allergens: ["peanuts"] },
  "peanut butter": { allergens: ["peanuts"] },
  almond: { allergens: ["tree-nuts"] },
  almonds: { allergens: ["tree-nuts"] },
  walnut: { allergens: ["tree-nuts"] },
  walnuts: { allergens: ["tree-nuts"] },
  cashew: { allergens: ["tree-nuts"] },
  "cashew nuts": { allergens: ["tree-nuts"] },
  soy: { allergens: ["soy"] },
  tofu: { allergens: ["soy"] },
  "soy sauce": { allergens: ["soy", "wheat"] },
  fish: { allergens: ["fish"] },
  salmon: { allergens: ["fish"] },
  tuna: { allergens: ["fish"] },
  shrimp: { allergens: ["shellfish"] },
  prawn: { allergens: ["shellfish"] },
  prawns: { allergens: ["shellfish"] },
  sesame: { allergens: ["sesame"] },
  "sesame oil": { allergens: ["sesame"] },
  mustard: { allergens: ["mustard"] },
  wine: { allergens: ["sulphites"] },
  "dried apricot": { allergens: ["sulphites"] },
};

/** Animal proteins that must show a cooking step (burst5 stand-in for PR #126's rulebook). */
const RAW_PROTEIN_TERMS = ["chicken", "pork", "beef", "lamb", "turkey", "salmon", "tuna", "shrimp", "prawn", "fish", "egg"];
const COOKING_TERMS = ["cook", "bake", "fry", "sauté", "saute", "simmer", "grill", "roast", "boil", "poach", "sear", "steam"];
const COOKING_TEMPERATURE = /(1[5-9]\d|2\d\d|[6-9]\d)\s*°?\s*[cf]\b/i;

export class ScreeningPipeline {
  constructor(private readonly packagesLoaded: boolean) {}

  run(content: RecipeContent): ScreeningResult {
    if (!this.packagesLoaded) {
      // Fail closed: the caller turns this into 503; nothing was screened, so
      // nothing may be published.
      throw new Error("screening packages are unloaded");
    }
    const outcomes: ScreeningOutcomeResult[] = [];
    const allergenTags = this.allergenStage(content, outcomes);
    this.foodSafetyStage(content, outcomes);
    const personalDataBlocked = this.personalDataStage(content, outcomes);
    const blocked = personalDataBlocked || outcomes.some((o) => o.check === "food-safety-lint" && o.verdict === "block");
    const flaggedTag: AllergenTag | null = allergenTags.includes("unknown-contents") ? "unknown-contents" : null;
    return {
      blocked,
      flagged: flaggedTag !== null,
      flaggedTag,
      outcomes,
      allergenTags,
    };
  }

  private allergenStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): AllergenTag[] {
    const tags = new Set<AllergenTag>();
    let unresolved = 0;
    for (const line of content.ingredientLines) {
      const fact = INGREDIENT_FACTS[line.name.trim().toLowerCase()];
      if (fact === undefined) {
        if (line.fdcId === null) {
          unresolved += 1;
        }
        continue;
      }
      for (const a of fact.allergens) {
        tags.add(a);
      }
    }
    if (unresolved > 0) {
      // Fail closed: any line that cannot resolve tags as unknown-contents
      // rather than passing clean (SPEC §6.5).
      tags.add("unknown-contents");
    }
    const sorted = [...tags].sort();
    outcomes.push({
      check: "compound-allergens",
      verdict: unresolved > 0 ? "flag" : "pass",
      detail:
        unresolved > 0
          ? `${unresolved} of ${content.ingredientLines.length} lines could not resolve an allergen.`
          : null,
    });
    return sorted;
  }

  private foodSafetyStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): void {
    const haystack = `${content.title} ${content.description ?? ""} ${content.ingredientLines.map((l) => l.name).join(" ")} ${content.steps.map((s) => s.text).join(" ")}`.toLowerCase();
    const mentionsRawProtein = RAW_PROTEIN_TERMS.some((t) => haystack.includes(t));
    const stepsText = content.steps.map((s) => s.text.toLowerCase()).join(" ");
    const hasCookingStep = COOKING_TERMS.some((t) => stepsText.includes(t)) || COOKING_TEMPERATURE.test(stepsText);
    // A rule the linter cannot evaluate is a block (fail-closed): an empty
    // recipe — no steps — cannot be evaluated, so it blocks too.
    const unevaluable = content.steps.length === 0;
    if (unevaluable) {
      outcomes.push({
        check: "food-safety-lint",
        verdict: "block",
        detail: "the recipe has no steps, so the food-safety lint cannot evaluate it.",
      });
      return;
    }
    if (mentionsRawProtein && !hasCookingStep) {
      outcomes.push({
        check: "food-safety-lint",
        verdict: "block",
        detail: "a raw animal protein appears without any cooking step or temperature.",
      });
      return;
    }
    outcomes.push({ check: "food-safety-lint", verdict: "pass", detail: null });
  }

  private personalDataStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): boolean {
    const fields: Array<readonly [string, string]> = [
      ["title", content.title],
      ...(content.description !== null ? ([["description", content.description]] as const) : []),
      ...content.ingredientLines.map((line, i) => [`ingredient line ${i + 1}`, line.name] as const),
      ...content.steps.map((step, i) => [`step ${i + 1}`, step.text] as const),
    ];
    const reasons: string[] = [];
    for (const [field, text] of fields) {
      for (const finding of findPersonalData(text)) {
        reasons.push(`${finding} in ${field}`);
      }
    }
    if (reasons.length > 0) {
      outcomes.push({
        check: "personal-data",
        verdict: "block",
        detail: reasons.join("; "),
      });
      return true;
    }
    outcomes.push({ check: "personal-data", verdict: "pass", detail: null });
    return false;
  }
}

/** Deterministic personal-data heuristics — ported from PR #104 `findPersonalData`. */
export function findPersonalData(text: string): readonly string[] {
  const findings: string[] = [];
  if (/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("an email address");
  }
  if (/https?:\/\//i.test(text) || /\bwww\.[A-Za-z0-9-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("a link");
  }
  if (/@[A-Za-z0-9_]{3,}/.test(text)) {
    findings.push("an @handle");
  }
  for (const run of text.matchAll(/\d[\d\s().-]{5,}\d/g)) {
    if ((run[0]?.match(/\d/g) ?? []).length >= 7) {
      findings.push("a phone number");
      break;
    }
  }
  return findings;
}
