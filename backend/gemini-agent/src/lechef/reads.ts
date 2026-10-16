/**
 * Read tools (SPEC §8.3) — the six registered reads, adapted from #102's
 * reads.ts: getPantry, getStepContext, getPlan, checkFoodSafety, cameraLook,
 * lookupSubstitution. Every read returns its result fields PLUS the
 * evidence/unknowns envelope; unknowns are explicit, never silent.
 *
 * Reads are pure over the bounded snapshots the phone hands out — they never
 * mutate anything and never propose anything.
 */

import { allergenViolations } from "./allergens.js";
import type { AdviceEntry, FoodSafetyTool } from "./foodSafety.js";
import { createFoodSafetyTool } from "./foodSafety.js";
import { computeCandidateFits } from "./fit.js";
import { CameraLintError, lintCameraObservations } from "./cameraLint.js";
import { createSubstitutionTool, type SubstitutionTool } from "./substitutions.js";
import type {
  CameraObservation,
  CookSessionSnapshot,
  RecipeContext,
  ReadToolResult
} from "./types.js";
import { PROPOSAL_TTL_SECONDS } from "./types.js";
import type { PhoneExecutor } from "./proposals.js";

// ---------------------------------------------------------------------------
// getPantry
// ---------------------------------------------------------------------------

export interface GetPantryResult extends ReadToolResult<{
  revision: number;
  items: readonly unknown[];
  counts: Record<string, number>;
  needsConfirmation: readonly { ingredientId: string; name: string; reason: string }[];
}> {}

/** The bounded pantry view, with the lines needing confirmation called out (SPEC 3.2). */
export function getPantry(phone: PhoneExecutor): GetPantryResult {
  const pantry = phone.pantrySnapshot();
  const counts: Record<string, number> = {};
  for (const item of pantry.items) counts[item.state] = (counts[item.state] ?? 0) + 1;
  const needsConfirmation = pantry.items
    .filter((i) => i.state === "quantity-unknown" || i.state === "needs-reconfirming")
    .map((i) => ({
      ingredientId: i.ingredientId,
      name: i.name,
      reason: i.state === "quantity-unknown" ? "quantity unknown" : "evidence stale"
    }));
  return {
    revision: pantry.revision,
    items: pantry.items,
    counts,
    needsConfirmation,
    evidence: [
      { kind: "pantry-line", ref: `pantry-revision-${pantry.revision}`, detail: `${pantry.items.length} lines` }
    ],
    unknowns: pantry.items.length === 0 ? ["pantry is empty — no lines on record"] : []
  };
}

// ---------------------------------------------------------------------------
// getStepContext
// ---------------------------------------------------------------------------

export interface GetStepContextResult extends ReadToolResult<{
  recipeId?: string;
  sessionState: string;
  currentStepIndex: number;
  stepText?: string;
  stepTimerMinutes?: number;
  stepSafetyCheckTarget?: string;
  stepCount?: number;
  activeTimers: readonly unknown[];
  recentStepMoves: readonly unknown[];
  cameraMode: string;
}> {}

/** Where the cook is: current step, its timer and doneness target, live timers, recent moves. */
export function getStepContext(
  phone: PhoneExecutor,
  instructionLint: typeof lintInstructionInjection = lintInstructionInjection
): GetStepContextResult {
  const session = phone.sessionSnapshot();
  const recipe = findRecipe(phone, session);
  const step = recipe?.steps.find((s) => s.index === session.currentStepIndex);
  const injectionFindings = step !== undefined ? instructionLint(`${recipe?.title ?? ""} ${step.text}`) : [];
  return {
    ...(recipe !== undefined ? { recipeId: recipe.id } : {}),
    sessionState: session.state,
    currentStepIndex: session.currentStepIndex,
    ...(step !== undefined
      ? { stepText: step.text, ...(step.timerMinutes !== undefined ? { stepTimerMinutes: step.timerMinutes } : {}), ...(step.safetyCheckTarget !== undefined ? { stepSafetyCheckTarget: step.safetyCheckTarget } : {}) }
      : {}),
    ...(recipe !== undefined ? { stepCount: recipe.steps.length } : {}),
    activeTimers: session.activeTimers,
    recentStepMoves: session.stepHistory ?? [],
    cameraMode: session.cameraMode,
    evidence: [
      { kind: "session-state", ref: `session:${session.recipeId ?? "none"}:${session.state}`, detail: `step ${session.currentStepIndex}` },
      ...(session.activeTimers.length > 0
        ? [{ kind: "session-state" as const, ref: "active-timers", detail: `${session.activeTimers.length} running` }]
        : [])
    ],
    unknowns: [
      ...(recipe === undefined ? ["no active recipe in this session"] : []),
      ...(recipe !== undefined && step === undefined ? [`no step ${session.currentStepIndex} in recipe ${recipe.id}`] : []),
      // Recipe and step text are DATA (SPEC 3.1): rule-dismissal or
      // instruction-injection language is surfaced as an explicit unknown so
      // it can never masquerade as authorization.
      ...injectionFindings.map((f) => `instruction-injection: step text ${f.reason} (matched: ${f.pattern})`)
    ]
  };
}

