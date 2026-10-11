/**
 * Automated screening (SPEC 3.4: "automated screening plus a human queue").
 *
 * HARD RULE (README rule 2, spec §6): no LLM anywhere in the moderation path.
 * Every stage here is a deterministic function of text. Stages can only fail
 * a publication into the human queue; a human moderator approves or rejects.
 *
 * The pipeline always runs the built-in text-hygiene stage — it cannot be
 * unwired by configuration. Optional stages (the food-safety linter when its
 * catalog is consumable from TypeScript, allergen tagging) arrive through
 * `deps.screeningStages` from the parent join; `defaultScreeningStages` is
 * what that join includes today.
 */
import type { ScreenablePublication, ScreeningStage, ScreeningVerdict } from "../shared/contracts.js";

export interface ScreeningFailure {
  readonly stage: string;
  readonly reasons: readonly string[];
}

export interface ScreeningResult {
  readonly passed: boolean;
  readonly failures: readonly ScreeningFailure[];
  /** Union of the tags produced by passing stages (e.g. allergen tags). */
  readonly tags: readonly string[];
}

export async function runScreeningPipeline(stages: readonly ScreeningStage[], publication: ScreenablePublication): Promise<ScreeningResult> {
  const failures: ScreeningFailure[] = [];
  const tags: string[] = [];
  for (const stage of stages) {
    const verdict: ScreeningVerdict = await stage.run(publication);
    if (verdict.outcome === "pass") {
      tags.push(...verdict.tags);
    } else {
      failures.push({ stage: verdict.stage, reasons: [...verdict.reasons] });
    }
  }
  return { passed: failures.length === 0, failures, tags };
}

/** The built-in optional stages the parent join wires into deps.screeningStages. */
export function defaultScreeningStages(): ScreeningStage[] {
  return [allergenTagStage()];
}

/**
 * Text hygiene (always on). A publication may not carry personal data
 * (SPEC 3.4: the author "confirms no personal data is in it") — the automated
 * layer catches the obvious cases (contact details, links) deterministically
 * and fails them into the human queue rather than judging intent.
 */
export function textHygieneStage(): ScreeningStage {
  return {
    name: "text-hygiene",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      const reasons: string[] = [];
      const fields: Array<readonly [string, string]> = [
        ["title", publication.title],
        ...(publication.summary !== null ? [["summary", publication.summary] as const] : []),
        ...publication.ingredientLines.map((line, i) => [`ingredient line ${i + 1}`, line] as const),
        ...publication.steps.map((step, i) => [`step ${i + 1}`, step] as const),
      ];
      for (const [field, text] of fields) {
        for (const finding of findPersonalData(text)) {
          reasons.push(`${finding} in ${field}`);
        }
      }
      if (reasons.length > 0) {
        return { outcome: "fail", stage: "text-hygiene", reasons };
      }
      return { outcome: "pass", stage: "text-hygiene", tags: [] };
    },
  };
}

export function findPersonalData(text: string): readonly string[] {
  const findings: string[] = [];
  if (/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("an email address");
  }
  if (/https?:\/\//i.test(text) || /\bwww\.[A-Za-z0-9-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("a link");
  }
  for (const run of text.matchAll(/\d[\d\s().-]{5,}\d/g)) {
    if ((run[0]?.match(/\d/g) ?? []).length >= 7) {
      findings.push("a phone number");
      break;
    }
  }
  return findings;
}

/**
 * Allergen tagging (SPEC 3.4: "allergen tagging ... apply[ies] to user
 * recipes exactly as to the catalog"). Tagging never fails a publication:
 * it annotates it so the feed can badge and the phone can filter.
 */
const ALLERGEN_KEYWORDS: Readonly<Record<string, readonly string[]>> = {
  milk: ["milk", "cream", "butter", "cheese", "yogurt", "yoghurt", "whey", "casein", "lactose", "ghee"],
  egg: ["egg", "eggs", "mayonnaise", "mayo"],
  peanut: ["peanut", "peanuts", "arachis"],
  "tree-nut": ["almond", "almonds", "hazelnut", "hazelnuts", "walnut", "walnuts", "cashew", "cashews", "pecan", "pecans", "pistachio", "pistachios", "macadamia", "brazil nut", "pine nut", "marzipan", "nougat"],
  "wheat-gluten": ["wheat", "gluten", "semolina", "spelt", "farro", "bulgur", "couscous", "barley", "rye", "breadcrumb", "breadcrumbs"],
  soy: ["soy", "soya", "soybean", "edamame", "tofu", "tempeh", "miso", "tamari"],
  fish: ["fish", "anchovy", "anchovies", "tuna", "salmon", "cod", "trout", "mackerel", "sardine", "sardines", "tilapia"],
  shellfish: ["shrimp", "prawn", "prawns", "crab", "lobster", "clam", "clams", "mussel", "mussels", "oyster", "oysters", "scallop", "scallops", "squid", "octopus", "crawfish", "shellfish"],
  sesame: ["sesame", "tahini"],
};

/** Canonical allergen tag for a keyword hit: "allergen-milk" style. */
function allergenTag(canonical: string): string {
  return `allergen-${canonical}`;
}

function words(text: string): readonly string[] {
  return text
    .toLowerCase()
    .split(/[^a-z]+/)
    .filter((w) => w.length > 0);
}

export function findAllergenTags(ingredientLines: readonly string[]): readonly string[] {
  const tokens = new Set<string>(ingredientLines.flatMap((line) => words(line)));
  const phrases = ingredientLines.map((line) => line.toLowerCase());
  const tags: string[] = [];
  for (const [canonical, keywords] of Object.entries(ALLERGEN_KEYWORDS)) {
    const hit = keywords.some((keyword) =>
      keyword.includes(" ") ? phrases.some((p) => p.includes(keyword)) : tokens.has(keyword),
    );
    if (hit) {
      tags.push(allergenTag(canonical));
    }
  }
  return tags;
}

export function allergenTagStage(): ScreeningStage {
  return {
    name: "allergen-tags",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      return { outcome: "pass", stage: "allergen-tags", tags: findAllergenTags(publication.ingredientLines) };
    },
  };
}
