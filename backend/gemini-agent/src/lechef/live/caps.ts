/**
 * Cap ledger — the hard spend ceiling for a live run.
 *
 * Both caps are enforced on every request; whichever binds first aborts the
 * run ("the stricter of the two"). A request is authorized only if sending
 * it keeps the run under BOTH ceilings:
 *  - requests sent so far + 1 <= maxRequests
 *  - committed spend so far + this request's pre-computed estimate <= maxSpendUsd
 *
 * "Committed spend" is the provider-reported usage cost so far, or — when a
 * response reports no usage — the conservative estimate for that response
 * (input estimate + maxOutputTokens upper bound). A request that would
 * exceed either cap is NEVER sent: the ledger refuses before the transport
 * fires, and the run aborts cleanly with the cap state in the summary.
 */

import type { CostEstimate, LiveCaps, TokenPrices } from "./types.js";
import { estimateRequestCost, actualCostOf } from "./pricing.js";

/** Why the ledger refused a request. */
export type CapBreach = "spend-cap" | "request-cap";

export interface Authorization {
  readonly allowed: boolean;
  readonly breach?: CapBreach;
  /** The refusal message for the log; absent when allowed. */
  readonly detail?: string;
  /** The pre-request estimate this authorization is bound to; absent when refused. */
  readonly estimate?: CostEstimate;
}

/** Runtime state of both caps, reported on abort and in every summary. */
export interface CapState {
  readonly requestsSent: number;
  readonly maxRequests: number;
  readonly committedSpendUsd: number;
  readonly maxSpendUsd: number;
}

export class CapLedger {
  private sent = 0;
  private committedUsd = 0;

  constructor(
    private readonly caps: LiveCaps,
    private readonly prices: TokenPrices
  ) {}

  /**
   * Compute the pre-request estimate and check both caps. The estimate is
   * charged to the committed total IMMEDIATELY when the request is sent
   * (see `chargeEstimate`) so a crash between send and response still
   * counts the attempt.
   */
  authorize(input: {
    readonly systemChars: number;
    readonly contextChars: number;
    readonly maxOutputTokens: number;
  }): Authorization {
    if (this.sent + 1 > this.caps.maxRequests) {
      return {
        allowed: false,
        breach: "request-cap",
        detail: `request ${this.sent + 1} would exceed LECHEF_LIVE_MAX_REQUESTS=${this.caps.maxRequests}`
      };
    }
    const est = estimateRequestCost({
      systemChars: input.systemChars,
      contextChars: input.contextChars,
      maxOutputTokens: input.maxOutputTokens,
      prices: this.prices
    });
    if (this.committedUsd + est.estimatedCostUsd > this.caps.maxSpendUsd) {
      return {
        allowed: false,
        breach: "spend-cap",
        detail:
          `estimated cost $${est.estimatedCostUsd.toFixed(6)} would exceed ` +
          `LECHEF_LIVE_MAX_SPEND_USD=${this.caps.maxSpendUsd} (committed $${this.committedUsd.toFixed(6)})`
      };
    }
    return { allowed: true, estimate: est };
  }

  /** The estimate this request was authorized with — charged at send time. */
  lastAuthorizationEstimate: CostEstimate | undefined;

  /** Charge the pre-request estimate (called when the request is actually sent). */
  chargeEstimate(est: CostEstimate): void {
    this.lastAuthorizationEstimate = est;
    this.sent += 1;
    this.committedUsd += est.estimatedCostUsd;
  }

  /**
   * Reconcile with provider-reported usage: replace the charged estimate
   * with the actual cost (delta may be negative — estimates are upper
   * bounds). Absent usage keeps the estimate.
   */
  recordActual(usage: { readonly inputTokens: number; readonly outputTokens: number } | undefined): number {
    if (usage === undefined) return this.committedUsd;
    const actual = actualCostOf(usage, this.prices);
    this.committedUsd = Math.max(0, this.committedUsd + actual - (this.lastAuthorizationEstimate?.estimatedCostUsd ?? 0));
    return this.committedUsd;
  }

  state(): CapState {
    return {
      requestsSent: this.sent,
      maxRequests: this.caps.maxRequests,
      committedSpendUsd: this.committedUsd,
      maxSpendUsd: this.caps.maxSpendUsd
    };
  }
}

/**
 * Parse the cap environment. Invalid values refuse (fail closed) rather
 * than fall back to defaults — a typo'd cap must never silently raise the
 * ceiling. Zero is allowed and means "send nothing".
 */
export function parseLiveCaps(env: Readonly<Record<string, string | undefined>>): LiveCaps {
  const rawSpend = env["LECHEF_LIVE_MAX_SPEND_USD"];
  const rawRequests = env["LECHEF_LIVE_MAX_REQUESTS"];
  const maxSpendUsd = rawSpend === undefined ? 1.0 : Number(rawSpend);
  const maxRequests = rawRequests === undefined ? 20 : Number(rawRequests);
  const issues: string[] = [];
  if (!Number.isFinite(maxSpendUsd) || maxSpendUsd < 0) {
    issues.push(`LECHEF_LIVE_MAX_SPEND_USD: expected a non-negative number, got "${rawSpend ?? ""}"`);
  }
  if (!Number.isInteger(maxRequests) || maxRequests < 0) {
    issues.push(`LECHEF_LIVE_MAX_REQUESTS: expected a non-negative integer, got "${rawRequests ?? ""}"`);
  }
  if (issues.length > 0) throw new Error(issues.join("; "));
  return { maxSpendUsd, maxRequests };
}
