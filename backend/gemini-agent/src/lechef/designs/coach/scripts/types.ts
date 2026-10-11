/**
 * Coach script fixture types — a CoachCase pairs a SessionScript with the
 * shape its replay MUST produce. The replay runner (../run.ts) asserts every
 * case's expectations and exits nonzero on any mismatch; the design's tests
 * pin the same expectations from src/__tests__/lechef/designs/coach/.
 */

import type { SessionScript } from "../../../fakeModel.js";
import type { DispatchResult } from "../../../runtime.js";

type CallStatus = DispatchResult["status"];
type ProposalLifecycle = "proposed" | "approved" | "executed" | "rejected" | "cancelled" | "expired";

/** The expected shape of one coach replay. Fields are compared exactly. */
export interface CoachExpectation {
  /** Gate suppressions, in turn order. */
  readonly suppressed: readonly { readonly turn: number; readonly because: string }[];
  /** Turn indexes that survive into the record, in order. */
  readonly keptTurns: readonly number[];
  /** Every recorded tool call by id, with its status and policy-denial flag. */
  readonly toolStatus: readonly {
    readonly id: string;
    readonly status: CallStatus;
    readonly policyDenied?: boolean;
  }[];
  /** Expected policy-denial reason per call id (checked verbatim when present). */
  readonly denialReasons?: Readonly<Record<string, string>>;
  /** Proposals in creation order (tool, approval class, end state). */
  readonly proposals?: readonly {
    readonly tool: string;
    readonly requiredApproval: "device-auto" | "explicit";
    readonly state: ProposalLifecycle;
  }[];
  /** Receipt states in log order. */
  readonly receiptStates?: readonly string[];
  /** Timer labels in creation order. */
  readonly timerLabels?: readonly string[];
  /** Camera look events recorded. */
  readonly cameraLooks?: number;
  /** Frames sent across the session. */
  readonly framesSent?: number;
  /** TemperatureC of every sourced doneness answer, in record order. */
  readonly donenessTemps?: readonly number[];
  /** Count of non-doneness answers (e.g. substitution lookups). */
  readonly otherAnswers?: number;
  /** Suggestion types silenced this session (sorted, unique). */
  readonly silencedTypes?: readonly string[];
  /** Total turns in the record (kept turns, both roles). */
  readonly usageTurns: number;
  /** User-action remaps from suppressed turns (sorted by `from`). */
  readonly remappedActions?: readonly { readonly from: number; readonly to: number }[];
  /** User actions dropped for want of a following kept turn. */
  readonly droppedActions?: number;
}

/** One focused coach fixture: the script plus the shape its replay must have. */
export interface CoachCase {
  readonly name: string;
  /** One line: the behavior this script probes. */
  readonly focus: string;
  readonly script: SessionScript;
  readonly expect: CoachExpectation;
}
