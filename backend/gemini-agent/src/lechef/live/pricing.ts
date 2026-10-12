/**
 * Live-runner pricing and cost estimation.
 *
 * Prices are a PARAMETER, not a fact (SPEC 4: "real pricing applied as a
 * parameter"; Sam confirms what pays for LeChef). The built-in table holds
 * published list prices from training data — they are defaults to make an
 * estimate possible, never a billing claim. A model missing from the table
 * refuses to run unless LECHEF_LIVE_PRICE_IN_PER_MTOK and
 * LECHEF_LIVE_PRICE_OUT_PER_MTOK are BOTH set (fail closed on pricing).
 *
 * Token estimates reuse the harness convention (`estimateTokens`,
 * ceil(chars / 4)) so live and offline numbers stay comparable; they are
 * estimates, not tokenizer counts. The pre-request estimate is deliberately
 * conservative: output is bounded by the configured maxOutputTokens, and
 * after each response the provider-reported usage replaces the estimate in
 * the running total.
 */

import { estimateTokens } from "../fakeModel.js";
import type { CostEstimate, TokenPrices } from "./types.js";

/**
 * Built-in list prices, USD per million tokens (input, output).
 * From training data (published list prices, October 2026); Sam confirms
 * the applicable prices at live authorization. Overridable by env.
 */
const PRICE_TABLE: Readonly<Record<string, TokenPrices>> = {
  "gemini-2.0-flash": { inputUsdPerMTok: 0.1, outputUsdPerMTok: 0.4 },
  "gemini-2.5-flash": { inputUsdPerMTok: 0.3, outputUsdPerMTok: 2.5 },
  "gemini-2.5-pro": { inputUsdPerMTok: 1.25, outputUsdPerMTok: 10.0 },
  "gemini-1.5-flash": { inputUsdPerMTok: 0.075, outputUsdPerMTok: 0.3 }
};

/** Table lookup; undefined for unknown models (the caller refuses). */
export function tablePricesFor(model: string): TokenPrices | undefined {
  return PRICE_TABLE[model];
}

/**
 * Cost of one request, estimated BEFORE it is sent: input tokens estimated
 * from the serialized request size (chars / 4), output tokens at the
 * configured maximum — an upper bound, so the cap check can only ever
 * over-estimate what this request costs.
 */
export function estimateRequestCost(input: {
  readonly systemChars: number;
  readonly contextChars: number;
  readonly maxOutputTokens: number;
  readonly prices: TokenPrices;
}): CostEstimate {
  const estimatedInputTokens = Math.ceil((input.systemChars + input.contextChars) / 4);
  const estimatedOutputTokens = input.maxOutputTokens;
  const estimatedCostUsd =
    (estimatedInputTokens * input.prices.inputUsdPerMTok +
      estimatedOutputTokens * input.prices.outputUsdPerMTok) /
    1_000_000;
  return { estimatedInputTokens, estimatedOutputTokens, estimatedCostUsd };
}

/** Actual cost from provider-reported usage. */
export function actualCostOf(
  usage: { readonly inputTokens: number; readonly outputTokens: number },
  prices: TokenPrices
): number {
  return (
    (usage.inputTokens * prices.inputUsdPerMTok + usage.outputTokens * prices.outputUsdPerMTok) /
    1_000_000
  );
}

/** Text-token estimate for a response when the provider reports no usage (documented approximation). */
export function estimatedResponseTokens(text: string): number {
  return estimateTokens(text);
}
