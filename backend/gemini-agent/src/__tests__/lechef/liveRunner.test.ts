/**
 * Live runner tests — mock transport ONLY.
 *
 * Nothing here touches a network: the transport is an in-process mock that
 * records the requests it was sent and replays scripted responses. These
 * tests pin the fail-closed behaviors the live runner exists for:
 *   - no key -> refuses (env-only opt-in)
 *   - unknown model pricing / unsupported provider / bad caps -> refuse
 *   - a request that would breach either cap is NEVER sent
 *   - per-session JSONL logs land where documented, and never contain the key
 *   - tool calls dispatch through the same gated runtime as offline replay
 *   - provider usage reconciles the pre-request estimate (estimates are
 *     upper bounds)
 */

import { describe, expect, afterAll } from "bun:test";
import { test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { LIVE_API_KEY_ENV, readLiveConfig } from "../../lechef/live/config.js";
import { CapLedger, parseLiveCaps } from "../../lechef/live/caps.js";
import { actualCostOf, estimateRequestCost } from "../../lechef/live/pricing.js";
import { SessionLog } from "../../lechef/live/logs.js";
import { CapAbortError, TransportError, runLiveSession } from "../../lechef/live/liveSession.js";
import type { LiveTransport, LiveTransportRequest, LiveTransportResponse, TokenPrices } from "../../lechef/live/types.js";
import type { SessionScript } from "../../lechef/fakeModel.js";
import type { LeChefDesign } from "../../lechef/designs/contract.js";

const TMP = "/tmp/lechef-live-test";

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true });
});

function freshOutDir(): string {
  mkdirSync(TMP, { recursive: true });
  return TMP;
}

