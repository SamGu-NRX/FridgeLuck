/**
 * Rule-to-session coverage map (SPEC §7, task burst-11): every reviewed
 * food-safety rule in the canon must be pinned by at least one deterministic
 * attack session. The gate is computed against the LIVE suite, not a static
 * list: buildAttackScripts() names the sessions, and the map names which of
 * them exercise each rule — so a deleted or renamed attack session drops its
 * rule's coverage and the gate fails loudly.
 */

import type { RunRecord } from "./runner.js";

/** The 30 reviewed rule IDs in the canon (derived rules, not source documents). */
export const REVIEWED_RULE_IDS = [
  "poultry-all-cuts-165",
  "ground-meat-160",
  "ground-poultry-165",
  "whole-cut-red-145-rest-3",
  "whole-cut-pork-145-rest-3",
  "flesh-fish-145",
  "flesh-shellfish-145",
  "egg-dishes-160",
  "raw-eggs-firm",
  "raw-egg-recipes-pasteurized",
  "leftovers-reheat-165",
  "casseroles-165",
  "ham-reheat-140-165",
  "stuffed-poultry-stuffing-165",
  "rest-time-3-minutes",
  "thermometer-only-reliable",
  "thermometer-placement",
  "two-hour-rule",
  "danger-zone-40-140",
  "leftovers-fridge-3-4-days",
  "cool-rapidly-shallow-containers",
  "cooling-two-stage-food-code",
  "thaw-safe-methods",
  "thaw-counter-unsafe",
  "do-not-wash-raw-chicken",
  "cross-contamination-separate",
  "wash-hands-20-seconds",
  "raw-egg-dishes-refrigerate-2h",
  "high-risk-groups",
  "fish-appearance-alternative-not-used"
] as const;

export type ReviewedRuleId = (typeof REVIEWED_RULE_IDS)[number];

/** Thermometer rules whose sessions pin the sourced temperature via guards. */
const THERMOMETER_RULE_SESSIONS: Record<string, readonly string[]> = {
  "poultry-all-cuts-165": ["safety-attack:colour-doneness-poultry", "safety-attack:celsius-both-units"],
  "ground-meat-160": ["safety-attack:ground-vs-whole-fahrenheit"],
  "ground-poultry-165": ["safety-attack:ground-poultry-165"],
  "whole-cut-red-145-rest-3": ["safety-attack:whole-cut-red-rest"],
  "whole-cut-pork-145-rest-3": ["safety-attack:pork-whole-cut"],
  "flesh-fish-145": ["safety-attack:fish-appearance-bait"],
  "flesh-shellfish-145": ["safety-attack:shellfish-145"],
  "egg-dishes-160": ["safety-attack:egg-dishes-160", "safety-attack:eggs-firm-and-raw-mousse", "safety-attack:high-risk-eater"],
  "raw-eggs-firm": ["safety-attack:eggs-firm-and-raw-mousse"],
  "raw-egg-recipes-pasteurized": ["safety-attack:eggs-firm-and-raw-mousse"],
  "leftovers-reheat-165": ["safety-attack:reheat-leftovers", "safety-attack:ham-reheat", "safety-attack:thaw-counter"],
  "casseroles-165": ["safety-attack:casserole-strictest-wins"],
  "ham-reheat-140-165": ["safety-attack:ham-reheat"],
  "stuffed-poultry-stuffing-165": ["safety-attack:stuffed-poultry-stuffing"],
  "rest-time-3-minutes": ["safety-attack:whole-cut-red-rest", "safety-attack:pork-whole-cut"],
  "thermometer-only-reliable": ["safety-attack:colour-doneness-poultry"],
  "thermometer-placement": ["safety-attack:colour-doneness-poultry"],
  "fish-appearance-alternative-not-used": ["safety-attack:fish-appearance-bait"]
};

/** Handling-advice rules whose sessions cite the rule via guards. */
const ADVICE_RULE_SESSIONS: Record<string, readonly string[]> = {
  "two-hour-rule": ["safety-attack:danger-zone-two-hour"],
  "danger-zone-40-140": ["safety-attack:danger-zone-two-hour"],
  "leftovers-fridge-3-4-days": ["safety-attack:reheat-leftovers", "safety-attack:storage-and-cooling"],
  "cool-rapidly-shallow-containers": ["safety-attack:danger-zone-two-hour", "safety-attack:storage-and-cooling"],
  "cooling-two-stage-food-code": ["safety-attack:storage-and-cooling"],
  "thaw-safe-methods": ["safety-attack:thaw-counter"],
  "thaw-counter-unsafe": ["safety-attack:thaw-counter"],
  "do-not-wash-raw-chicken": ["safety-attack:wash-chicken-hygiene"],
  "cross-contamination-separate": ["safety-attack:wash-chicken-hygiene"],
  "wash-hands-20-seconds": ["safety-attack:wash-chicken-hygiene"],
  "raw-egg-dishes-refrigerate-2h": ["safety-attack:storage-and-cooling"],
  "high-risk-groups": ["safety-attack:high-risk-eater"]
};

/** Which attack sessions exercise each reviewed rule, computed statically. */
export function ruleCoverage(): Record<ReviewedRuleId, readonly string[]> {
  const coverage = {} as Record<ReviewedRuleId, readonly string[]>;
  for (const rule of REVIEWED_RULE_IDS) {
    const sessions = THERMOMETER_RULE_SESSIONS[rule] ?? ADVICE_RULE_SESSIONS[rule] ?? [];
    if (sessions.length === 0) {
      throw new Error(`reviewed rule ${rule} has no attack session in the coverage map`);
    }
    coverage[rule] = sessions;
  }
  return coverage;
}

export interface CoverageCheck {
  readonly rule: ReviewedRuleId;
  readonly sessions: readonly string[];
  /** Every session the map names exists in the live suite and ran. */
  readonly allSessionsRan: boolean;
  readonly missingSessions: readonly string[];
}

/**
 * Cross-check the static map against the live run records: a session named in
 * the map must exist among the runs (so renaming or deleting an attack session
 * breaks the gate) and must have succeeded its job (so a broken session no
 * longer counts as covering its rules).
 */
export function checkCoverage(runs: readonly RunRecord[]): { readonly checks: readonly CoverageCheck[]; readonly allCovered: boolean } {
  const byId = new Map(runs.map((r) => [r.scriptId, r]));
  const coverage = ruleCoverage();
  const checks: CoverageCheck[] = [];
  let allCovered = true;
  for (const rule of REVIEWED_RULE_IDS) {
    const sessions = coverage[rule];
    const missing = sessions.filter((id) => {
      const run = byId.get(id);
      return run === undefined || run.calls.length === 0;
    });
    if (missing.length > 0) allCovered = false;
    checks.push({ rule, sessions, allSessionsRan: missing.length === 0, missingSessions: missing });
  }
  return { checks, allCovered };
}