function findRecipe(phone: PhoneExecutor, session: CookSessionSnapshot): RecipeContext | undefined {
  if (session.recipeId === undefined) return undefined;
  return phone.recipeCatalog().find((r) => r.id === session.recipeId);
}

// ---------------------------------------------------------------------------
// getPlan
// ---------------------------------------------------------------------------

export interface GetPlanResult extends ReadToolResult<{
  pantryRevision: number;
  fitLineSummary: string;
  candidates: readonly {
    recipeId: string;
    revision: number;
    title?: string;
    fitLine: string;
    sufficientCount: number;
    requiredCount: number;
    swapCount: number;
  }[];
}> {}

/**
 * Recipe candidates ranked by honest fit (SPEC 3.2): fit lines count every
 * required line, assumed staples and stale evidence stay visible, garnish
 * never blocks, and the summary never says "you have everything" unless
 * every required line is sufficient. Top three candidates.
 */
export function getPlan(phone: PhoneExecutor, acceptedSwaps: readonly { from: string; to: string }[] = []): GetPlanResult {
  const pantry = phone.pantrySnapshot();
  const session = phone.sessionSnapshot();
  const candidates = phone.recipeCatalog();
  const fits = computeCandidateFits(candidates, pantry, {
    acceptedSwaps,
    swapViolations: (to: string) => allergenViolations(to, session.eaters)
  });
  const ranked = candidates
    .map((r) => ({ recipe: r, fit: fits.get(r.id)!.fit }))
    .sort((a, b) => b.fit.sufficientCount - a.fit.sufficientCount || a.recipe.id.localeCompare(b.recipe.id));
  const top = ranked.slice(0, 3);
  const allSufficient = ranked.length > 0 && ranked.every((x) => x.fit.allSufficient);
  return {
    pantryRevision: pantry.revision,
    fitLineSummary: allSufficient
      ? `every candidate's required lines are sufficient against pantry revision ${pantry.revision}`
      : `top candidates against pantry revision ${pantry.revision} — short, unknown, and assumed-staple lines are counted honestly`,
    candidates: top.map(({ recipe, fit }) => ({
      recipeId: recipe.id,
      revision: recipe.revision,
      ...(recipe.title !== undefined ? { title: recipe.title } : {}),
      fitLine: fit.fitLine,
      sufficientCount: fit.sufficientCount,
      requiredCount: fit.requiredCount,
      swapCount: fit.swapCount
    })),
    evidence: [
      { kind: "pantry-line", ref: `pantry-revision-${pantry.revision}`, detail: "bounded snapshot used for fit" },
      ...top.map(({ recipe }) => ({ kind: "recipe-bill" as const, ref: `${recipe.id}@r${recipe.revision}`, detail: "candidate" }))
    ],
    unknowns: [
      ...(pantry.items.length === 0 ? ["pantry is empty — fits assume nothing is in stock"] : []),
      ...(candidates.length === 0 ? ["no candidate recipes available"] : [])
    ]
  };
}

// ---------------------------------------------------------------------------
// checkFoodSafety
// ---------------------------------------------------------------------------

export interface CheckFoodSafetyResult extends ReadToolResult<{
  answer: unknown;
  sourceName: string | null;
  product: string;
  matchedRuleIds: readonly string[];
  advice: readonly AdviceEntry[];
}> {}

/**
 * Doneness as a checkable thermometer test from a named reviewed source
 * (SPEC 3.1). The product comes from the question or, when omitted, from the
 * current step's doneness target. Uncovered products return an explicit
 * unknown — never a colour, never a time, never a guess.
 */
