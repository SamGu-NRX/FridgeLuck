import type { RecipeGenerationResponse } from "../types/contracts.js";

/**
 * Safety-lint seam for generated cooking advice.
 *
 * The cooking advice a recipe returns (title, instructions, ingredients)
 * can carry unsafe cooking-process guidance — undercooking, unsafe cooling,
 * storage, or thawing. Those rules live in the canonical food-safety
 * rulebook and its linter (branch `overhaul/food-safety-canon`). Until that
 * package lands, this module is the single seam it drops into, mirroring
 * `ingredientFacts.ts`:
 *
 * - `SafetyLint` is the contract the package implements (`lint` returning
 *   safe | unsafe | unknown).
 * - `safetyLint` is the ONE binding call sites use. Swapping in the
 *   package-backed linter is a one-line change here; no call site changes.
 * - `failClosedSafetyLint` is the placeholder: it has NO rulebook data, so
 *   it answers `unknown` for every piece of generated advice — and unknown
 *   is NEVER safe. Callers must fail closed and refuse the advice.
 *
 * This seam deliberately owns NO food-safety data: no temperature, cooling,
 * storage, or thaw tables are defined here. Hand-rolled tables would drift
 * from the canonical rulebook that owns them.
 */

/**
 * Verdict for one piece of generated cooking advice. The `unknown` state is
 * load-bearing: an unclassifiable verdict (rulebook missing, safety class
 * unknown, rule unparseable) means we do not know — callers must treat it
 * as unsafe, never as safe.
 */
export type SafetyLintVerdict =
  | {
      kind: "safe";
      /** What the clearance is based on (rulebook ids, rule versions). */
      evidence: readonly string[];
    }
  | {
      kind: "unsafe";
      /** Rulebook rules the advice conflicts with (internal diagnostics). */
      violatedRules: readonly string[];
    }
  | {
      kind: "unknown";
      /** What is missing before the advice can be classified. */
      missing: readonly string[];
    };

/** Provider seam: classifies generated cooking advice against the rulebook. */
export interface SafetyLint {
  /**
   * MUST be total and pure: no I/O, no throwing on any advice value.
   * `unknown` NEVER counts as safe.
   */
  lint(advice: RecipeGenerationResponse): SafetyLintVerdict;
}

/**
 * Placeholder linter used until the canonical rulebook lands. It has NO
 * rulebook data, so every piece of generated advice is `unknown`: nothing
 * can be classified safe, and no cooking advice may leave the service while
 * this binding is in place. The message stays fully static — it must never
 * quote generated content.
 */
export const failClosedSafetyLint: SafetyLint = {
  lint(advice: RecipeGenerationResponse): SafetyLintVerdict {
    void advice;
    return {
      kind: "unknown",
      missing: [
        "canonical food-safety rulebook (generated cooking advice cannot be classified safe yet)"
      ]
    };
  }
};

/**
 * The binding call sites use. Until the package lands this is the fail-closed
 * placeholder; when the canonical rulebook lands, assign the package-backed
 * linter here. No call site changes.
 */
export const safetyLint: SafetyLint = failClosedSafetyLint;
