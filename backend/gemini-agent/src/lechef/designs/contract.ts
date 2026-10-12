/**
 * LeChef design contract — the shared shape all three LeChef designs
 * (companion, planner, coach) implement.
 *
 * Parent-owned join infrastructure (fl-lechef-f1): the design tasks own
 * their design directory only; this file and run/designRunner.ts own the
 * gating mechanics so the designs cannot drift apart.
 *
 * A design is CONFIGURATION, not a model. Offline replay (suite D) scripts
 * the conversational material; the design gates what passes through — which
 * tool calls its policy denies, how much unprompted speech its budget
 * allows, when its suggestion types fall silent. The system prompt is
 * documented here for the later native wiring; offline runs never execute
 * it.
 */

import type { ScriptTurn } from "../fakeModel.js";

/**
 * Deny-list rule for tool calls. Everything not denied is allowed — policies
 * are written as explicit denials so the safe default is "the layer works".
 *
 * `when` splits calls by the proactivity of the turn carrying them:
 * - "proactive": the assistant speaks without a preceding user turn in the
 *   source script (see run/designRunner.ts);
 * - "prompted": the turn answers a user turn;
 * - "any": both.
 */
export interface ToolPolicyRule {
  /** Tool names this rule denies, or "*" for every tool. */
  readonly tools: readonly string[] | "*";
  readonly when: "any" | "proactive" | "prompted";
  /** Why the design denies this — surfaced verbatim in denial results. */
  readonly reason: string;
}

/**
 * Unprompted-speech budget: at most `maxUnpromptedTurns` proactive assistant
 * turns per session, with at least `minGapTurns` EMITTED turns (any role)
 * between two. A user turn between two assistant turns makes the later one
 * prompted, so the gap binds inside consecutive proactive runs (adjacent
 * unprompted turns violate any positive gap) and across them.
 */
export interface TurnBudget {
  readonly maxUnpromptedTurns: number;
  readonly minGapTurns: number;
}

export interface LeChefDesign {
  /** Stable id stamped into RunRecord.design (the scorer groups by it). */
  readonly id: string;
  readonly title: string;
  /** One-paragraph thesis, cross-referenced from the design's DESIGN.md. */
  readonly summary: string;
  /** Native-wiring system prompt. Documented, not executed offline. */
  readonly systemPrompt: string;
  readonly toolPolicy: readonly ToolPolicyRule[];
  readonly turnBudget: TurnBudget;
  /**
   * How this design recognizes its own proactive suggestion type from a
   * scripted turn (null = not a suggestion). Drives third-rejection
   * silence; a design without a matcher has no silence rule.
   */
  readonly suggestionType?: (turn: ScriptTurn) => string | null;
  /**
   * What counts as the user rejecting a suggestion. Defaults to an explicit
   * no-ish opener; designs may tighten it.
   */
  readonly isRejection?: (userTurn: ScriptTurn) => boolean;
}

/** Default rejection matcher: an explicit no-ish opener, nothing subtle. */
export function defaultIsRejection(turn: ScriptTurn): boolean {
  return /^(no|nope|not now|stop|stop suggesting|don't|do not|not interested|no thanks|nah)\b/i.test(
    turn.text.trim()
  );
}
