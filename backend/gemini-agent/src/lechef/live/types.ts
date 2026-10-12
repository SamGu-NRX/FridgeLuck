/**
 * Live runner types — the opt-in, env-key, capped real-model path for the
 * LeChef design comparison.
 *
 * The offline harness (run/harness.ts + run/designRunner.ts) replays
 * SCRIPTED turns: the script IS the provider, so there is no model seam to
 * inject into. The live runner therefore owns its own session loop
 * (live/liveSession.ts) and reuses the offline seams that are
 * provider-independent: the per-design configs under designs/<arm>/design.ts,
 * `wrapWithPolicy` tool gating, `buildSessionWorld`, `estimateTokens`, and
 * the pinned RunRecord assembly surfaces.
 *
 * A real provider is reached ONLY through the injected `LiveTransport`.
 * Tests inject a mock transport; nothing in src/lechef/live/ is ever run
 * against a real API by the test suite. Live execution requires the
 * operator's explicit key + scope + cap authorization (see README-live.md).
 */

/**
 * One request to the model provider. `messages` is the conversation so far
 * (user turns from the source script + generated assistant text);
 * `toolResults` carries dispatched tool results back to the model within the
 * same exchange.
 */
export interface LiveTransportRequest {
  readonly system: string;
  readonly messages: readonly { readonly role: "user" | "assistant"; readonly text: string }[];
  readonly toolResults: readonly {
    readonly callId: string;
    readonly name: string;
    readonly resultJson: string;
  }[];
  readonly maxOutputTokens: number;
}

/** One model response. `usage` is provider-reported; absent usage falls back to estimates (conservative). */
export interface LiveTransportResponse {
  readonly text: string;
  readonly toolCalls: readonly {
    readonly id: string;
    readonly name: string;
    readonly args?: Readonly<Record<string, unknown>>;
  }[];
  readonly usage?: { readonly inputTokens: number; readonly outputTokens: number };
}

/**
 * The provider seam. Every send is one billable request — the cap ledger
 * authorizes each send BEFORE it happens (run/liveSession.ts).
 */
export interface LiveTransport {
  /** e.g. "gemini" or "mock" — logged, never the key. */
  readonly name: string;
  readonly model: string;
  send(request: LiveTransportRequest): Promise<LiveTransportResponse>;
}

/** Hard spend caps — BOTH are enforced; the stricter one binds (caps.ts). */
export interface LiveCaps {
  readonly maxSpendUsd: number;
  readonly maxRequests: number;
}

/** USD price per million tokens, input and output. */
export interface TokenPrices {
  readonly inputUsdPerMTok: number;
  readonly outputUsdPerMTok: number;
}

/**
 * Fully resolved live configuration. Built only from the environment
 * (config.ts) — a run never re-reads env mid-flight, so a key that appears
 * later is never picked up automatically.
 */
export interface LiveConfig {
  readonly apiKey: string;
  readonly provider: string;
  readonly model: string;
  readonly endpoint: string;
  readonly caps: LiveCaps;
  readonly prices: TokenPrices;
  /** Source of `prices`: "table:<model>" or "env" — logged and printed. */
  readonly priceSource: string;
  readonly maxOutputTokens: number;
  readonly maxToolRounds: number;
  readonly outDir: string;
}

/** Why a live start refused to start. Never contains the key value. */
export interface LiveRefusal {
  readonly reason: string;
}

/** The token-cost estimate computed BEFORE a request is sent. */
export interface CostEstimate {
  readonly estimatedInputTokens: number;
  readonly estimatedOutputTokens: number;
  readonly estimatedCostUsd: number;
}
