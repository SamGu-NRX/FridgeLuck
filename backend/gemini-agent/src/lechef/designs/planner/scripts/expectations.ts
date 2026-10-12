/**
 * Expected-shape declarations for the planner's design scripts.
 *
 * Each fixture declares what the design runner MUST produce for it —
 * suppressions (with reasons), tool-call dispositions, proposal lifecycles,
 * timer outcomes. designs/planner/run.ts replays every script and exits
 * nonzero on any mismatch; the bun tests assert the same expectations plus
 * finer detail (exact denial payloads, receipts, events).
 *
 * These are design-local types: nothing here feeds the shared layer or the
 * RunRecord contract.
 */

import type { ScriptUserAction, SessionScript } from "../../../fakeModel.js";
import type { ToolCallStatus } from "../../../runtime.js";

export interface ExpectedToolCall {
  readonly id: string;
  readonly name: string;
  readonly status: ToolCallStatus;
  /**
   * When set, the recorded result must deep-equal this — used to pin exact
   * policy-denial payloads ({ error: "policy-denied", deniedBy, reason }).
   */
  readonly result?: unknown;
}

export interface ExpectedProposal {
  readonly tool: string;
  readonly requiredApproval: "device-auto" | "explicit";
  readonly state: "proposed" | "approved" | "executed" | "rejected" | "cancelled" | "expired";
}

export interface ExpectedTimer {
  readonly label: string;
  readonly minutes: number;
  /** True when the timer fired (deadline passed on the injected clock). */
  readonly fired: boolean;
  readonly survivedKill: boolean;
}

export interface ScriptExpectations {
  /** Suppressed SOURCE turns in source order: index and gate reason. */
  readonly suppressed: readonly { readonly turn: number; readonly because: string }[];
  readonly remappedActions?: readonly { readonly from: number; readonly to: number }[];
  readonly droppedActions?: readonly { readonly afterTurn: number; readonly action: ScriptUserAction }[];
  /** Recorded tool calls in record order. */
  readonly toolCalls: readonly ExpectedToolCall[];
  /** Proposals in creation order, with lifecycle state at record time. */
  readonly proposals: readonly ExpectedProposal[];
  /** Timer records in creation order. */
  readonly timers: readonly ExpectedTimer[];
}

/** One planner design fixture: the source script plus its expected replay shape. */
export interface PlannerScriptFixture {
  readonly name: string;
  /** One-line statement of what this fixture probes. */
  readonly blurb: string;
  readonly script: SessionScript;
  readonly expect: ScriptExpectations;
}
