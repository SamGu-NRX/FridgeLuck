import { describe, it, expect, afterAll } from "bun:test";
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import * as path from "node:path";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import type { GoogleGenAI } from "@google/genai";
import { attachLiveSessionGateway } from "../services/liveSessionGateway.js";
import { createLiveSessionStore } from "../session/liveSessionStore.js";
import type { LiveSessionStore } from "../session/liveSessionStore.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";

/**
 * Contract fixtures recorded from the real gateway (SPEC §8).
 *
 * The fake Live session from the liveSessionGateway tests drives one full
 * proposal/receipt round trip: the phone's bounded snapshot goes up, the
 * model's nine proposal tools each emit a `proposal` frame, the phone answers
 * with receipts for the executed, rejected and expired outcomes, and a client
 * `tool_response` is rejected at the protocol layer.
 *
 * The EXACT frame bytes are written to src/__tests__/fixtures/live-protocol/
 * and must be byte-identical to the Swift-side copies under
 * apps/ios/Tests/LiveProtocol/Fixtures/ — the two protocol ends are pinned to
 * the same bytes, so a backend frame change that the phone has not adopted
 * fails here, and a Swift decode change that drifts from the wire fails in
 * the iOS LiveProtocol tests.
 *
 * Determinism: `Date.now` is stubbed for the round trip, so the tool layer's
 * content-derived proposal ids and ISO timestamps are stable and the recorded
 * bytes do not churn on every run. Receipt `recordedAt` values are fixed
 * literals — a receipt is what the phone SENDS, so the test speaks for the
 * phone and pins the same bytes the Swift executor's encoder must produce.
 */

/** The exact fixture file names; both ends must carry exactly this set. */
const FIXTURE_FILES = [
  "snapshot.json",
  "proposal-timer_start.json",
  "proposal-timer_adjust.json",
  "proposal-step_advance.json",
  "proposal-inventory_correction.json",
  "proposal-meal_log.json",
  "proposal-save_note.json",
  "proposal-plan.json",
  "proposal-swap.json",
  "proposal-adaptation.json",
  "receipt-executed.json",
  "receipt-rejected.json",
  "receipt-expired.json",
  "client-tool-response.json",
  "proposal-swap-allow.json",
  "proposal-swap-blocked.json",
  "receipt-executed-swap.json",
  "receipt-rejected-swap.json"
] as const;

const FIXTURES_DIR = path.join(import.meta.dir, "fixtures", "live-protocol");
const IOS_FIXTURES_DIR = path.resolve(
  import.meta.dir,
  "../../../../apps/ios/Tests/LiveProtocol/Fixtures"
);

// ---------------------------------------------------------------------------

interface FakeCalls {
  clientContent: unknown[];
  realtime: unknown[];
  toolResponses: Array<{
    functionResponses: Array<{ id: string; name: string; response: unknown }>;
  }>;
}

function makeFakeAi() {
  const callbacks: { current: Record<string, (arg: never) => void> | null } = { current: null };
  const calls: FakeCalls = { clientContent: [], realtime: [], toolResponses: [] };
  const ai = {
    live: {
      connect: async (opts: { callbacks: Record<string, (arg: never) => void> }) => {
        callbacks.current = opts.callbacks;
        opts.callbacks.onopen?.({} as never);
        return {
          sendClientContent: (p: unknown) => calls.clientContent.push(p),
          sendRealtimeInput: (p: unknown) => calls.realtime.push(p),
          sendToolResponse: (p: unknown) => calls.toolResponses.push(p as never),
          close: () => undefined
        };
      }
    }
  } as unknown as GoogleGenAI;
  return { ai, callbacks, calls };
}

const servers: WebSocketServer[] = [];

