/**
 * Automated screening (SPEC 3.4: "automated screening plus a human queue").
 *
 * HARD RULE (README rule 2, spec §6): no LLM anywhere in the moderation path.
 * Every stage here is a deterministic function of text. Stages can only fail
 * a publication into the human queue; a human moderator approves or rejects.
 *
 * The pipeline always runs the built-in text-hygiene stage. The MANDATORY
 * food-safety stages (canonical-rulebook lint, compound-allergen tagging)
 * come from `deps.foodSafetyGate` — they are not optional and the publish
 * route refuses to run at all while their data packages are not loaded
 * (foodSafety/gate.ts). `deps.screeningStages` stays the seam for any
 * additional parent-join stages.
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
