/**
 * LeChef end-to-end boot: the phone and the gateway meet over a real
 * WebSocket with the scripted fake model in Gemini's place.
 *
 * What runs here is the PRODUCTION surface end to end:
 * - backend: createAgentServer (server.ts's routes + attachLiveSessionGateway)
 *   with an in-memory session store and a scripted fake live session
 *   (src/lechef/suite/scripts.ts vocabulary) answering the real gateway's
 *   dispatch — no API key, no paid calls, no network beyond localhost.
 * - phone: apps/ios/Tools/lechef-e2e (the Swift walk) — pinned copies of the
 *   real GeminiLiveSessionClient, proposal coordinator, wire codec, and the
 *   proposal executor driving a walk kitchen — run as a child process.
 *
 * The boot asserts the gateway side of the script (script.ts); the walk
 * asserts the phone side (executor state, cards, refusal paths). Either side
 * failing fails the run.
 */

import { spawn } from "node:child_process";
import type { GoogleGenAI } from "@google/genai";
import { createAgentServer } from "../../agentServer.js";
import { ConfidenceService } from "../../services/confidenceService.js";
import { InMemoryFrameHolder } from "../../services/frameCache.js";
import { InventoryLedger } from "../../inventory/inventoryLedger.js";
import {
  createLiveSessionStore,
  type LiveSessionStore,
  type StoredCameraFrameMetadata,
} from "../../session/liveSessionStore.js";
import { boundedSnapshotPayload, cookSessionTurns, TURN_STALE_STEP, TURN_SWAP, TURN_TIMER } from "./script.js";

/** The walk sends a client-supplied id in the query string; the gateway must mint its own. */
const CLIENT_FORGED_ID = "burst9-e2e-client-id";

interface CheckResult {
  readonly name: string;
  readonly ok: boolean;
  readonly detail: string;
}

const results: CheckResult[] = [];
function step(name: string, ok: boolean, detail = ""): void {
  results.push({ name, ok, detail });
  console.log(`boot: [${ok ? "PASS" : "FAIL"}] ${name}${detail ? ` — ${detail}` : ""}`);
}
function fail(why: string): void {
  step("scripted session consistency", false, why);
}

/**
 * The user text a client_content payload carries: either a bare string or the
 * Gemini Content[] form ({role, parts:[{text}]}). The production client sends
 * Content[] (the real SDK session API); the fake parses it directly.
 */
function clientContentText(turns: unknown): string {
  if (typeof turns === "string") return turns;
  if (!Array.isArray(turns)) return "";
  const pieces: string[] = [];
  for (const content of turns) {
    if (typeof content === "string") {
      pieces.push(content);
      continue;
    }
    const parts = (content as { parts?: unknown })?.parts;
    if (Array.isArray(parts)) {
      for (const part of parts) {
        const text = (part as { text?: unknown })?.text;
        if (typeof text === "string") pieces.push(text);
      }
    }
  }
  return pieces.join(" ");
}

// ---------------------------------------------------------------------------
// The scripted live session: the fake model's voice on the real gateway.
// ---------------------------------------------------------------------------

interface SessionCallbacks {
  onopen?: () => void;
  onmessage?: (message: unknown) => void;
  onerror?: (error: unknown) => void;
}

class ScriptedLiveSession {
  private turnCursor = 0;
  readonly toolResponses: Array<{ id: string; name: string; response: Record<string, unknown> }> = [];
  /** Count of realtime inputs; the snapshot must flow as session_context, never realtime. */
  frameCount = 0;

  constructor(private readonly callbacks: SessionCallbacks) {}

