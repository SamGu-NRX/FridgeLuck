/**
 * Read tools — every result carries {evidence, unknowns}; unknowns are
 * explicit, never silent (SPEC 3.2). All inputs are bounded snapshot views
 * the phone hands out; nothing here mutates anything.
 *
 * getRecipeCandidates computes fit over the COMPLETE ingredient bill from the
 * pantry snapshot: repeated lines summed, optional garnish separate,
 * allocation without double counting across candidates, and a fit LINE built
 * from per-line states only — never a percentage, and "you have everything"
 * only when every required line is strictly sufficient.
 */

import type {
  CameraMode,
  CookSessionSnapshot,
  Eater,
  Evidence,
  PantrySnapshot,
  RecipeCandidate,
  RecipeContext,
  SubstitutionSwap,
  ToolEnvelope
} from "./types.js";
import { computeCandidateFits } from "./fit.js";
import { CameraLintError, lintCameraObservations } from "./cameraLint.js";

/** Where candidate recipes come from (phone-side, bounded; the real client reads recipe cards). */
export type RecipeCatalog = () => readonly RecipeContext[];

/** The candidate-search goal: what the user asked for, plus any accepted swaps. */
export interface CandidateGoal {
  readonly text: string;
  readonly acceptedSwaps?: readonly SubstitutionSwap[];
}

export interface ReadDeps {
  pantry: () => PantrySnapshot;
  session: () => CookSessionSnapshot;
  catalog: RecipeCatalog;
  /** Allergen violations a swap target raises for all eaters (compound-aware). */
  swapViolations: (to: string) => readonly string[];
}

// ---------------------------------------------------------------------------
// getRecipeCandidates
// ---------------------------------------------------------------------------

export interface CandidateResult extends ToolEnvelope {
  readonly candidates: readonly RecipeCandidate[];
  readonly goal: string;
}

/**
 * Candidate recipes with per-recipe fit computed over the complete
 * ingredient bill. Candidates are allocated in catalog order — the same
 * stock cannot count for two candidates (no double counting).
 */
export function getRecipeCandidates(deps: ReadDeps, goal: CandidateGoal): CandidateResult {
  const pantry = deps.pantry();
  const catalog = deps.catalog();
  const evidence: Evidence[] = [
    { kind: "pantry-line", ref: `pantry-revision-${pantry.revision}`, detail: `${pantry.items.length} bounded line(s)` }
  ];
  const unknowns: string[] = [];
  if (catalog.length === 0) {
    unknowns.push("no candidate recipes are loaded in this session's bounded catalog");
  }
  const fits = computeCandidateFits(catalog, pantry, {
    ...(goal.acceptedSwaps !== undefined ? { acceptedSwaps: goal.acceptedSwaps } : {}),
    swapViolations: deps.swapViolations
  });
  const candidates: RecipeCandidate[] = catalog.map((recipe) => {
    const computed = fits.get(recipe.id);
    if (!computed) {
      // Never silently skip a candidate — surface the gap.
      unknowns.push(`fit for ${recipe.id} could not be computed`);
      return {
        recipeId: recipe.id,
        revision: recipe.revision,
        ...(recipe.title !== undefined ? { title: recipe.title } : {}),
        fit: { fitLine: "fit unavailable", required: [], garnish: [], sufficientCount: 0, requiredCount: 0, swapCount: 0, allSufficient: false }
      };
    }
    return {
      recipeId: recipe.id,
      revision: recipe.revision,
      ...(recipe.title !== undefined ? { title: recipe.title } : {}),
      fit: computed.fit
    };
  });
  for (const line of pantry.items) {
    if (line.state === "needs-reconfirming") {
      unknowns.push(`pantry: "${line.name}" needs reconfirming — its evidence is stale`);
    }
  }
  return { goal: goal.text ?? "", candidates, evidence, unknowns };
}

// ---------------------------------------------------------------------------
// getPantrySummary
// ---------------------------------------------------------------------------

export interface PantrySummaryResult extends ToolEnvelope {
  readonly revision: number;
  readonly useSoon: PantrySnapshot["items"];
  readonly other: PantrySnapshot["items"];
}

/** Bounded pantry lines with states, use-soon first. */
export function getPantrySummary(deps: ReadDeps): PantrySummaryResult {
  const pantry = deps.pantry();
  const useSoon = pantry.items.filter((l) => l.useSoon === true);
  const other = pantry.items.filter((l) => l.useSoon !== true);
  const unknowns: string[] = [];
  for (const line of pantry.items) {
    if (line.state === "quantity-unknown") unknowns.push(`pantry: "${line.name}" quantity is unknown`);
    if (line.state === "assumed-staple") unknowns.push(`pantry: "${line.name}" is an assumed staple, not observed stock`);
    if (line.state === "needs-reconfirming") unknowns.push(`pantry: "${line.name}" needs reconfirming`);
    if (line.state === "short") unknowns.push(`pantry: "${line.name}" is short${line.shortBy !== undefined ? ` by ${line.shortBy} ${line.quantity.kind === "known" ? line.quantity.unit : "units"}` : ""}`);
  }
  return {
    revision: pantry.revision,
    useSoon,
    other,
    evidence: [
      { kind: "pantry-line", ref: `pantry-revision-${pantry.revision}`, detail: `${pantry.items.length} line(s), use-soon first` }
    ],
    unknowns
  };
}