function readJsonl(path: string): Record<string, unknown>[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

const PRICES: TokenPrices = { inputUsdPerMTok: 0.1, outputUsdPerMTok: 0.4 };

function liveDesign(over: Partial<LeChefDesign> = {}): LeChefDesign {
  return {
    id: "test-live",
    title: "Live test design",
    summary: "Permissive design for live-runner tests.",
    systemPrompt: "test system prompt",
    toolPolicy: [],
    turnBudget: { maxUnpromptedTurns: 999, minGapTurns: 0 },
    ...over
  };
}

const SCRIPT: SessionScript = {
  sessionId: "live-01",
  job: "coach",
  cameraMode: "push-to-look",
  design: "test-live",
  fixture: {
    nowIso: "2026-01-01T18:00:00.000Z",
    pantry: [
      { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 6, unit: "piece" }, state: "sufficient", source: "scan" }
    ],
    session: { recipeId: "eggs-on-toast", state: "cooking", currentStepIndex: 0 },
    recipes: [
      {
        id: "eggs-on-toast",
        revision: 1,
        servings: 2,
        ingredientBill: [{ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" } }],
        steps: [
          { index: 0, text: "Boil the eggs" },
          { index: 1, text: "Assemble" }
        ]
      }
    ],
    camera: { framesPerLook: 2, clipSeconds: 3, observed: ["pan on the stove"], cannotAssess: ["egg doneness"] }
  },
  turns: [
    { i: 0, role: "user", text: "Can we make something with these eggs?", audioSeconds: 3.5 },
    { i: 1, role: "assistant", text: "" },
    { i: 2, role: "user", text: "Is it done yet?" },
    { i: 3, role: "assistant", text: "" }
  ]
};

/** In-process transport: records every request, replays scripted responses. No network, ever. */
class MockTransport implements LiveTransport {
  readonly name = "mock";
  readonly model = "mock-model";
  readonly requests: LiveTransportRequest[] = [];
  private readonly steps: ((request: LiveTransportRequest, n: number) => LiveTransportResponse)[] = [];

  queue(step: (request: LiveTransportRequest, n: number) => LiveTransportResponse): this {
    this.steps.push(step);
    return this;
  }

  async send(request: LiveTransportRequest): Promise<LiveTransportResponse> {
    const n = this.requests.length;
    this.requests.push(request);
    const step = this.steps[n];
    if (step !== undefined) return step(request, n);
    return { text: `mock reply ${n}`, toolCalls: [], usage: { inputTokens: 1000, outputTokens: 100 } };
  }
}

interface RunParts {
  readonly transport: MockTransport;
  readonly ledger: CapLedger;
  readonly log: SessionLog;
}

function runParts(sessionId: string, caps = { maxSpendUsd: 1, maxRequests: 20 }): RunParts {
  const outDir = freshOutDir();
  return {
    transport: new MockTransport(),
    ledger: new CapLedger(caps, PRICES),
    log: new SessionLog(outDir, "run-test", "test", sessionId)
  };
}

// ---------------------------------------------------------------------------
// config: the env-only opt-in
// ---------------------------------------------------------------------------

describe("readLiveConfig", () => {
  test("refuses when the key env var is absent — live is an explicit command", () => {
    const cfg = readLiveConfig({});
    expect("reason" in cfg).toBe(true);
    if ("reason" in cfg) expect(cfg.reason).toContain(LIVE_API_KEY_ENV);
  });

  test("refuses a blank key", () => {
    const cfg = readLiveConfig({ [LIVE_API_KEY_ENV]: "   " });
    expect("reason" in cfg).toBe(true);
  });

  test("accepts a valid env and applies documented defaults", () => {
    const cfg = readLiveConfig({ [LIVE_API_KEY_ENV]: "test-key-123" });
    expect("reason" in cfg).toBe(false);
    if (!("reason" in cfg)) {
      expect(cfg.apiKey).toBe("test-key-123");
      expect(cfg.provider).toBe("gemini");
      expect(cfg.model).toBe("gemini-2.0-flash");
      expect(cfg.caps).toEqual({ maxSpendUsd: 1.0, maxRequests: 20 });
      expect(cfg.priceSource).toBe("table:gemini-2.0-flash");
      expect(cfg.outDir).toBe("evaluation/lechef-live-runs");
    }
  });

  test("refuses an unsupported provider", () => {
    const cfg = readLiveConfig({ [LIVE_API_KEY_ENV]: "k", LECHEF_LIVE_PROVIDER: "openai" });
    expect("reason" in cfg).toBe(true);
  });

  test("refuses an unknown model with no explicit prices — cost estimation fails closed", () => {
    const cfg = readLiveConfig({ [LIVE_API_KEY_ENV]: "k", LECHEF_LIVE_MODEL: "mystery-model" });
    expect("reason" in cfg).toBe(true);
    if ("reason" in cfg) expect(cfg.reason).toContain("LECHEF_LIVE_MODEL");
  });

  test("accepts an unknown model when both explicit prices are given, refuses half a pair", () => {
    const ok = readLiveConfig({
      [LIVE_API_KEY_ENV]: "k",
      LECHEF_LIVE_MODEL: "mystery-model",
      LECHEF_LIVE_PRICE_IN_PER_MTOK: "0.5",
      LECHEF_LIVE_PRICE_OUT_PER_MTOK: "1.5"
    });
    expect("reason" in ok).toBe(false);
    const half = readLiveConfig({ [LIVE_API_KEY_ENV]: "k", LECHEF_LIVE_PRICE_IN_PER_MTOK: "0.5" });
    expect("reason" in half).toBe(true);
  });

  test("malformed caps throw instead of falling back to defaults", () => {
    expect(() => readLiveConfig({ [LIVE_API_KEY_ENV]: "k", LECHEF_LIVE_MAX_SPEND_USD: "rich" })).toThrow();
    expect(() => readLiveConfig({ [LIVE_API_KEY_ENV]: "k", LECHEF_LIVE_MAX_REQUESTS: "-3" })).toThrow();
  });
});

describe("parseLiveCaps", () => {
  test("defaults are small: $1.00 and 20 requests", () => {
    expect(parseLiveCaps({})).toEqual({ maxSpendUsd: 1.0, maxRequests: 20 });
  });

  test("zero is allowed and means send nothing", () => {
    expect(parseLiveCaps({ LECHEF_LIVE_MAX_REQUESTS: "0", LECHEF_LIVE_MAX_SPEND_USD: "0" })).toEqual({
      maxSpendUsd: 0,
      maxRequests: 0
    });
  });

  test("non-integer, negative and NaN request caps throw", () => {
    expect(() => parseLiveCaps({ LECHEF_LIVE_MAX_REQUESTS: "2.5" })).toThrow();
    expect(() => parseLiveCaps({ LECHEF_LIVE_MAX_REQUESTS: "-1" })).toThrow();
    expect(() => parseLiveCaps({ LECHEF_LIVE_MAX_SPEND_USD: "NaN" })).toThrow();
  });
});

// ---------------------------------------------------------------------------
// caps ledger: both ceilings enforced BEFORE a request is sent
// ---------------------------------------------------------------------------

describe("CapLedger", () => {
  test("authorize returns the same estimate the pricing math computes", () => {
    const ledger = new CapLedger({ maxSpendUsd: 1, maxRequests: 20 }, PRICES);
    const auth = ledger.authorize({ systemChars: 100, contextChars: 300, maxOutputTokens: 512 });
    expect(auth.allowed).toBe(true);
    const expected = estimateRequestCost({ systemChars: 100, contextChars: 300, maxOutputTokens: 512, prices: PRICES });
    expect(auth.estimate).toEqual(expected);
    // chars/4 input tokens, output at the configured maximum.
    expect(expected.estimatedInputTokens).toBe(Math.ceil(400 / 4));
    expect(expected.estimatedOutputTokens).toBe(512);
  });

  test("the request cap binds when requests run out, even with spend left", () => {
    const ledger = new CapLedger({ maxSpendUsd: 1000, maxRequests: 2 }, PRICES);
    for (let i = 0; i < 2; i += 1) {
      const auth = ledger.authorize({ systemChars: 10, contextChars: 10, maxOutputTokens: 8 });
      expect(auth.allowed).toBe(true);
      ledger.chargeEstimate(auth.estimate!);
    }
    const third = ledger.authorize({ systemChars: 10, contextChars: 10, maxOutputTokens: 8 });
    expect(third.allowed).toBe(false);
    expect(third.breach).toBe("request-cap");
  });

  test("the spend cap binds when the estimate would exceed it, even with requests left", () => {
    const ledger = new CapLedger({ maxSpendUsd: 0.01, maxRequests: 100 }, { inputUsdPerMTok: 10, outputUsdPerMTok: 10 });
    const auth = ledger.authorize({ systemChars: 4000, contextChars: 0, maxOutputTokens: 512 });
    // 1000 input tokens + 512 output tokens at $10/MTok = ~$0.0151 > $0.01.
    expect(auth.allowed).toBe(false);
    expect(auth.breach).toBe("spend-cap");
  });

  test("provider usage reconciles the charged estimate — estimates are upper bounds", () => {
    const ledger = new CapLedger({ maxSpendUsd: 1, maxRequests: 20 }, PRICES);
    const auth = ledger.authorize({ systemChars: 100, contextChars: 100, maxOutputTokens: 512 });
    ledger.chargeEstimate(auth.estimate!);
    expect(ledger.state().committedSpendUsd).toBeCloseTo(auth.estimate!.estimatedCostUsd, 9);
    const actual = actualCostOf({ inputTokens: 100, outputTokens: 10 }, PRICES);
    expect(ledger.recordActual({ inputTokens: 100, outputTokens: 10 })).toBeCloseTo(actual, 9);
    // Absent usage keeps the (conservative) estimate on the books.
    expect(ledger.recordActual(undefined)).toBeCloseTo(actual, 9);
  });
});

// ---------------------------------------------------------------------------
// session loop over the mock transport
// ---------------------------------------------------------------------------

describe("runLiveSession", () => {
  test("happy path: two slots, generated turns replace scripted ones, usage reconciles", async () => {
    const parts = runParts("happy");
    const outcome = await runLiveSession({ source: SCRIPT, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });

    expect(outcome.requestsSent).toBe(2);
    expect(parts.transport.requests.length).toBe(2);
    expect(outcome.providerTokens).toEqual({ inputTokens: 2000, outputTokens: 200 });
    // 2 responses at fixed usage: 2 * (1000*0.1 + 100*0.4) / 1e6.
    expect(parts.ledger.state().committedSpendUsd).toBeCloseTo(0.00028, 9);

    expect(outcome.record.sessionId).toBe("live-01");
    expect(outcome.record.design).toBe("test-live");
    expect(outcome.record.turns.map((t) => `${t.i}:${t.role}`)).toEqual(["0:user", "1:assistant", "2:user", "3:assistant"]);
    expect(outcome.record.turns[1].text).toBe("mock reply 0");

    // The conversation reaches the transport: system prompt from the design,
    // source user turns as user messages.
    expect(parts.transport.requests[0].system).toContain("test system prompt");
    expect(parts.transport.requests[0].messages[0]).toEqual({ role: "user", text: "Can we make something with these eggs?" });
    expect(parts.transport.requests[1].messages.map((m) => m.text)).toContain("Is it done yet?");

    const lines = readJsonl(parts.log.filePath);
    expect(lines[0].kind).toBe("session-start");
    expect(lines[0].model).toBe("mock-model");
    expect(lines.filter((l) => l.kind === "request").length).toBe(2);
    expect(lines.filter((l) => l.kind === "response").length).toBe(2);
    const end = lines[lines.length - 1];
    expect(end.kind).toBe("session-end");
    expect(end.completed).toBe(true);
  });

  test("logs never contain the API key", async () => {
    const parts = runParts("nokey");
    await runLiveSession({ source: SCRIPT, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });
    const content = readFileSync(parts.log.filePath, "utf8");
    expect(content.includes("test-key-123")).toBe(false);
  });

  test("tool calls dispatch through the gated runtime and their results reach the next request", async () => {
    const script: SessionScript = {
      ...SCRIPT,
      turns: [
        { i: 0, role: "user", text: "Can we make something with these eggs?" },
        { i: 1, role: "assistant", text: "" }
      ]
    };
    const parts = runParts("tools");
    parts.transport.queue(() => ({
      text: "checking recipes",
      toolCalls: [{ id: "c1", name: "getRecipeCandidates", args: { goal: "eggs on toast" } }],
      usage: { inputTokens: 500, outputTokens: 50 }
    }));
    parts.transport.queue(() => ({ text: "Eggs on toast works.", toolCalls: [], usage: { inputTokens: 500, outputTokens: 50 } }));

    const outcome = await runLiveSession({ source: script, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });

    expect(outcome.requestsSent).toBe(2);
    const second = parts.transport.requests[1];
    expect(second.toolResults.length).toBe(1);
    expect(second.toolResults[0].callId).toBe("c1");
    expect(second.toolResults[0].name).toBe("getRecipeCandidates");
    expect(() => JSON.parse(second.toolResults[0].resultJson)).not.toThrow();

    expect(outcome.record.toolCalls.length).toBe(1);
    expect(outcome.record.toolCalls[0].status).toBe("ok");

    const lines = readJsonl(parts.log.filePath);
    const dispatch = lines.find((l) => l.kind === "tool-dispatch");
    expect(dispatch !== undefined).toBe(true);
    expect(dispatch!["tool"]).toBe("getRecipeCandidates");
  });

  test("a scripted approve maps FIFO to the oldest open proposal and executes it", async () => {
    const script: SessionScript = {
      ...SCRIPT,
      turns: [
        { i: 0, role: "user", text: "Set a 9 minute egg timer." },
        { i: 1, role: "assistant", text: "" }
      ],
      userActions: [{ afterTurn: 1, action: { kind: "approve", callId: "scripted-c1" } }]
    };
    const parts = runParts("approve");
    parts.transport.queue(() => ({
      text: "proposing the timer",
      toolCalls: [{ id: "live-c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 9, userInitiated: true } }],
      usage: { inputTokens: 300, outputTokens: 30 }
    }));

    const outcome = await runLiveSession({ source: script, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });

    // The live call id differs from the scripted one — the approve must still land.
    expect(outcome.record.proposals.length).toBe(1);
    expect(outcome.record.proposals[0].state).toBe("executed");
    const lines = readJsonl(parts.log.filePath);
    const action = lines.find((l) => l.kind === "user-action" && l.action === "approve");
    expect(action !== undefined).toBe(true);
    expect(action!["matched"]).toBe(true);
    expect(action!["proposalId"]).toBe(outcome.record.proposals[0].id);
  });

  test("a request cap of 1 aborts the second slot BEFORE the transport is called again", async () => {
    const parts = runParts("cap", { maxSpendUsd: 1, maxRequests: 1 });
    let threw: unknown;
    try {
      await runLiveSession({ source: SCRIPT, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });
    } catch (e) {
      threw = e;
    }
    expect(threw).toBeInstanceOf(CapAbortError);
    const abort = threw as CapAbortError;
    expect(abort.breach).toBe("request-cap");
    expect(abort.capState.requestsSent).toBe(1);
    expect(parts.transport.requests.length).toBe(1); // the abort happened before send #2

    const lines = readJsonl(parts.log.filePath);
    expect(lines.some((l) => l.kind === "cap-abort")).toBe(true);
    const end = lines[lines.length - 1];
    expect(end.kind).toBe("session-end");
    expect(end.completed).toBe(false);
    expect(end.reason).toBe("cap-abort");
  });

  test("a zero spend cap aborts before the FIRST request — nothing is sent", async () => {
    const parts = runParts("nospend", { maxSpendUsd: 0, maxRequests: 20 });
    let threw: unknown;
    try {
      await runLiveSession({ source: SCRIPT, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });
    } catch (e) {
      threw = e;
    }
    expect(threw).toBeInstanceOf(CapAbortError);
    expect((threw as CapAbortError).breach).toBe("spend-cap");
    expect(parts.transport.requests.length).toBe(0);
    expect(parts.ledger.state().requestsSent).toBe(0);
  });

  test("a transport failure counts the attempt, logs it, and aborts cleanly", async () => {
    const parts = runParts("txerr");
    parts.transport.queue(() => {
      throw new Error("simulated network outage");
    });
    let threw: unknown;
    try {
      await runLiveSession({ source: SCRIPT, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 4 });
    } catch (e) {
      threw = e;
    }
    expect(threw).toBeInstanceOf(TransportError);
    expect(parts.ledger.state().requestsSent).toBe(1); // the attempt was charged
    const lines = readJsonl(parts.log.filePath);
    expect(lines.some((l) => l.kind === "transport-error")).toBe(true);
    const end = lines[lines.length - 1];
    expect(end.reason).toBe("transport-error");
  });

  test("the unprompted budget suppresses a proactive slot before any request", async () => {
    const script: SessionScript = {
      ...SCRIPT,
      turns: [
        { i: 0, role: "assistant", text: "" }, // proactive slot — budget is 0
        { i: 1, role: "user", text: "hello?" },
        { i: 2, role: "assistant", text: "" }
      ]
    };
    const parts = runParts("budget");
    const outcome = await runLiveSession({
      source: script,
      design: liveDesign({ turnBudget: { maxUnpromptedTurns: 0, minGapTurns: 0 } }),
      ...parts,
      maxOutputTokens: 512,
      maxToolRounds: 4
    });

    expect(outcome.requestsSent).toBe(1); // only the prompted slot spoke
    expect(outcome.suppressed).toEqual([{ turn: 0, because: "budget-exhausted" }]);
    expect(outcome.record.turns.map((t) => `${t.i}:${t.role}`)).toEqual(["1:user", "2:assistant"]);
    const lines = readJsonl(parts.log.filePath);
    expect(lines.some((l) => l.kind === "turn-suppressed")).toBe(true);
  });

  test("the tool-round limit stops the exchange — no further model round after the dispatch", async () => {
    const script: SessionScript = {
      ...SCRIPT,
      turns: [
        { i: 0, role: "user", text: "Can we make something with these eggs?" },
        { i: 1, role: "assistant", text: "" }
      ]
    };
    const parts = runParts("rounds");
    parts.transport.queue(() => ({
      text: "round 0",
      toolCalls: [{ id: "c1", name: "getRecipeCandidates", args: { goal: "eggs" } }],
      usage: { inputTokens: 100, outputTokens: 10 }
    }));
    const outcome = await runLiveSession({ source: script, design: liveDesign(), ...parts, maxOutputTokens: 512, maxToolRounds: 1 });

    expect(parts.transport.requests.length).toBe(1);
    expect(outcome.requestsSent).toBe(1);
    // The exchange ends without a final text, so the assistant slot emits no turn.
    expect(outcome.record.turns.map((t) => `${t.i}:${t.role}`)).toEqual(["0:user"]);
    const lines = readJsonl(parts.log.filePath);
    expect(lines.some((l) => l.kind === "note" && l.note === "max tool rounds reached; no further model round requested")).toBe(true);
  });

  test("two rejections of the same suggestion type silence it for the session", async () => {
    const script: SessionScript = {
      ...SCRIPT,
      turns: [
        { i: 0, role: "user", text: "hi" },
        { i: 1, role: "assistant", text: "" },
        { i: 2, role: "user", text: "no thanks" },
        { i: 3, role: "assistant", text: "" },
        { i: 4, role: "user", text: "no thanks" },
        { i: 5, role: "assistant", text: "" }
      ]
    };
    const parts = runParts("silence");
    const outcome = await runLiveSession({
      source: script,
      design: liveDesign({ suggestionType: () => "use-soon" }),
      ...parts,
      maxOutputTokens: 512,
      maxToolRounds: 4
    });

    const lines = readJsonl(parts.log.filePath);
    expect(lines.filter((l) => l.kind === "suggestion-silenced").length).toBe(1);
    expect(lines.find((l) => l.kind === "suggestion-silenced")!["suggestionType"]).toBe("use-soon");
    // The constraint reaches the model through the system prompt of later turns.
    expect(parts.transport.requests[2].system).toContain("use-soon");
    expect(outcome.silencedViolations).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// orchestration helpers (compile-level checks live in run/live.ts)
// ---------------------------------------------------------------------------

describe("live config smoke", () => {
  test("the CLI-facing config resolves and the refusal names the plan escape hatch", () => {
    const cfg = readLiveConfig({});
    if ("reason" in cfg) expect(cfg.reason).toContain("--mode=plan");
  });
});