  /** The gateway relays the phone's client_content envelope straight to the SDK. */
  sendClientContent(payload: { turns?: unknown } = {}): void {
    const text = clientContentText(payload.turns);
    const turn = cookSessionTurns[this.turnCursor];
    if (turn === undefined || text !== turn.userText) {
      fail(
        `client content "${text}" does not match scripted turn ${this.turnCursor} (expected "${turn?.userText ?? "<none>"}")`,
      );
      return;
    }
    this.turnCursor += 1;
    const callBase = this.turnCursor;
    setTimeout(() => {
      if (turn.utterance !== undefined) {
        this.callbacks.onmessage?.({
          serverContent: { modelTurn: { parts: [{ text: turn.utterance }] }, turnComplete: true },
        });
      }
      if (turn.calls?.length) {
        setTimeout(() => {
          this.callbacks.onmessage?.({
            toolCall: {
              functionCalls: turn.calls!.map((call, i) => ({
                id: `call-${callBase}-${i}`,
                name: call.name,
                args: call.args ?? {},
              })),
            },
          });
        }, 10);
      }
    }, 5);
  }

  sendRealtimeInput(_payload: unknown): void {
    this.frameCount += 1;
  }

  sendToolResponse(payload: { functionResponses?: Array<{ id: string; name: string; response: Record<string, unknown> }> }): void {
    for (const response of payload.functionResponses ?? []) this.toolResponses.push(response);
  }

  close(): void {}
}

function makeFakeAi(sessions: ScriptedLiveSession[]): GoogleGenAI {
  return {
    live: {
      connect: async (options: { callbacks: SessionCallbacks }) => {
        const session = new ScriptedLiveSession(options.callbacks);
        sessions.push(session);
        setTimeout(() => options.callbacks.onopen?.(), 0);
        return session;
      },
    },
  } as unknown as GoogleGenAI;
}

// ---------------------------------------------------------------------------
// Store wrapper: captures what the gateway persists (and what it never does).
// ---------------------------------------------------------------------------

function wrapStore(inner: LiveSessionStore): {
  store: LiveSessionStore;
  mintedId: () => string | null;
  ensureCount: () => number;
  deletedIds: () => string[];
  frameMetadata: () => StoredCameraFrameMetadata[];
} {
  let minted: string | null = null;
  let ensures = 0;
  const deleted: string[] = [];
  const metadata: StoredCameraFrameMetadata[] = [];
  const store: LiveSessionStore = {
    mode: inner.mode,
    ensureSession: async (sessionId) => {
      ensures += 1;
      minted = sessionId;
      return inner.ensureSession(sessionId);
    },
    getSession: (sessionId) => inner.getSession(sessionId),
    patchContext: (sessionId, patch) => inner.patchContext(sessionId, patch),
    recordFrameMetadata: (sessionId, meta) => {
      metadata.push(meta);
      return inner.recordFrameMetadata(sessionId, meta);
    },
    recordLatestConfidence: (sessionId, assessment) => inner.recordLatestConfidence(sessionId, assessment),
    deleteSession: async (sessionId) => {
      deleted.push(sessionId);
      await inner.deleteSession(sessionId);
    },
    sweepExpired: (nowMs) => inner.sweepExpired(nowMs),
  };
  return {
    store,
    mintedId: () => minted,
    ensureCount: () => ensures,
    deletedIds: () => deleted,
    frameMetadata: () => metadata,
  };
}

// ---------------------------------------------------------------------------
// Assertions over the tool responses the fake session received.
// ---------------------------------------------------------------------------

interface ReceiptShape {
  proposalID?: string;
  state?: string;
  reason?: string;
  allergenRecheck?: { verdict?: string; eaters?: string[]; blockedPath?: string | null };
}

function findResponse(session: ScriptedLiveSession, name: string): Record<string, unknown> | null {
  return session.toolResponses.find((r) => r.name === name)?.response ?? null;
}

/** The tool's result: the gateway wraps it as {output: result} (or {error}). */
function toolResult(session: ScriptedLiveSession, name: string): Record<string, unknown> | null {
  const response = findResponse(session, name);
  const output = response?.output;
  return output !== undefined && output !== null && typeof output === "object"
    ? (output as Record<string, unknown>)
    : null;
}

function assertTimerReceipt(session: ScriptedLiveSession): void {
  const result = toolResult(session, "proposeTimerStart");
  if (result === null) {
    step("S3 gateway resolves the timer proposal", false, "no proposeTimerStart tool response captured");
    return;
  }
  const receipt = (result.receipt ?? {}) as ReceiptShape;
  step(
    "S3 gateway resolves the timer proposal as executed",
    result.status === "resolved" && receipt.state === "executed",
    `status=${String(result.status)} state=${String(receipt.state)}`,
  );
}