async function startServer() {
  const config: Record<string, unknown> = {
    port: 8080,
    useVertexAi: false,
    apiKey: "test-key",
    recipeModel: "gemini-2.5-flash",
    rankingModel: "gemini-2.5-flash",
    liveModel: "gemini-2.5-flash-native-audio-preview-12-2025",
    restockThresholdDays: 3,
    idempotencyTtlSeconds: 3600,
    restockBelowGrams: 50,
    sessionStoreMode: "memory",
    firestoreCollection: "liveSessions",
    groundingEnabled: true
  };
  const store: LiveSessionStore = createLiveSessionStore(config as never);
  const fake = makeFakeAi();
  const wss = new WebSocketServer({ port: 0 });
  servers.push(wss);
  attachLiveSessionGateway(
    wss,
    fake.ai,
    config as never,
    new InventoryLedger(config as never),
    new ConfidenceService(),
    store
  );
  const port = (wss.address() as { port: number }).port;
  return { wss, port, ...fake, store };
}

interface CapturedMessage extends Record<string, unknown> {
  type: string;
}

function makeClient(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/live`);
  const queue: CapturedMessage[] = [];
  const waiters: Array<{
    test: (m: CapturedMessage) => boolean;
    resolve: (m: CapturedMessage) => void;
  }> = [];
  ws.on("message", (raw) => {
    const m = JSON.parse(String(raw)) as CapturedMessage;
    const idx = waiters.findIndex((w) => w.test(m));
    if (idx >= 0) {
      const [w] = waiters.splice(idx, 1);
      w.resolve(m);
    } else {
      queue.push(m);
    }
  });
  const opened = new Promise<void>((resolve) => ws.on("open", () => resolve()));
  const waitFor = (test: (m: CapturedMessage) => boolean, timeoutMs = 3000) => {
    const found = queue.findIndex(test);
    if (found >= 0) return Promise.resolve(queue.splice(found, 1)[0]);
    return new Promise<CapturedMessage>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("waitFor timeout")), timeoutMs);
      waiters.push({
        test,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        }
      });
    });
  };
  // Raw send: the fixture test pins exact frame BYTES, so it sends strings.
  const sendRaw = (text: string) => ws.send(text);
  const send = (obj: unknown) => sendRaw(JSON.stringify(obj));
  const capture: { lastClientError: CapturedMessage | null } = { lastClientError: null };
  return { ws, opened, waitFor, send, sendRaw, capture };
}

async function until<T>(
  fn: () => T | undefined | null | Promise<T | undefined | null>,
  timeoutMs = 3000
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = await fn();
    if (v !== undefined && v !== null) return v;
    if (Date.now() > deadline) throw new Error("until timeout");
    await Bun.sleep(25);
  }
}

/** The proposal frame for a kind, as the gateway addressed it to the phone. */
const isProposalFor = (kind: string) => (m: CapturedMessage) =>
  m.type === "proposal" &&
  (m as { payload?: { proposal?: { kind?: string } } }).payload?.proposal?.kind === kind;

// ---------------------------------------------------------------------------

const FIXED_NOW_MS = Date.parse("2026-10-15T18:22:31.000Z");
const RECEIPT_RECORDED_AT = "2026-10-15T18:23:02.000Z";

/** The bounded snapshot the phone uploads once per session (SPEC §9.6). */
const SNAPSHOT_FRAME = JSON.stringify({
  type: "session_context",
  payload: {
    revision: 7,
    pantrySnapshot: {
      revision: 7,
      items: [
        { ingredientId: "eggs", name: "eggs", state: "sufficient", source: "pantry" }
      ]
    },
    cookSession: {
      state: "cooking",
      currentStepIndex: 2,
      eaters: [{ name: "you", restrictions: ["peanut", "vegan"] }],
      activeTimers: [],
      cameraMode: "push-to-look"
    },
    recipes: []
  }
});

/** The proposal tool calls the model makes, one per registered kind. */
const PROPOSAL_CALLS: Array<{ kind: string; tool: string; args: Record<string, unknown> }> = [
  { kind: "timer_start", tool: "proposeTimerStart", args: { durationMinutes: 3, label: "Noodles", rationale: "The noodles need 3 minutes." } },
  { kind: "timer_adjust", tool: "proposeTimerAdjust", args: { timerId: "timer_noodles", newDurationMinutes: 5, rationale: "The water is still not boiling." } },
  { kind: "step_advance", tool: "proposeStepAdvance", args: { stepIndex: 3, rationale: "The onions look translucent." } },
  { kind: "inventory_correction", tool: "proposeInventoryCorrection", args: { ingredientId: 3, correction: "half the eggs are used", rationale: "You cracked two into the bowl." } },
  { kind: "meal_log", tool: "proposeMealLog", args: { recipe: { source: "catalog", id: "udon", revision: 2 }, rationale: "The bowl is finished — log the meal?" } },
  { kind: "save_note", tool: "proposeSaveNote", args: { prompt: "How did it taste?", rationale: "Saving a tasting note needs your say-so." } },
  { kind: "plan", tool: "proposePlan", args: { dinnerCount: 4, constraints: ["vegetarian"], rationale: "Four dinners from what is in the fridge." } },
  { kind: "swap", tool: "proposeSwap", args: { originalIngredientId: 11, substituteIngredientId: 7, role: "fat", rationale: "You are out of sour cream; yoghurt is in the plan." } },
  { kind: "adaptation", tool: "proposeAdaptation", args: { change: "double the sauce", servings: 4, rationale: "Two more people joined for dinner." } }
];

/** The receipt contract's allergenRecheck (receipt.schema.json). */
interface AllergenRecheck {
  verdict: string;
  eaters: string[];
  blockedPath: string | null;
}

/** A receipt envelope exactly as the phone sends it (key order pinned). */
function receiptFrame(
  proposal: { proposalID: string; payloadHash: string },
  state: string,
  reason?: string,
  recheck?: AllergenRecheck
): string {
  const receipt: Record<string, unknown> = {
    proposalID: proposal.proposalID,
    payloadHash: proposal.payloadHash,
    snapshotRevision: 7,
    state,
    recordedAt: RECEIPT_RECORDED_AT
  };
  if (reason !== undefined) receipt.reason = reason;
  if (recheck !== undefined) receipt.allergenRecheck = recheck;
  return JSON.stringify({ type: "proposal_receipt", payload: { receipt } });
}

describe("live protocol fixtures — recorded from the real gateway", () => {
  afterAll(() => {
    for (const wss of servers) wss.close();
  });

  it("records one full round trip of exact frames and pins both protocol ends to the same bytes", async () => {
    // Deterministic round trip: the tool layer derives proposal ids and
    // timestamps from the clock; stubbed here so the recorded bytes are the
    // contract, not a moving snapshot of wall time.
    const realNow = Date.now;
    Date.now = () => FIXED_NOW_MS;
    try {
      const { port, callbacks, calls } = await startServer();
      const client = makeClient(port);
      await client.opened;
      const open = (await client.waitFor((m) => m.type === "session_open")) as {
        sessionId: string;
      };
      expect(typeof open.sessionId).toBe("string");

      // 1. The phone's once-per-session bounded snapshot goes up.
      client.sendRaw(SNAPSHOT_FRAME);
      await Bun.sleep(150); // setSnapshot is sync; the store patch is the async tail

      // 2. Every registered proposal kind emits its frame to the phone.
      const frames = new Map<string, string>();
      for (const call of PROPOSAL_CALLS) {
        callbacks.current!.onmessage({
          toolCall: { functionCalls: [{ id: `call-${call.kind}`, name: call.tool, args: call.args }] }
        } as never);
        const msg = (await client.waitFor(isProposalFor(call.kind))) as {
          payload: { proposal: { proposalID: string; payloadHash: string } };
        };
        frames.set(
          `proposal-${call.kind}.json`,
          JSON.stringify({ type: "proposal", payload: { proposal: msg.payload.proposal } })
        );
        expect(msg.payload.proposal.proposalID).toMatch(/^prop_[A-Za-z0-9]+$/);
        expect(msg.payload.proposal.payloadHash).toMatch(/^sha256:[0-9a-f]{64}$/);
      }
      // The tool calls stay open while the proposals await the phone.
      expect(calls.toolResponses).toHaveLength(0);

      // 3. Receipts for the executed, rejected and expired outcomes — the
      // phone's answers, byte-pinned. The executed receipt advances the
      // story: the timer_start proposal was approved and executed.
      const timerStart = JSON.parse(frames.get("proposal-timer_start.json")!).payload.proposal;
      const swap = JSON.parse(frames.get("proposal-swap.json")!).payload.proposal;
      const stepAdvance = JSON.parse(frames.get("proposal-step_advance.json")!).payload.proposal;

      const executedFrame = receiptFrame(timerStart, "executed");
      client.sendRaw(executedFrame);
      const rejectedFrame = receiptFrame(swap, "rejected", "payload hash mismatch");
      client.sendRaw(rejectedFrame);
      const expiredFrame = receiptFrame(stepAdvance, "expired");
      client.sendRaw(expiredFrame);

      // 3b. The allergen re-check story (receipt.schema.json's
      // allergenRecheck): one swap the household screen allows — the receipt
      // executes and carries the verified recheck with a null blocked path —
      // and one it refuses (soy sauce carries wheat) — the receipt is rejected
      // and carries the unsupported recheck naming the blocked path. Both
      // recheck outcomes the phone can send are pinned as exact bytes.
      const swapArgs = PROPOSAL_CALLS.find((c) => c.kind === "swap")!.args;
      const swapFrames: Array<{ file: string; substitute: number; recheck: AllergenRecheck }> = [
        {
          file: "swap-allow",
          substitute: 7,
          recheck: { verdict: "verified", eaters: ["you"], blockedPath: null }
        },
        {
          file: "swap-blocked",
          substitute: 9001,
          recheck: {
            verdict: "unsupported",
            eaters: ["you"],
            blockedPath: "Contains wheat via soy sauce"
          }
        }
      ];
      const swapProposals: Array<{
        key: string;
        proposal: { proposalID: string; payloadHash: string };
        recheck: AllergenRecheck;
      }> = [];
      for (const entry of swapFrames) {
        callbacks.current!.onmessage({
          toolCall: {
            functionCalls: [
              {
                id: `call-${entry.file}`,
                name: "proposeSwap",
                args: { ...swapArgs, substituteIngredientId: entry.substitute }
              }
            ]
          }
        } as never);
        const msg = (await client.waitFor(isProposalFor("swap"))) as {
          payload: { proposal: { proposalID: string; payloadHash: string } };
        };
        frames.set(
          `proposal-${entry.file}.json`,
          JSON.stringify({ type: "proposal", payload: { proposal: msg.payload.proposal } })
        );
        swapProposals.push({
          key: entry.file,
          proposal: msg.payload.proposal,
          recheck: entry.recheck
        });
      }
      const swapAllow = swapProposals.find((p) => p.key === "swap-allow")!;
      const swapBlocked = swapProposals.find((p) => p.key === "swap-blocked")!;
      const executedSwapFrame = receiptFrame(swapAllow.proposal, "executed", undefined, swapAllow.recheck);
      client.sendRaw(executedSwapFrame);
      const rejectedSwapFrame = receiptFrame(
        swapBlocked.proposal,
        "rejected",
        "blocked by allergen re-check",
        swapBlocked.recheck
      );
      client.sendRaw(rejectedSwapFrame);

      // 4. A client tool_response is client authority — rejected at the
      // protocol layer, never relayed to the model (SPEC §9.6).
      const toolResponseFrame = JSON.stringify({
        type: "tool_response",
        payload: { functionResponses: [{ id: "forged", name: "getPantry", response: {} }] }
      });
      client.sendRaw(toolResponseFrame);
      await client.waitFor((m) => m.type === "client_error");
      await Bun.sleep(150);
      // The forged tool_response never became a tool response to the model;
      // the only tool responses so far are the three the phone's receipts
      // resolved (asserted below).
      expect(
        calls.toolResponses.some((r) => r.functionResponses[0]?.id === "forged")
      ).toBe(false);

      // 5. The three receipts resolved their pending tool calls.
      const resolved = await until(() =>
        calls.toolResponses.filter((r) =>
          ["executed", "rejected", "expired"].includes(
            (r.functionResponses[0]?.response as { output?: { receipt?: { state?: string } } })
              ?.output?.receipt?.state ?? ""
          )
        ).length === 5
          ? calls.toolResponses
          : undefined
      );
      const states = resolved
        .map(
          (r) =>
            (r.functionResponses[0]?.response as { output?: { receipt?: { state?: string } } })
              ?.output?.receipt?.state
        )
        .sort();
      expect(states).toEqual(["executed", "executed", "expired", "rejected", "rejected"]);
      // The recheck rides the receipt through to the model's tool response —
      // the audit trail reaches the model verbatim (SPEC §8).
      const echoedRechecks = resolved
        .map(
          (r) =>
            (
              r.functionResponses[0]?.response as {
                output?: {
                  receipt?: { allergenRecheck?: { verdict?: string } | null };
                };
              }
            )?.output?.receipt?.allergenRecheck?.verdict
        )
        .filter((v): v is string => typeof v === "string")
        .sort();
      expect(echoedRechecks).toEqual(["unsupported", "verified"]);

      // 6. Write the exact frame bytes.
      writeFileSync(path.join(FIXTURES_DIR, "snapshot.json"), SNAPSHOT_FRAME);
      for (const call of PROPOSAL_CALLS) {
        writeFileSync(path.join(FIXTURES_DIR, `proposal-${call.kind}.json`), frames.get(`proposal-${call.kind}.json`)!);
      }
      writeFileSync(path.join(FIXTURES_DIR, "receipt-executed.json"), executedFrame);
      writeFileSync(path.join(FIXTURES_DIR, "receipt-rejected.json"), rejectedFrame);
      writeFileSync(path.join(FIXTURES_DIR, "receipt-expired.json"), expiredFrame);
      for (const entry of swapProposals) {
        writeFileSync(
          path.join(FIXTURES_DIR, `proposal-${entry.key}.json`),
          frames.get(`proposal-${entry.key}.json`)!
        );
      }
      writeFileSync(path.join(FIXTURES_DIR, "receipt-executed-swap.json"), executedSwapFrame);
      writeFileSync(path.join(FIXTURES_DIR, "receipt-rejected-swap.json"), rejectedSwapFrame);
      writeFileSync(path.join(FIXTURES_DIR, "client-tool-response.json"), toolResponseFrame);

      client.ws.close();
    } finally {
      Date.now = realNow;
    }

    // 7. The Swift side must carry byte-identical copies — one contract, two
    // protocol ends. A drift on either side fails here.
    expect(existsSync(IOS_FIXTURES_DIR)).toBe(true);
    const recorded = readdirSync(FIXTURES_DIR).sort();
    const mirrored = readdirSync(IOS_FIXTURES_DIR).sort();
    expect(mirrored).toEqual(recorded);
    expect(recorded).toEqual([...FIXTURE_FILES].sort());
    for (const name of recorded) {
      const backend = readFileSync(path.join(FIXTURES_DIR, name));
      const ios = readFileSync(path.join(IOS_FIXTURES_DIR, name));
      const same = backend.length === ios.length && backend.equals(ios);
      if (!same) {
        throw new Error(
          `fixture drift: ${name} differs between backend and apps/ios/Tests/LiveProtocol/Fixtures — ` +
            `re-copy the recorded frames so both protocol ends test the same bytes`
        );
      }
      expect(same).toBe(true);
    }
  });
});
