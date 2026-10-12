/**
 * Per-session JSONL logs and run summaries.
 *
 * One JSONL file per (arm, session) under the run directory:
 *
 *   <outDir>/<runId>/<arm>--<sessionId>.jsonl
 *
 * Every line is one self-contained JSON entry with a wall-clock `ts`
 * (ISO 8601), the arm, the session id and an entry `kind`. Requests log
 * SIZES and cost estimates, never the request content and never the API
 * key; responses log the emitted text and provider usage.
 *
 * Logs are evaluation artifacts, not source: the run directory defaults to
 * `evaluation/lechef-live-runs/` and is NEVER committed (README-live.md).
 * Writes are append-and-flush per entry so a crashed run leaves every
 * earlier entry readable.
 */

import { mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import type { CapBreach, CapState } from "./caps.js";
import type { CostEstimate } from "./types.js";

export type LogKind =
  | "session-start"
  | "request"
  | "response"
  | "tool-dispatch"
  | "user-action"
  | "turn-suppressed"
  | "suggestion-silenced"
  | "cap-abort"
  | "transport-error"
  | "note"
  | "session-end"
  | "run-end";

export interface LogEntry {
  readonly ts: string;
  readonly runId: string;
  readonly arm: string;
  readonly sessionId: string;
  readonly kind: LogKind;
  readonly model?: string;
  readonly transport?: string;
  readonly [field: string]: unknown;
}

/** One JSONL stream for one (arm, session). */
export class SessionLog {
  private readonly path: string;

  constructor(
    readonly outDir: string,
    readonly runId: string,
    readonly arm: string,
    readonly sessionId: string
  ) {
    this.path = join(outDir, runId, `${arm}--${sessionId}.jsonl`);
    mkdirSync(join(outDir, runId), { recursive: true });
  }

  get filePath(): string {
    return this.path;
  }

  append(entry: Omit<LogEntry, "ts" | "runId" | "arm" | "sessionId"> & { readonly ts?: string }, ts: string): void {
    const line = JSON.stringify({
      ts,
      runId: this.runId,
      arm: this.arm,
      sessionId: this.sessionId,
      ...entry
    });
    appendFileSync(this.path, line + "\n");
  }
}

/** The run-level summary written once per arm plus one run-wide summary. */
export interface ArmSummary {
  readonly arm: string;
  readonly design: string;
  readonly model: string;
  readonly transport: string;
  readonly sessions: { readonly attempted: number; readonly completed: number; readonly aborted: number };
  readonly requests: { readonly sent: number; readonly maxAllowed: number };
  readonly usage: { readonly estimatedCostUsd: number; readonly actualCostUsd: number | null };
  readonly capState: "within" | CapBreach;
  readonly capDetail?: string;
  readonly logsDir: string;
  readonly completedSessionIds: readonly string[];
}

export interface RunSummary {
  readonly runId: string;
  readonly model: string;
  readonly arms: readonly ArmSummary[];
  readonly capState: "within" | CapBreach;
  readonly capDetail?: string;
  readonly logsDir: string;
}

export function writeJson(outDir: string, runId: string, name: string, value: unknown): string {
  const dir = join(outDir, runId);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, name);
  writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
  return path;
}

export { estimateRequestCost, actualCostOf } from "./pricing.js";
export type { CapState, CostEstimate };