export function checkFoodSafety(
  phone: PhoneExecutor,
  tool: FoodSafetyTool,
  input: { product?: string; question?: string }
): CheckFoodSafetyResult {
  const session = phone.sessionSnapshot();
  let product = input.product;
  const unknowns: string[] = [];
  if (product === undefined || product === "") {
    const recipe = findRecipe(phone, session);
    const step = recipe?.steps.find((s) => s.index === session.currentStepIndex);
    if (step?.safetyCheckTarget !== undefined) {
      product = step.safetyCheckTarget;
      unknowns.push(`product taken from the current step's doneness target ("${product}") — say so if the cook asked about something else`);
    } else {
      return {
        answer: { kind: "unknown", reason: "no product named in the question and no doneness target on the current step" },
        sourceName: null,
        product: "",
        matchedRuleIds: [],
        advice: [],
        evidence: [{ kind: "session-state", ref: `session:${session.recipeId ?? "none"}`, detail: "no step safety target" }],
        unknowns: ["name the product (e.g. chicken breast, salmon fillet) to get a sourced check"]
      };
    }
  }
  const result = tool.checkFoodSafety({ product, question: input.question });
  return {
    answer: result.answer,
    sourceName: result.sourceName,
    product,
    matchedRuleIds: result.matchedRuleIds,
    advice: result.advice,
    evidence: [
      ...(result.answer.kind === "sourced-check"
        ? [{ kind: "fsis-table" as const, ref: result.answer.check.source, detail: `${result.answer.check.temperatureF} °F / ${result.answer.check.temperatureC} °C` }]
        : []),
      ...result.advice.map((a) => ({ kind: "fsis-table" as const, ref: a.ruleId, detail: "reviewed advice quoted" })),
      { kind: "session-state", ref: `session:${session.recipeId ?? "none"}`, detail: "doneness question" }
    ],
    unknowns: [...result.unknowns, ...unknowns]
  };
}

// ---------------------------------------------------------------------------
// cameraLook
// ---------------------------------------------------------------------------

export interface CameraLookResult extends ReadToolResult<{ observation: CameraObservation | null; refused: boolean }> {}

/**
 * A device-mediated camera look (SPEC 3.1). The observation type has no field
 * that could carry a safety verdict; the free-text observations are linted
 * and verdict-shaped text is REFUSED, never relayed (fail closed). Offline,
 * the phone returns framesSent: 0 and the tool says what cannot be assessed.
 */
export function cameraLook(
  phone: PhoneExecutor,
  input: { mode?: "push-to-look" | "continuous" },
  lint: typeof lintCameraObservations = lintCameraObservations
): CameraLookResult {
  const session = phone.sessionSnapshot();
  const mode = input.mode ?? session.cameraMode;
  const observation = phone.cameraLook(mode);
  const unknowns: string[] = [];
  if (observation.framesSent === 0) {
    unknowns.push("no frames reached the model this look" + (observation.cannotAssess.length ? ` — cannot assess: ${observation.cannotAssess.join("; ")}` : ""));
  }
  let refused = false;
  let cleaned: CameraObservation = observation;
  // Fail closed: the lint returns findings (it never throws), so a non-empty
  // findings list refuses the whole capture — verdict-shaped camera text is
  // never relayed (SPEC 3.1).
  const lintFindings = lint(observation.observed);
  if (lintFindings.length > 0) {
    refused = true;
    cleaned = { observed: [], cannotAssess: [...observation.cannotAssess, "observations refused: verdict-shaped camera text is never relayed (SPEC 3.1)"], framesSent: 0, clipSeconds: 0 };
    unknowns.push(lintFindings.map((f) => f.reason).join("; "));
  }
  return {
    observation: cleaned,
    refused,
    evidence: [
      { kind: "device-observation", ref: `camera:${mode}`, detail: `${cleaned.framesSent} frames, ${cleaned.clipSeconds}s clip` },
      { kind: "session-state", ref: `session:${session.recipeId ?? "none"}:step-${session.currentStepIndex}`, detail: "camera look context" }
    ],
    unknowns
  };
}

// ---------------------------------------------------------------------------
// lookupSubstitution
// ---------------------------------------------------------------------------

export interface LookupSubstitutionResult extends ReadToolResult<{
  answer: unknown;
}> {}

/**
 * The reviewed substitution table answer (SPEC 3.5): table rows carry ratios
 * and difference notes; no reviewed entry means an explicit beyond-table
 * answer, labelled as reasoning beyond the table. Every answer is rechecked
 * against ALL eaters' restrictions before it leaves the tool (SPEC 3.3).
 */