function assertSwapReceipt(session: ScriptedLiveSession): void {
  const result = toolResult(session, "proposeSwap");
  if (result === null) {
    step("S4 gateway resolves the swap proposal as rejected", false, "no proposeSwap tool response captured");
    return;
  }
  const receipt = (result.receipt ?? {}) as ReceiptShape;
  const reason = receipt.reason ?? "";
  const recheck = receipt.allergenRecheck;
  // The recheck the receipt carries must match receipt.schema.json's
  // allergenRecheck object exactly: verdict from the enum, eater names, an
  // optional blockedPath — nothing else (the schema is additionalProperties:
  // false, and wire.ts enforces the shape when parsing the phone's envelope).
  const recheckOk =
    recheck !== undefined &&
    recheck.verdict === "verified" &&
    Array.isArray(recheck.eaters) &&
    recheck.eaters.length === 1 &&
    recheck.eaters[0] === "Ana" &&
    typeof recheck.blockedPath === "string" &&
    recheck.blockedPath.toLowerCase().includes("wheat") &&
    Object.keys(recheck).length === 3;
  step(
    "S4 gateway resolves the swap proposal as rejected (allergen re-check)",
    result.status === "resolved" && receipt.state === "rejected" && /allergen/i.test(reason),
    `state=${String(receipt.state)} reason="${reason}"`,
  );
  step(
    "S4 rejected receipt carries the contract-shaped allergen recheck",
    recheckOk,
    recheck === undefined ? "recheck missing" : JSON.stringify(recheck),
  );
}

function assertStaleStep(session: ScriptedLiveSession): void {
  const read = toolResult(session, "getStepContext");
  if (read === null) {
    step("S5 getStepContext answers from the phone's own snapshot", false, "no getStepContext response captured");
  } else {
    // The walk finished the recipe on the device after the swap turn and
    // re-sent its bounded snapshot: the read answers from the phone's own
    // state (done, step 4), not from anything the model assumed.
    step(
      "S5 getStepContext answers from the phone's own snapshot",
      read.sessionState === "done" && read.currentStepIndex === 4,
      `sessionState=${String(read.sessionState)} currentStepIndex=${String(read.currentStepIndex)}`,
    );
  }
  const result = toolResult(session, "proposeStepAdvance");
  if (result === null) {
    step("S5 gateway refuses the stale-step advance", false, "no proposeStepAdvance tool response captured");
    return;
  }
  const receipt = (result.receipt ?? {}) as ReceiptShape;
  step(
    "S5 gateway refuses the stale-step advance",
    result.status === "resolved" && receipt.state === "rejected" && (receipt.reason ?? "").includes("no active step"),
    `state=${String(receipt.state)} reason="${String(receipt.reason)}"`,
  );
}

function assertLookupRan(session: ScriptedLiveSession): void {
  const result = toolResult(session, "lookupSubstitution");
  // The read answers from the reviewed table with the recheck's acceptance
  // record in its evidence; the eater-specific hard block is proven end to end
  // by the S4 swap receipt (soy sauce carries wheat → rejected for Ana).
  const answer = (result?.answer ?? null) as { kind?: string; swaps?: unknown[] } | null;
  const evidence = JSON.stringify(result?.evidence ?? []);
  step(
    "S2 lookupSubstitution answers from the reviewed table with the allergen recheck recorded",
    answer !== null &&
      typeof answer.kind === "string" &&
      Array.isArray(answer.swaps) &&
      answer.swaps.length >= 1 &&
      evidence.includes("allergen recheck"),
    result === null ? "no lookupSubstitution response" : `kind=${String(answer?.kind)} swaps=${String(answer?.swaps?.length)}`,
  );
}

// ---------------------------------------------------------------------------
// The boot.
// ---------------------------------------------------------------------------

