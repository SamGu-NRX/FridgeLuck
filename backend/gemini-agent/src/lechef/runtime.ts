/**
 * The LeChef runtime — tool dispatch over a phone executor (SPEC §8.3).
 * Adapted from #102's runtime.ts: 6 read tools + 9 proposal tools, registered
 * names only. Unknown tool names are a typed error result, never a throw
 * across the model boundary, and no unregistered action can execute.
 */

import type { Clock } from "./types.js";
import { createProposalTools, type PhoneExecutor, type ProposalArgs, type ProposalTools } from "./proposals.js";
import {
  cameraLook,
  checkFoodSafety,
  defaultReadTools,
  getPlan,
  getPantry,
  getStepContext,
  lookupSubstitution
} from "./reads.js";
import type { FoodSafetyTool } from "./foodSafety.js";
import { createFoodSafetyTool } from "./foodSafety.js";
import type { SubstitutionTool } from "./substitutions.js";
import { createSubstitutionTool } from "./substitutions.js";
import { lintCameraObservations } from "./cameraLint.js";
import { lintInstructionInjection } from "./reads.js";

/** The 15 registered tool names (SPEC §8.3): six reads, nine proposals. */
export const REGISTERED_TOOLS: readonly string[] = [
  "getPantry",
  "getStepContext",
  "getPlan",
  "checkFoodSafety",
  "cameraLook",
  "lookupSubstitution",
  "proposeTimerStart",
  "proposeTimerAdjust",
  "proposeStepAdvance",
  "proposeInventoryCorrection",
  "proposeMealLog",
  "proposeSaveNote",
  "proposePlan",
  "proposeSwap",
  "proposeAdaptation"
] as const;

export type ToolCallResult = Record<string, unknown>;

export interface RuntimeOptions {
  readonly phone: PhoneExecutor;
  readonly clock: Clock;
  /** Override the food-safety tool (tests). Default: the pinned-canon tool. */
  readonly foodSafety?: FoodSafetyTool;
  /** Override the substitution tool (tests). Default: the canon-table tool. */
  readonly substitutions?: SubstitutionTool;
  /** Override the camera lint (knock-out tests). Default: the fail-closed verdict lint. */
  readonly cameraLint?: typeof lintCameraObservations;
  /** Override the instruction-injection lint (knock-out tests). Default: the fail-closed injection lint. */
  readonly instructionLint?: typeof lintInstructionInjection;
}

export class LeChefRuntime {
  private readonly phone: PhoneExecutor;
  private readonly clock: Clock;
  private readonly reads: ReturnType<typeof defaultReadTools>;
  private readonly proposals: ProposalTools;

  constructor(options: RuntimeOptions) {
    this.phone = options.phone;
    this.clock = options.clock;
    const foodSafety = options.foodSafety ?? createFoodSafetyTool();
    const substitutions = options.substitutions ?? createSubstitutionTool();
    this.reads = {
      getPantry: () => getPantry(this.phone),
      getStepContext: () => getStepContext(this.phone, options.instructionLint ?? lintInstructionInjection),
      getPlan: () => getPlan(this.phone),
      checkFoodSafety: (input) => checkFoodSafety(this.phone, foodSafety, input),
      cameraLook: (input) => cameraLook(this.phone, input, options.cameraLint ?? lintCameraObservations),
      lookupSubstitution: (input) => lookupSubstitution(this.phone, substitutions, input)
    };
    this.proposals = createProposalTools({ phone: this.phone, clock: this.clock });
  }

  /** Dispatch one tool call by registered name. */
  dispatch(toolName: string, args: unknown = {}): ToolCallResult {
    if (!REGISTERED_TOOLS.includes(toolName)) {
      return {
        toolError: "unknown_tool",
        detail: `"${toolName}" is not a registered LeChef tool; registered: ${REGISTERED_TOOLS.join(", ")}`
      };
    }
    try {
      switch (toolName) {
        case "getPantry":
          return this.reads.getPantry() as unknown as ToolCallResult;
        case "getStepContext":
          return this.reads.getStepContext() as unknown as ToolCallResult;
        case "getPlan":
          return this.reads.getPlan() as unknown as ToolCallResult;
        case "checkFoodSafety":
          return this.reads.checkFoodSafety((args ?? {}) as { product?: string }) as unknown as ToolCallResult;
        case "cameraLook":
          return this.reads.cameraLook((args ?? {}) as { mode?: "push-to-look" | "continuous" }) as unknown as ToolCallResult;
        case "lookupSubstitution":
          return this.reads.lookupSubstitution((args ?? {}) as { ingredient: string; context?: string }) as unknown as ToolCallResult;
        default: {
          const proposalTool = toolName as keyof ProposalTools;
          return this.proposals[proposalTool]((args ?? {}) as ProposalArgs) as unknown as ToolCallResult;
        }
      }
    } catch (error) {
      // Tool bugs surface as typed results, never as throws across the model boundary.
      return { toolError: "tool_failure", detail: (error as Error).message };
    }
  }

  /** The registered tool names, for prompt wiring and tests. */
  registeredTools(): readonly string[] {
    return REGISTERED_TOOLS;
  }
}
