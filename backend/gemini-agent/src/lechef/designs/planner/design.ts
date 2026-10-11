/**
 * Planner design — the structure-first LeChef configuration.
 *
 * Thesis (see designs/planner/DESIGN.md): LeChef earns its keep before and
 * after the cook, not during it. One batched plan at session open — what to
 * cook, in what order, which timers — then near-zero mid-cook chatter, then
 * a strong remember step at natural closing points.
 *
 * Configuration only, on the shared layer (designs/contract.ts): the offline
 * replay never executes the system prompt; the budget and the deny-list are
 * what actually gate a session. See run/designRunner.ts for the mechanics
 * this design plugs into.
 */

import type { LeChefDesign, ToolPolicyRule } from "../contract.js";
import type { ScriptTurn } from "../../fakeModel.js";

/** The planner's typed proactive suggestions — the units third-rejection silence scopes. */
export type PlannerSuggestionType = "plan-pitch" | "timer-offer" | "meal-log-offer";

/**
 * Offline stand-in for intent classification: design scripts tag their
 * suggestion turns with a stable text prefix ("Plan:", "Timer offer:",
 * "Log offer:"), and a meal-log offer is also recognizable from the
 * proposeMealLog call it carries. Native wiring classifies the model's
 * structured output instead; the matcher contract stays identical.
 */
export function plannerSuggestionType(turn: ScriptTurn): PlannerSuggestionType | null {
  const text = turn.text.trim().toLowerCase();
  if (text.startsWith("plan:")) return "plan-pitch";
  if (text.startsWith("timer offer:")) return "timer-offer";
  if (text.startsWith("log offer:")) return "meal-log-offer";
  if (turn.toolCalls?.some((call) => call.name === "proposeMealLog")) return "meal-log-offer";
  return null;
}

/**
 * Deny-list: the planner's ONLY unprompted proposals are the timers that
 * belong to the opening plan batch. Every other write waits for a prompt —
 * a step advance, inventory correction, note, timer adjustment or meal log
 * is proposed only when the user's words call for it. Reads are never
 * denied (the open is read-heavy by design), and proposeTimerStart is never
 * denied (the up-front timer proposals are the thesis).
 */
export const PROACTIVE_WRITE_DENIALS: ToolPolicyRule = {
  tools: [
    "proposeTimerAdjust",
    "proposeStepAdvance",
    "proposeInventoryCorrection",
    "proposeSaveNote",
    "proposeMealLog"
  ],
  when: "proactive",
  reason:
    "the planner proposes unprompted only inside the opening plan batch (timers); this proposal waits for a prompt"
};

/**
 * The whole proactive allowance is the opening batch: one turn to pitch the
 * plan, one to propose its timers, one to close the open (order, shopping
 * list). minGapTurns MUST be 0 — any positive gap suppresses every adjacent
 * proactive turn, which would make the batch impossible.
 *
 * The contract's TurnBudget is session-wide; it cannot bind the allowance to
 * a phase. A session that never opens with the batch can spend all three
 * turns mid-cook (scripts/...budget-stress probes exactly that). Phase
 * discipline beyond this is carried by the script shape and the documented
 * system prompt — recorded as a limitation, not hacked around. See
 * DESIGN.md, "What the contract cannot express".
 */
const TURN_BUDGET = { maxUnpromptedTurns: 3, minGapTurns: 0 } as const;

export const plannerDesign: LeChefDesign = {
  id: "planner",
  title: "Planner",
  summary:
    "Structure before and after the cook: one batched plan at session open (pick, order, timers — three unprompted turns, no gap rule), silence mid-cook (writes wait for a prompt; timers run on the device), and a remember step that offers the meal log at natural closing points, always explicit-approval, silent after two declines of a suggestion type.",
  systemPrompt: [
    "You are LeChef in planner mode. Your job is structure: decide what to cook, set it up, get out of the way, and remember it afterwards.",
    "",
    "Opening (unprompted, once, batched). When a session starts cold, deliver the whole plan in at most three short turns and then stop:",
    "1. Tonight's pick and one alternative, chosen from what is actually in the fridge, use-soon items first. Never a 7-day grid.",
    "2. The timers the cook needs, named, with minutes — proposed, not started.",
    "3. The order of the cook and, if the plan needs it, a shopping list under 8 items.",
    "Never open with a question and never spread the batch past the budget.",
    "",
    "Mid-cook: silence. You speak only when spoken to. The user's vocabulary is next, back, repeat, timer N minutes, show — answers are short. Timers live on the device: never promise to watch one yourself and never announce a firing unprompted. A camera look never gives a safety verdict; describe what you see and cite the rulebook for anything about doneness.",
    "",
    "Closing (remember). When the user signals the cook is done, offer exactly one meal log — recipe, servings, the swaps actually made — and ask at most one question. The log is always explicit-approval: propose it, never assume it. When the user declines a suggestion twice, that suggestion type is dead for the session; do not find a third way to ask.",
    "",
    "Never: propose a meal log, note, step advance or timer adjustment unprompted; speak between steps uninvited; promise device-unsafe guarantees; or spend the opening batch on anything but the plan."
  ].join("\n"),
  toolPolicy: [PROACTIVE_WRITE_DENIALS],
  turnBudget: TURN_BUDGET,
  suggestionType: plannerSuggestionType
  // isRejection: the contract default (explicit no-ish openers) is kept.
  // The product direction counts "something else" as a weak, ambiguous
  // signal — it must NOT count as a rejection, and the default already
  // excludes it. Tightening further would under-count real refusals.
};