export function lookupSubstitution(
  phone: PhoneExecutor,
  tool: SubstitutionTool,
  input: { ingredient: string; context?: string }
): LookupSubstitutionResult {
  const session = phone.sessionSnapshot();
  const result = tool.lookupSubstitution({
    ingredient: input.ingredient,
    context: input.context,
    eaters: session.eaters
  });
  return {
    answer: {
      kind: result.kind,
      swaps: result.swaps,
      explanation: result.explanation,
      differenceStatements: result.differenceStatements,
      violations: result.violations
    },
    evidence: result.evidence,
    unknowns: [
      ...result.unknowns,
      ...(result.kind === "beyond-table"
        ? ["the substitution above is NOT from a reviewed table — label it as reasoning beyond the table to the user"]
        : []),
      ...(result.violations.length > 0 ? [`allergen recheck blocked the suggestion: ${result.violations.join("; ")}`] : [])
    ]
  };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

export interface InstructionInjectionFinding {
  pattern: string;
  reason: string;
}

/**
 * Instruction-injection lint (SPEC 3.1): recipe and step text are DATA. A
 * closed list of rule-dismissal phrases is flagged so the read surface says
 * explicitly that recipe text cannot override the reviewed rules or approval
 * policy — the model never has to make that judgement from vibes. Deliberately
 * narrow: ordinary cooking language ("start a 2 minute timer", "don't stir")
 * never trips it; only text that dismisses the safety rules or the
 * thermometer does.
 */
export function lintInstructionInjection(text: string): readonly InstructionInjectionFinding[] {
  const findings: { pattern: RegExp; reason: string }[] = [
    { pattern: /ignore (?:the |all |any |previous |prior |those )?(?:rules|rule|safety(?: rules)?|instructions|guidelines)/i, reason: "dismisses the reviewed rules" },
    { pattern: /disregard (?:the |all |any )?(?:rules|rule|safety|guidelines|instructions)/i, reason: "dismisses the reviewed rules" },
    { pattern: /(?:don'?t|do not|never|no need to|skip(?: the)?) use (?:a |the )?thermometer/i, reason: "dismisses the thermometer check" },
    { pattern: /(?:skip|forget) (?:the )?(?:safety|thermometer|rules|rules check|safety check)/i, reason: "dismisses the safety check" },
    { pattern: /(?:the |these |those )?rules (?:do not|don'?t) apply/i, reason: "claims the reviewed rules do not apply" },
    { pattern: /no thermometer (?:is |needed |required )/i, reason: "dismisses the thermometer check" },
    { pattern: /override (?:the )?(?:safety|approval|rules)/i, reason: "claims an override of safety or approval policy" }
  ];
  return findings
    .filter((f) => f.pattern.test(text))
    .map((f) => ({ pattern: f.pattern.source, reason: f.reason }));
}

/** TTL re-exported for the runtime's tool catalogue docs. */
export const PROPOSAL_TTL = PROPOSAL_TTL_SECONDS;

export function defaultReadTools(
  phone: PhoneExecutor,
  options: {
    foodSafety?: FoodSafetyTool;
    substitutions?: SubstitutionTool;
    cameraLint?: typeof lintCameraObservations;
    instructionLint?: typeof lintInstructionInjection;
  } = {}
): {
  getPantry: () => GetPantryResult;
  getStepContext: () => GetStepContextResult;
  getPlan: () => GetPlanResult;
  checkFoodSafety: (input: { product?: string; question?: string }) => CheckFoodSafetyResult;
  cameraLook: (input: { mode?: "push-to-look" | "continuous" }) => CameraLookResult;
  lookupSubstitution: (input: { ingredient: string; context?: string }) => LookupSubstitutionResult;
} {
  const foodSafety: FoodSafetyTool = options.foodSafety ?? createFoodSafetyTool();
  const substitutions: SubstitutionTool = options.substitutions ?? createSubstitutionTool();
  const cameraLint = options.cameraLint ?? lintCameraObservations;
  const instructionLint = options.instructionLint ?? lintInstructionInjection;
  return {
    getPantry: () => getPantry(phone),
    getStepContext: () => getStepContext(phone, instructionLint),
    getPlan: () => getPlan(phone),
    checkFoodSafety: (input) => checkFoodSafety(phone, foodSafety, input),
    cameraLook: (input) => cameraLook(phone, input, cameraLint),
    lookupSubstitution: (input) => lookupSubstitution(phone, substitutions, input)
  };
}
