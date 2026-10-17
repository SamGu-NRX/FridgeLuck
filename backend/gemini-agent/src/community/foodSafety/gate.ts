/**
 * The mandatory food-safety publish gate (SPEC 3.1, 3.5: "Rights, safety lint
 * and allergen tagging apply to user recipes exactly as to the community
 * catalog"; PR #104 review blocker 1).
 *
 * Round 3 rescope (PR #104): the safety stage is a THIN ADAPTER over the
 * canonical food-safety rulebook and linter (PR #126,
 * overhaul/food-safety-canon), vendored and hash-verified at load. The gate
 * adds no thresholds and no fallbacks of its own: the canon linter's
 * semantics — pinned by its conformance kit, which the repo tests replay in
 * full — decide everything. ANY canon finding refuses publication into the
 * human queue: a doneness defect, a copy defect, a flag for review (an
 * unclassifiable ingredient is UNKNOWN, never a lowest-floor pass), or a
 * fail-closed verdict (drifted/absent/undecodable canon data).
 *
 * Two screening stages are REQUIRED on the publication path — the canon lint
 * and compound-allergen tagging derived from the ingredient facts — before
 * anything leaves the author's private view. The gate is fail-closed both
 * ways: while the canon package or the ingredient-facts package is not
 * loaded (absent, empty, unparsable, off-schema, or hash-drifted),
 * `requiredStages` is null and the publish route must refuse with an error
 * envelope — never queue, never publish; and an ingredient the loaded facts
 * do not cover has UNKNOWN composition, which fails the publication into
 * the human queue — never silently allowed (PR #104 review blocker 3).
 * There is no mode in which a publication is created unevaluated.
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
import { loadVendoredCanonPackage, defaultVendoredCanonDir, type VendoredCanon, type VendoredCanonLoad } from "./canonPackage.js";
import type { CopyFinding, LintFinding } from "./canonLinter.js";

export interface FoodSafetyGate {
  /**
   * The two mandatory stages when the canon package and the catalog are
   * loaded; null when closed (fail closed — the publish route refuses with
   * an error envelope).
   */
  readonly requiredStages: readonly ScreeningStage[] | null;
  /** Why the gate is closed; null when open. Goes into logs and error envelopes. */
  readonly closedReason: string | null;
}

export interface CreateFoodSafetyGateOptions {
  /** Explicit catalog package paths; win over env and default locations. */
  readonly canonPath?: string;
  readonly factsPath?: string;
  /**
   * Directory of the vendored canon package (rulebook, copy patterns,
   * conformance kit, provenance manifest). Default: the copy vendored beside
   * this module. A directory that fails load verification closes the gate.
   */
  readonly canonDir?: string;
  /** Environment for path overrides (default process.env). */
  readonly env?: Record<string, string | undefined>;
  /** Working directory for default-location resolution (default process.cwd()). */
  readonly cwd?: string;
  /** Explicit data root overriding env/ancestor discovery. */
  readonly dataRoot?: string;
}

/**
 * Builds the gate by loading the vendored canon package and both catalog
 * packages once, at wiring time. A restart after the packages land re-opens
 * the gate; there is no lazy reopen, because an unevaluated publish must
 * never be possible.
 */
export function createFoodSafetyGate(options: CreateFoodSafetyGateOptions = {}): FoodSafetyGate {
  const canon = loadVendoredCanonPackage(options.canonDir ?? defaultVendoredCanonDir());
  const resolved: FoodSafetyCatalogPaths = resolveFoodSafetyCatalogPaths({
    ...(options.env !== undefined ? { env: options.env } : {}),
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
    ...(options.dataRoot !== undefined ? { dataRoot: options.dataRoot } : {}),
  });
  const paths: FoodSafetyCatalogPaths = {
    canon: options.canonPath ?? resolved.canon,
    facts: options.factsPath ?? resolved.facts,
  };
  return gateFromCatalog(loadFoodSafetyCatalog(paths), canon);
}

/**
 * Builds the gate from an already-decided catalog state (tests,
 * caller-loaded data). The canon package loads from the vendored copy unless
 * a load result is supplied (tests inject one to pin drift behaviour).
 */
export function foodSafetyGateFromCatalog(catalog: FoodSafetyCatalog, canon: VendoredCanonLoad = loadVendoredCanonPackage()): FoodSafetyGate {
  return gateFromCatalog(catalog, canon);
}

function gateFromCatalog(catalog: FoodSafetyCatalog, canon: VendoredCanonLoad): FoodSafetyGate {
  // The canon package is load-bearing: without it there is no reviewed
  // rulebook to lint against, so the gate closes ahead of any other state.
  if (!canon.loaded) {
    return { requiredStages: null, closedReason: canon.reason };
  }
  if (!catalog.loaded) {
    return { requiredStages: null, closedReason: catalog.reason };
  }
  return {
    requiredStages: [foodSafetyLintStage(canon.canon), compoundAllergenStage(catalog.facts, catalog.rulebook)],
    closedReason: null,
  };
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
 * Stage 1 — the mandatory food-safety lint: a thin adapter over the canon
 * linter. The publication is evaluated exactly as the canon evaluates a
 * recipe record — the numbered steps against the rulebook's doneness
 * contract, the prose fields against the canon's copy patterns — and ANY
 * finding fails the publication into the human queue. The adapter carries
 * no thresholds and no fallbacks: an unknown food is the canon's
 * flag-for-review (refusal), not a guess.
 */
export function foodSafetyLintStage(canon: VendoredCanon): ScreeningStage {
  return {
    name: "food-safety-lint",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      const reasons = canonLintReasons(canon, publication);
      if (reasons.length > 0) {
        return { outcome: "fail", stage: "food-safety-lint", reasons };
      }
      return { outcome: "pass", stage: "food-safety-lint", tags: [] };
    },
  };
}

