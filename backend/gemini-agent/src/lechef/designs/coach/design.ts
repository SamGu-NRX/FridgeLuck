/**
 * The COACH design — competing LeChef voice-design configuration #3
 * (branch overhaul/lechef-design-coach).
 *
 * Thesis: in-the-moment guidance during cooking. The coach emphasizes the
 * step you are on and the one coming next, surfaces food-safety READS
 * proactively (a sourced thermometer test, never a camera verdict), grounds
 * use-soon suggestions in pantry state, and runs a tight speech budget so
 * it never talks over the user. Proposals — step advance included — are
 * made only on the user's ask: guidance flows as speech, the proposal
 * layer belongs to the user. See DESIGN.md in this directory for the full
 * rationale; the system prompt below is documented for the later native
 * wiring and is NOT executed by the offline replay.
 */

import type { LeChefDesign } from "../contract.js";
import type { ScriptTurn } from "../../fakeModel.js";

/**
 * The coach's suggestion types. A suggestion turn OPENS with its type tag
 * ("use-soon:", "safety:", "substitution:") — the same fixture convention
 * the shared contract tests use. A turn that does not start with a marker
 * is not a suggestion and never feeds the third-rejection silence rule.
 */
export const COACH_SUGGESTION_TYPES = ["use-soon", "safety", "substitution"] as const;

/** Deny-list reasons — surfaced verbatim in `{error: "policy-denied"}` results. */
export const COACH_DENY_REASONS = {
  /** Rule 1: proposeMealLog is denied for the coach in EVERY context. */
  mealLog: "meal logs belong to the remember flow at cook-complete, not to the coach mid-cook",
  /** Rule 2: all six propose* tools are denied on proactive turns. */
  proactiveProposal: "proposals need an ask — the coach guides in speech and proposes only on the user's ask",
  /** Rule 3: requestCameraLook is denied on proactive turns. */
  proactiveCamera: "camera looks are push-to-look — captured on an explicit user request, never proactively, and never as a safety verdict (SPEC 3.1)"
} as const;

/** The six proposal tools, widened to `readonly string[]` for ToolPolicyRule. */
const PROPOSAL_TOOLS: readonly string[] = [
  "proposeTimerStart",
  "proposeTimerAdjust",
  "proposeStepAdvance",
  "proposeInventoryCorrection",
  "proposeMealLog",
  "proposeSaveNote"
];

/**
 * The coach's suggestion matcher: the leading tag names the type. Kept as a
 * named export so tests and the replay runner classify turns identically.
 */
export function coachSuggestionType(turn: ScriptTurn): string | null {
  const text = turn.text.trimStart().toLowerCase();
  if (text.startsWith("use-soon:")) return "use-soon";
  if (text.startsWith("safety:")) return "safety";
  if (text.startsWith("substitution:")) return "substitution";
  return null;
}

/**
 * Native-wiring system prompt. Documented, not executed offline — the
 * offline replay scripts the conversational material and the design gates
 * what passes through.
 */
const SYSTEM_PROMPT = [
  "You are LeChef in cook mode. The user has wet hands and a hot pan; the step in front of them is the only thing that matters.",
  "Speak when spoken to. Between steps you stay quiet unless a read gives you something actionable for THIS step: a safety-critical product (surface the sourced thermometer test from checkFoodSafety, with the temperature and the source named) or a pantry item that will be lost (offer it for the step that uses it, once).",
  "Safety is sourced or silent: doneness is a thermometer test with the temperature and source named; you never judge safety from a camera look and never ask the camera for a verdict.",
  "Step movement belongs to the user. Say what is next and what it needs; propose the advance only when they ask ('next'). Propose timers only on an explicit ask ('timer N minutes'). Never propose a meal log — that is the remember flow's job at cook-complete.",
  "Use-soon suggestions are grounded in the pantry read you just made: name the item and the step that uses it, then stop after the user declines twice.",
  "Keep every unprompted turn to one sentence. The five-word vocabulary (next, back, repeat, timer N minutes, show) always works."
].join(" ");

export const coachDesign: LeChefDesign = {
  id: "coach",
  title: "Coach — in-the-moment, safety-first step guidance",
  summary:
    "In-the-moment guidance during cooking: the coach surfaces sourced food-safety reads and pantry-grounded " +
    "use-soon suggestions proactively inside a tight speech budget (at most 2 unprompted turns, at least 2 " +
    "emitted turns between them), keeps every proposal — step advance included — behind the user's ask, and " +
    "treats camera looks as push-to-look only. Full rationale in designs/coach/DESIGN.md.",
  systemPrompt: SYSTEM_PROMPT,
  // Deny-list, first match wins. Reads are never denied.
  toolPolicy: [
    {
      tools: ["proposeMealLog"],
      when: "any",
      reason: COACH_DENY_REASONS.mealLog
    },
    {
      tools: PROPOSAL_TOOLS,
      when: "proactive",
      reason: COACH_DENY_REASONS.proactiveProposal
    },
    {
      tools: ["requestCameraLook"],
      when: "proactive",
      reason: COACH_DENY_REASONS.proactiveCamera
    }
  ],
  turnBudget: { maxUnpromptedTurns: 2, minGapTurns: 2 },
  suggestionType: coachSuggestionType
  // isRejection: the parent default (explicit no-ish openers only) is right
  // for hands-wet, terse cooking speech — see DESIGN.md, "Knobs".
};

/**
 * The coach with every gating knob opened — same identity (id, prompt,
 * suggestion matcher), no policy, no budget. It is the equivalence
 * baseline: through it, a script must replay exactly as the plain harness
 * would (pinned by the design's equivalence tests).
 */
export const coachPermissiveVariant: LeChefDesign = {
  ...coachDesign,
  toolPolicy: [],
  turnBudget: { maxUnpromptedTurns: 999, minGapTurns: 0 }
};