async function main(): Promise<number> {
  const port = Number(process.env.LECHEF_E2E_PORT ?? 8791);
  const walkBin = process.env.LECHEF_E2E_WALK_BIN;
  if (!walkBin) {
    console.error("boot: LECHEF_E2E_WALK_BIN is required (the built walk binary)");
    return 2;
  }

  const config: Record<string, unknown> = {
    port,
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
    groundingEnabled: true,
  };

  const sessions: ScriptedLiveSession[] = [];
  const holder = new InMemoryFrameHolder();
  const wrapped = wrapStore(createLiveSessionStore(config as never));
  const { server } = createAgentServer({
    ai: makeFakeAi(sessions),
    config: config as never,
    ledger: new InventoryLedger(config as never),
    confidenceService: new ConfidenceService(),
    sessionStore: wrapped.store,
    frames: holder,
  });

  await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
  console.log(`boot: gateway up on ws://127.0.0.1:${port}/v1/live (memory store, scripted model)`);

  let frameSeen = false;
  const framePoll = setInterval(() => {
    const id = wrapped.mintedId();
    if (id !== null && holder.get(id) !== null) frameSeen = true;
  }, 50);

  const child = spawn(walkBin, [], {
    env: { ...process.env, LECHEF_E2E_URL: `ws://127.0.0.1:${port}` },
    stdio: ["ignore", "inherit", "inherit"],
  });
  const watchdog = setTimeout(() => {
    console.error("boot: watchdog fired — killing the walk");
    child.kill("SIGKILL");
  }, 120_000);

  const walkExit = await new Promise<number>((resolve) => child.on("exit", (code) => resolve(code ?? -1)));
  clearTimeout(watchdog);
  clearInterval(framePoll);

  const minted = wrapped.mintedId();
  const session = sessions[0];

  step("S1 gateway mints its own session id (client-forged id ignored)", wrapped.ensureCount() === 1 && minted !== null && minted !== CLIENT_FORGED_ID, `minted=${String(minted)}`);

  if (session !== undefined) {
    assertLookupRan(session);
    step("S2 gateway received the camera frame into the in-process cache", frameSeen);
    const meta = wrapped.frameMetadata();
    step(
      "S2 store holds frame METADATA only (bytes stay in the cache)",
      meta.length === 1 && meta[0].mimeType === "image/jpeg" && meta[0].sizeBytes > 0,
      meta.length === 1 ? `sizeBytes=${meta[0].sizeBytes}` : `metadata rows=${meta.length}`,
    );
    step(
      "S2 snapshot rides session_context; the shutter frame is the only realtime input",
      session.frameCount === 1,
      `realtime inputs=${session.frameCount} (expected 1: the push-to-look frame)`,
    );
    assertTimerReceipt(session);
    assertSwapReceipt(session);
    assertStaleStep(session);
  } else {
    step("scripted session existed", false, "the fake model was never connected");
  }

  // Cleanup: the gateway deletes the session and evicts the frame on close.
  let blank = false;
  if (minted !== null) {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      const reading = await wrapped.store.getSession(minted);
      if (reading.createdAt === "") {
        blank = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  step("S6 session doc deleted on close (read enforces blank)", blank, `deleted=${JSON.stringify(wrapped.deletedIds())}`);
  step(
    "S6 frame cache evicted on close",
    minted === null || holder.get(minted) === null,
    `cache size=${holder.size}`,
  );

  server.close();
  console.log("boot: walk exit code", walkExit);
  const failed = results.filter((r) => !r.ok);
  console.log(`boot: ${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length > 0 || walkExit !== 0) {
    for (const f of failed) console.error(`boot: FAILED — ${f.name}${f.detail ? ` (${f.detail})` : ""}`);
    return 1;
  }
  console.log("boot: phone and gateway ran the cook session end to end ✓");
  return 0;
}

main()
  .then((code) => process.exit(code))
  .catch((error: unknown) => {
    console.error("boot crashed:", error);
    process.exit(2);
  });

// Referenced so the turn constants stay pinned to the script even if only the
// walk drives them today.
void TURN_TIMER;
void TURN_SWAP;
void TURN_STALE_STEP;
void boundedSnapshotPayload;