// ---------------------------------------------------------------------------
// getRecipeContext / getStepContext
// ---------------------------------------------------------------------------

export interface RecipeContextResult extends ToolEnvelope {
  readonly recipe: RecipeContext | null;
}

export function getRecipeContext(deps: ReadDeps): RecipeContextResult {
  const session = deps.session();
  const recipe = deps.catalog().find((r) => r.id === currentRecipeId(session)) ?? null;
  if (!recipe) {
    return {
      recipe: null,
      evidence: [
        { kind: "session-state", ref: `session:${session.state}`, detail: `step ${session.currentStepIndex}` }
      ],
      unknowns: ["no recipe context is loaded for this cook session"]
    };
  }
  return {
    recipe,
    evidence: [
      { kind: "recipe-bill", ref: `${recipe.id}@r${recipe.revision}`, detail: `${recipe.ingredientBill.length} bill line(s), ${recipe.steps.length} step(s)` },
      { kind: "session-state", ref: `session:${session.state}`, detail: `step ${session.currentStepIndex}` }
    ],
    unknowns: []
  };
}

function currentRecipeId(session: CookSessionSnapshot): string | undefined {
  return session.recipeId;
}

export interface StepContextResult extends ToolEnvelope {
  readonly state: CookSessionSnapshot["state"];
  readonly currentStepIndex: number;
  readonly step: RecipeContext["steps"][number] | null;
  readonly activeTimers: CookSessionSnapshot["activeTimers"];
  readonly recentSteps: CookSessionSnapshot["stepHistory"];
  readonly eaters: readonly Eater[];
}

/** Current recipe/step, active timers, recent step history. */
export function getStepContext(deps: ReadDeps): StepContextResult {
  const session = deps.session();
  const recipe = deps.catalog().find((r) => r.id === currentRecipeId(session)) ?? null;
  const step = recipe?.steps.find((s) => s.index === session.currentStepIndex) ?? null;
  const unknowns: string[] = [];
  if (!recipe) unknowns.push("no recipe context is loaded for this cook session");
  else if (!step) unknowns.push(`recipe ${recipe.id} has no step ${session.currentStepIndex}`);
  const recent = (session.stepHistory ?? []).slice(-5);
  return {
    state: session.state,
    currentStepIndex: session.currentStepIndex,
    step: step ?? null,
    activeTimers: session.activeTimers,
    recentSteps: recent,
    eaters: session.eaters,
    evidence: [
      { kind: "session-state", ref: `session:${session.state}`, detail: `step ${session.currentStepIndex}, ${session.activeTimers.length} active timer(s)` },
      ...(recipe ? [{ kind: "recipe-bill" as const, ref: `${recipe.id}@r${recipe.revision}`, detail: `step ${step?.index ?? "?"} of ${recipe.steps.length}` }] : [])
    ],
    unknowns
  };
}

// ---------------------------------------------------------------------------
// requestCameraLook — device-mediated, proposal-gated (SPEC 3.1)
// ---------------------------------------------------------------------------

/**
 * The device-mediated camera surface. The phone shows the viewfinder and the
 * user explicitly uploads a clip of at most maxClipSeconds; the fake phone /
 * harness supplies observations. There is NO path from here to a safety
 * verdict — the result type cannot carry one.
 */
export interface CameraDevice {
  readonly mode: CameraMode;
  capture(input: { maxClipSeconds: number }): {
    observed: readonly string[];
    cannotAssess: readonly string[];
    framesSent: number;
    clipSeconds: number;
  };
}

export interface CameraLookResult extends ToolEnvelope {
  readonly look: {
    readonly observed: readonly string[];
    readonly cannotAssess: readonly string[];
    readonly framesSent: number;
    readonly clipSeconds: number;
  };
  /** Always null — structurally, a camera look cannot yield a safety verdict (SPEC 3.1). */
  readonly safetyVerdict: null;
}

export function requestCameraLook(deps: ReadDeps, device: CameraDevice, input: { maxClipSeconds?: number } = {}): CameraLookResult {
  const maxClipSeconds = Math.min(input.maxClipSeconds ?? 3, 3); // hard cap 3 s
  const capture = device.capture({ maxClipSeconds });
  // SPEC 3.1 (binding): a camera look describes what a picture can show and
  // says what it cannot assess — it never gives a safety verdict. The capture
  // strings are free text, so the lint refuses verdict language here, failing
  // closed instead of relaying it (safetyVerdict: null alone cannot prevent
  // verdict language riding inside `observed`).
  const lintFindings = lintCameraObservations(capture.observed);
  if (lintFindings.length > 0) {
    throw new CameraLintError(lintFindings);
  }
  return {
    look: {
      observed: capture.observed,
      cannotAssess: capture.cannotAssess,
      framesSent: capture.framesSent,
      clipSeconds: capture.clipSeconds
    },
    safetyVerdict: null,
    evidence: [
      { kind: "device-observation", ref: `camera:${device.mode}`, detail: `${capture.framesSent} frame(s), ${capture.clipSeconds}s clip` }
    ],
    unknowns: [
      ...capture.cannotAssess.map((c) => `camera cannot assess: ${c}`),
      "a camera look can never establish doneness or safety (SPEC 3.1) — use checkFoodSafety for a thermometer test"
    ]
  };
}
