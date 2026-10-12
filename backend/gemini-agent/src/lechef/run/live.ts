/**
 * Live runner CLI — the explicit command that runs the three-design
 * comparison against a REAL provider, or plans it without one.
 *
 *   bun src/lechef/run/live.ts --sessions=<dir-or-file> --mode=plan
 *   bun src/lechef/run/live.ts --sessions=<dir-or-file> --mode=live [--run-id=<id>]
 *
 * - --sessions  a session script JSON file, or a directory whose *.json
 *               files (recursive) are session scripts — the same seam the
 *               offline harness CLI consumes
 * - --mode      plan (default): NO key needed, prints what a live run would
 *               do — arms, sessions, assistant slots, caps, price table,
 *               per-request estimate floor, and the exact live command.
 *               live: requires LECHEF_LIVE_API_KEY (env-only); refuses
 *               without it (exit 2). A key appearing later is never picked
 *               up automatically — going live is always this command.
 * - --run-id    live only: override the run directory name
 *               (default: live-<UTC timestamp>)
 *
 * Caps are RUN-WIDE: one CapLedger spans every arm and session, so
 * LECHEF_LIVE_MAX_SPEND_USD and LECHEF_LIVE_MAX_REQUESTS bound the whole
 * comparison (the stricter binds first). Every request is authorized
 * BEFORE it is sent; a request that would breach either cap is never sent,
 * and the run aborts cleanly with the cap state in summary.json.
 *
 * Per (arm, session) JSONL logs and per-session RunRecord JSON land under
 * the run directory; logs are evaluation artifacts and are never committed
 * (see backend/gemini-agent/README-live.md). Exit codes: 0 plan/complete,
 * 1 cap abort or no sessions, 2 configuration refusal.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { parseSessionScript, type SessionScript } from "../fakeModel.js";
import type { LeChefDesign } from "../designs/contract.js";
import { coachDesign } from "../designs/coach/design.js";
import { companionDesign } from "../designs/companion/design.js";
import { plannerDesign } from "../designs/planner/design.js";
import { CapLedger, parseLiveCaps } from "../live/caps.js";
import { readLiveConfig, LIVE_API_KEY_ENV } from "../live/config.js";
import { GeminiLiveTransport } from "../live/geminiTransport.js";
import { estimateRequestCost, tablePricesFor } from "../live/pricing.js";
import { SessionLog, writeJson, actualCostOf, type ArmSummary, type RunSummary } from "../live/logs.js";
import { CapAbortError, TransportError, runLiveSession } from "../live/liveSession.js";

interface CliArgs {
  readonly sessions: string;
  readonly mode: "plan" | "live";
  readonly runId?: string;
}

interface ArmSpec {
  readonly arm: string;
  readonly design: LeChefDesign;
}

const ARMS: readonly ArmSpec[] = [
  { arm: "coach", design: coachDesign },
  { arm: "companion", design: companionDesign },
  { arm: "planner", design: plannerDesign }
];

function parseArgs(argv: readonly string[]): CliArgs {
  let sessions: string | undefined;
  let mode: "plan" | "live" = "plan";
  let runId: string | undefined;
  for (const arg of argv) {
    const eq = arg.indexOf("=");
    const key = eq === -1 ? arg : arg.slice(0, eq);
    const value = eq === -1 ? undefined : arg.slice(eq + 1);
    switch (key) {
      case "--sessions":
        if (!value) throw new Error("--sessions needs a path");
        sessions = value;
        break;
      case "--mode":
        if (value !== "plan" && value !== "live") throw new Error(`--mode must be plan or live, got "${value}"`);
        mode = value;
        break;
      case "--run-id":
        if (!value) throw new Error("--run-id needs a value");
        runId = value;
        break;
      default:
        throw new Error(`unknown argument: ${key}`);
    }
  }
  if (!sessions) {
    throw new Error("usage: bun src/lechef/run/live.ts --sessions=<dir-or-file> [--mode=plan|live] [--run-id=<id>]");
  }
  return { sessions, mode, runId };
}

function listScriptFiles(path: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    if (entry.isDirectory()) files.push(...listScriptFiles(join(path, entry.name)));
    else if (entry.isFile() && entry.name.endsWith(".json")) files.push(join(path, entry.name));
  }
  return files;
}

/** Load and validate session scripts; unparsable files are skipped and counted. */
function loadScripts(path: string): { scripts: SessionScript[]; skipped: string[] } {
  const stat = statSync(path);
  const files = stat.isDirectory() ? listScriptFiles(path) : [path];
  const scripts: SessionScript[] = [];
  const skipped: string[] = [];
  for (const file of files) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      scripts.push(parseSessionScript(parsed));
    } catch (e) {
      skipped.push(`${file}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return { scripts, skipped };
}

/** Assistant slots are where the live model speaks — one request minimum each. */
function assistantSlots(script: SessionScript): number {
  return script.turns.filter((t) => t.role === "assistant").length;
}

function fail(message: string): never {
  console.error(message);
  process.exit(2);
}

// ---------------------------------------------------------------------------

function main(argv: readonly string[]): void {
  let args: CliArgs;
  try {
    args = parseArgs(argv);
  } catch (e) {
    fail(`live runner: ${e instanceof Error ? e.message : String(e)}`);
  }

  const env = process.env as Readonly<Record<string, string | undefined>>;

  if (args.mode === "plan") {
    runPlan(env, args);
    return;
  }
  runLive(env, args);
}

/** Plan mode: keyless, side-effect free. Prints what a live run would do. */
function runPlan(env: Readonly<Record<string, string | undefined>>, args: CliArgs): void {
  let caps;
  try {
    caps = parseLiveCaps(env);
  } catch (e) {
    fail(`live runner: ${e instanceof Error ? e.message : String(e)}`);
  }
  const model = env["LECHEF_LIVE_MODEL"] ?? "gemini-2.0-flash";
  const maxOutputTokens = env["LECHEF_LIVE_MAX_OUTPUT_TOKENS"] !== undefined ? Number(env["LECHEF_LIVE_MAX_OUTPUT_TOKENS"]) : 512;
  const { scripts, skipped } = loadScripts(args.sessions);

  console.log("LeChef live run plan (no key needed, nothing was sent)");
  console.log("======================================================");
  console.log(`sessions found: ${scripts.length}${skipped.length > 0 ? ` (${skipped.length} skipped — unparsable)` : ""}`);
  for (const s of skipped) console.log(`  skipped: ${s}`);
  console.log(`arms: ${ARMS.map((a) => `${a.arm} (${a.design.id})`).join(", ")}`);
  console.log(`sessions x arms: ${scripts.length * ARMS.length} sessions total`);
  for (const a of ARMS) {
    const slots = scripts.reduce((sum, s) => sum + assistantSlots(s), 0);
    console.log(`  ${a.arm}: ${scripts.length} sessions, ${slots} assistant slots (>= ${slots} requests, tool rounds add more)`);
  }
  console.log(`caps: LECHEF_LIVE_MAX_SPEND_USD=${caps.maxSpendUsd}, LECHEF_LIVE_MAX_REQUESTS=${caps.maxRequests} (whichever binds first; run-wide)`);
  const prices = tablePricesFor(model);
  if (prices === undefined) {
    console.log(`prices: no table price for model "${model}" — set LECHEF_LIVE_PRICE_IN_PER_MTOK and LECHEF_LIVE_PRICE_OUT_PER_MTOK before going live`);
  } else {
    const floor = estimateRequestCost({ systemChars: 0, contextChars: 0, maxOutputTokens: caps.maxRequests > 0 ? maxOutputTokens : 0, prices });
    console.log(`prices: ${model} at $${prices.inputUsdPerMTok}/MTok in, $${prices.outputUsdPerMTok}/MTok out`);
    console.log(
      `per-request estimate floor (input at zero context; real requests grow with the conversation): ` +
        `$${floor.estimatedCostUsd.toFixed(6)} = ${floor.estimatedInputTokens} in + ${floor.estimatedOutputTokens} out tokens`
    );
    console.log(`spend-cap bound at that floor: ~${caps.maxSpendUsd === 0 ? 0 : Math.floor(caps.maxSpendUsd / floor.estimatedCostUsd)} requests before LECHEF_LIVE_MAX_SPEND_USD binds`);
  }
  console.log("");
  console.log(`To go live (explicit; needs your key — see backend/gemini-agent/README-live.md):`);
  console.log(
    `  ${LIVE_API_KEY_ENV}=... LECHEF_LIVE_MAX_SPEND_USD=${caps.maxSpendUsd} LECHEF_LIVE_MAX_REQUESTS=${caps.maxRequests} ` +
      `bun src/lechef/run/live.ts --sessions=<dir-or-file> --mode=live`
  );
  console.log("Logs land under evaluation/lechef-live-runs/<runId>/ and are never committed.");
}

/** Live mode: key required, caps run-wide, logs per session. */
async function runLive(env: Readonly<Record<string, string | undefined>>, args: CliArgs): Promise<void> {
  const cfg = readLiveConfig(env);
  if ("reason" in cfg) fail(`live runner: refusing to start a live run — ${cfg.reason}`);

  const { scripts, skipped } = loadScripts(args.sessions);
  if (scripts.length === 0) {
    console.error("live runner: no parsable session scripts found — nothing to run");
    process.exit(1);
  }

  const runId = args.runId ?? `live-${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}Z`;
  const outDir = cfg.outDir;
  const ledger = new CapLedger(cfg.caps, cfg.prices);
  const transport = new GeminiLiveTransport({
    apiKey: cfg.apiKey,
    model: cfg.model,
    endpoint: cfg.endpoint,
    maxOutputTokens: cfg.maxOutputTokens
  });

  console.log(
    `live run ${runId}: model=${cfg.model} transport=gemini sessions=${scripts.length}x${ARMS.length} arms ` +
      `caps=$${cfg.caps.maxSpendUsd}/${cfg.caps.maxRequests} req outDir=${outDir}`
  );

  const armSummaries: ArmSummary[] = [];
  let capAbort: CapAbortError | undefined;
  let runExit = 0;

  for (const { arm, design } of ARMS) {
    if (capAbort !== undefined) {
      // Cap exhausted — remaining arms are not attempted at all.
      armSummaries.push({
        arm: design.id,
        design: design.title,
        model: cfg.model,
        transport: "gemini",
        sessions: { attempted: 0, completed: 0, aborted: 0 },
        requests: { sent: 0, maxAllowed: cfg.caps.maxRequests },
        usage: { estimatedCostUsd: 0, actualCostUsd: 0 },
        capState: "within",
        logsDir: join(outDir, runId),
        completedSessionIds: []
      });
      continue;
    }

    let completed = 0;
    let aborted = 0;
    let sent = 0;
    let spendDelta = 0;
    let tokensIn = 0;
    let tokensOut = 0;
    const completedIds: string[] = [];

    for (const script of scripts) {
      const log = new SessionLog(outDir, runId, arm, script.sessionId);
      const spendBefore = ledger.state().committedSpendUsd;
      const sentBefore = ledger.state().requestsSent;
      try {
        const outcome = await runLiveSession({
          source: { ...script, design: design.id },
          design,
          transport,
          ledger,
          log,
          maxOutputTokens: cfg.maxOutputTokens,
          maxToolRounds: cfg.maxToolRounds
        });
        completed += 1;
        completedIds.push(script.sessionId);
        sent += outcome.requestsSent;
        tokensIn += outcome.providerTokens.inputTokens;
        tokensOut += outcome.providerTokens.outputTokens;
        spendDelta += ledger.state().committedSpendUsd - spendBefore;
        writeJson(outDir, runId, `${arm}--${script.sessionId}.record.json`, outcome.record);
        console.log(
          `  [${arm}] ${script.sessionId}: ${outcome.requestsSent} req, ` +
            `$${(ledger.state().committedSpendUsd - spendBefore).toFixed(6)}, ${outcome.suppressed.length} suppressed`
        );
      } catch (e) {
        if (e instanceof CapAbortError) {
          // Run-wide ceiling bound mid-session — stop everything cleanly.
          aborted += 1;
          spendDelta += ledger.state().committedSpendUsd - spendBefore;
          sent += Math.max(0, e.capState.requestsSent - sentBefore);
          capAbort = e;
          break;
        }
        if (e instanceof TransportError) {
          // One failed exchange aborts that session; the run continues
          // (failures still charge their estimate, so a persistent outage
          // burns the cap and stops the run by itself).
          aborted += 1;
          console.error(`  [${arm}] ${script.sessionId}: transport failed — session aborted`);
          continue;
        }
        throw e;
      }
    }

    armSummaries.push({
      arm: design.id,
      design: design.title,
      model: cfg.model,
      transport: "gemini",
      sessions: { attempted: completed + aborted, completed, aborted },
      requests: { sent, maxAllowed: cfg.caps.maxRequests },
      usage: {
        estimatedCostUsd: spendDelta,
        actualCostUsd: actualCostOf({ inputTokens: tokensIn, outputTokens: tokensOut }, cfg.prices)
      },
      capState: capAbort !== undefined ? capAbort.breach : "within",
      capDetail: capAbort?.detail,
      logsDir: join(outDir, runId),
      completedSessionIds: completedIds
    });
  }

  const summary: RunSummary = {
    runId,
    model: cfg.model,
    arms: armSummaries,
    capState: capAbort !== undefined ? capAbort.breach : "within",
    capDetail: capAbort?.detail,
    logsDir: join(outDir, runId)
  };
  writeJson(outDir, runId, "summary.json", summary);

  console.log(`run ${runId} finished: capState=${summary.capState}${capAbort !== undefined ? ` — ${capAbort.detail}` : ""}`);
  console.log(`  logs+records: ${join(outDir, runId)} (summary.json, <arm>--<session>.jsonl, <arm>--<session>.record.json)`);
  console.log(`  ledger: ${ledger.state().requestsSent} requests sent, $${ledger.state().committedSpendUsd.toFixed(6)} committed of $${cfg.caps.maxSpendUsd}`);
  if (capAbort !== undefined) {
    console.error(`live run aborted cleanly at the cap: ${capAbort.detail}`);
    runExit = 1;
  }
  process.exit(runExit);
}

if (import.meta.main) {
  main(process.argv.slice(2));
}