/**
 * The canon's findings for a publication, as reviewer-readable reasons.
 * Step layer: the canon lints numbered instructions over the title and
 * ingredient context — publication steps are numbered explicitly so the
 * canon's numbered-step reader sees every step (an unnumbered leading line
 * would otherwise read as prose). Copy layer: the canon's copy patterns run
 * over the publication's prose fields, as they run over the corpus's.
 */
function canonLintReasons(canon: VendoredCanon, publication: ScreenablePublication): readonly string[] {
  const reasons: string[] = [];
  const title = publication.title;
  const ingredients = publication.ingredientLines.join("\n");
  const instructions = publication.steps.map((step, i) => `${i + 1}. ${step}`).join("\n");
  for (const row of canon.steps.findingsForRecipe(title, ingredients, instructions)) {
    for (const finding of row.findings) {
      reasons.push(stepReason(finding, `step ${row.stepIndex + 1}`));
    }
  }
  const copyRecords: ReadonlyArray<{ readonly field: string; readonly text: string }> = [
    { field: "title", text: title },
    ...(publication.summary !== null && publication.summary.length > 0 ? [{ field: "summary", text: publication.summary }] : []),
  ];
  for (const copy of copyRecords) {
    for (const finding of canon.copy.lint([{ file: "publication", recordID: title, field: copy.field, text: copy.text }])) {
      reasons.push(copyReason(finding));
    }
  }
  return reasons;
}

/** One reviewer-readable reason for a step finding, citing the canon rule id. */
function stepReason(finding: LintFinding, where: string): string {
  const head = finding.ruleID.length > 0 ? `${finding.kind} [${finding.ruleID}]` : finding.kind;
  const what = finding.detail.length > 0 ? finding.detail : finding.suggestedRewrite;
  return `food-safety-canon: ${head} — ${what} (${where})`;
}

/** One reviewer-readable reason for a copy finding, citing the canon pattern id. */
function copyReason(finding: CopyFinding): string {
  return `food-safety-canon: ${finding.patternID} — ${finding.requiredChange} (in ${finding.field}: "${finding.currentText}")`;
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
 *
 * The tagging is TOTAL (PR #104 review blocker 3): an ingredient line that
 * matches no reviewed fact is reported in `unknownLines` — its composition
 * is UNKNOWN, and unknown is never allowed. The caller (the stage below)
 * fails the publication on it.
 */
export function deriveAllergenTagging(facts: IngredientFacts, ingredientLines: readonly string[]): { tags: readonly string[]; unknownLines: readonly string[] } {
  const tags = new Set<string>();
  const unknownLines: string[] = [];
  for (const line of ingredientLines) {
    const lineLower = line.toLowerCase();
    const lineTokens = new Set(tokens(line));
    const covered = facts.ingredients.some((entry) =>
      entry.match.some((phrase) => {
        const phraseLower = phrase.toLowerCase();
        return phraseLower.includes(" ") ? lineLower.includes(phraseLower) : lineTokens.has(phraseLower);
      }),
    );
    if (!covered) {
      // Cite the line verbatim: the facts cannot say what it is, and the
      // refusal must say so honestly instead of inventing a name for it.
      unknownLines.push(line);
      continue;
    }
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
  return { tags: [...tags].sort(), unknownLines };
}

/**
 * Stage 2 — mandatory compound-allergen tagging from the ingredient facts.
 * Tagging annotates every clean publication; an allergen-free CLAIM the
 * derived tags contradict is an unsupported claim and fails the publication
 * (PLAN C: "0 unchecked allergen or diet claims").
 *
 * Fail closed on unknown composition (PR #104 review blocker 3): an
 * ingredient line the reviewed facts do not cover has UNKNOWN composition —
 * it fails the publication into the human queue with the uncovered line
 * cited, and no claim can be supported over it. Unknown is never allowed,
 * and an empty tag set is never read as allergen-free.
 */
export function compoundAllergenStage(facts: IngredientFacts, rulebook: FoodSafetyRulebook): ScreeningStage {
  return {
    name: "compound-allergens",
    async run(publication: ScreenablePublication): Promise<ScreeningVerdict> {
      const { tags, unknownLines } = deriveAllergenTagging(facts, publication.ingredientLines);
      const wholeTokens = tokens([publication.title, publication.summary ?? "", ...publication.ingredientLines, ...publication.steps].join("\n"));
      const reasons: string[] = [];
      // Unknown composition first, and independently of any claim: the
      // facts cannot establish what the recipe contains, so no allergen
      // claim over it can be supported either. Each reason cites the
      // uncovered line verbatim.
      for (const [i, line] of publication.ingredientLines.entries()) {
        if (unknownLines.includes(line)) {
          reasons.push(`ingredient-facts: ingredient line ${i + 1} ("${line}") is not covered by the reviewed facts — its composition is unknown, so allergen tagging cannot be trusted and no allergen-free claim over it can be supported (fail closed)`);
        }
      }
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
