/**
 * Live configuration — resolved from the ENVIRONMENT ONLY, once, at the
 * explicit live command. Nothing else reads credentials: no config files,
 * nodotenv-style fallbacks, no mid-run re-reads. A key that appears in the
 * environment later is invisible to a running or planned session; going
 * live is always an explicit command (`--mode=live`).
 *
 * Refusals fail closed and name the env var (never the value): no key,
 * unknown provider, unknown model without explicit prices, invalid caps.
 */

import { parseLiveCaps } from "./caps.js";
import { tablePricesFor } from "./pricing.js";
import type { LiveConfig, LiveRefusal, TokenPrices } from "./types.js";

export const LIVE_API_KEY_ENV = "LECHEF_LIVE_API_KEY";

/** The provider this runner knows how to talk to. Adding one is a code change, not a config change. */
const SUPPORTED_PROVIDER = "gemini";
const DEFAULT_MODEL = "gemini-2.0-flash";
const DEFAULT_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta";
const DEFAULT_OUT_DIR = "evaluation/lechef-live-runs";
const DEFAULT_MAX_OUTPUT_TOKENS = 512;
const DEFAULT_MAX_TOOL_ROUNDS = 4;

function positiveInt(raw: string | undefined, name: string, fallback: number): number {
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`${name}: expected a positive integer, got "${raw}"`);
  }
  return n;
}

/**
 * Resolve the live configuration from env. Returns a refusal for every
 * "cannot start live" condition; `parseLiveCaps` throws on malformed caps
 * (also a refusal — caught by the CLI and reported as exit 2).
 */
export function readLiveConfig(env: Readonly<Record<string, string | undefined>>): LiveConfig | LiveRefusal {
  const apiKey = env[LIVE_API_KEY_ENV];
  if (apiKey === undefined || apiKey.trim() === "") {
    return {
      reason:
        `${LIVE_API_KEY_ENV} is not set — refusing to start a live run. ` +
        `Without a key the runner can still plan: run with --mode=plan. ` +
        `A live run is an explicit command and needs the operator's authorization ` +
        `(see backend/gemini-agent/README-live.md).`
    };
  }

  const provider = env["LECHEF_LIVE_PROVIDER"] ?? SUPPORTED_PROVIDER;
  if (provider !== SUPPORTED_PROVIDER) {
    return { reason: `LECHEF_LIVE_PROVIDER="${provider}" is not supported (only "${SUPPORTED_PROVIDER}")` };
  }

  const caps = parseLiveCaps(env);

  const model = env["LECHEF_LIVE_MODEL"] ?? DEFAULT_MODEL;
  const priceIn = env["LECHEF_LIVE_PRICE_IN_PER_MTOK"];
  const priceOut = env["LECHEF_LIVE_PRICE_OUT_PER_MTOK"];
  let prices: TokenPrices;
  let priceSource: string;
  if (priceIn !== undefined || priceOut !== undefined) {
    // Explicit prices must come as a pair — half a price is a typo, refuse.
    if (priceIn === undefined || priceOut === undefined) {
      return {
        reason: "set BOTH LECHEF_LIVE_PRICE_IN_PER_MTOK and LECHEF_LIVE_PRICE_OUT_PER_MTOK (got only one)"
      };
    }
    const inN = Number(priceIn);
    const outN = Number(priceOut);
    if (!Number.isFinite(inN) || inN < 0 || !Number.isFinite(outN) || outN < 0) {
      return { reason: "LECHEF_LIVE_PRICE_*_PER_MTOK: expected non-negative numbers" };
    }
    prices = { inputUsdPerMTok: inN, outputUsdPerMTok: outN };
    priceSource = "env";
  } else {
    const table = tablePricesFor(model);
    if (table === undefined) {
      return {
        reason:
          `LECHEF_LIVE_MODEL="${model}" has no built-in price; refusing to estimate cost against an unknown ` +
          `price. Set both LECHEF_LIVE_PRICE_IN_PER_MTOK and LECHEF_LIVE_PRICE_OUT_PER_MTOK explicitly.`
      };
    }
    prices = table;
    priceSource = `table:${model}`;
  }

  const maxOutputTokens = positiveInt(env["LECHEF_LIVE_MAX_OUTPUT_TOKENS"], "LECHEF_LIVE_MAX_OUTPUT_TOKENS", DEFAULT_MAX_OUTPUT_TOKENS);
  const maxToolRounds = positiveInt(env["LECHEF_LIVE_MAX_TOOL_ROUNDS"], "LECHEF_LIVE_MAX_TOOL_ROUNDS", DEFAULT_MAX_TOOL_ROUNDS);

  return {
    apiKey,
    provider,
    model,
    endpoint: env["LECHEF_LIVE_ENDPOINT"] ?? DEFAULT_ENDPOINT,
    caps,
    prices,
    priceSource,
    maxOutputTokens,
    maxToolRounds,
    outDir: env["LECHEF_LIVE_OUT"] ?? DEFAULT_OUT_DIR
  };
}
