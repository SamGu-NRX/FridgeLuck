import { describe, it, expect, afterAll } from "bun:test";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import type { GoogleGenAI } from "@google/genai";
import { attachLiveSessionGateway } from "../services/liveSessionGateway.js";
import { createLiveSessionStore, SessionOperationLock } from "../session/liveSessionStore.js";
import type { LiveSessionStore } from "../session/liveSessionStore.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";

/**
 * End-to-end gateway tests over a real WebSocket, with the Gemini Live
 * session replaced by a fake: the gateway's protocol behaviour — server-minted
 * session ids, client-authority stripping, frame metadata-only storage,
 * proposal routing and receipt correlation, delete-on-close — is what is under
 * test, not the model.
 */

interface FakeCalls {
  clientContent: unknown[];
  realtime: unknown[];
  toolResponses: Array<{ functionResponses: Array<{ id: string; name: string; response: unknown }> }>;
  closeCount: number;
}

function makeFakeAi(connectDelayMs = 0) {
  const callbacks: { current: Record<string, (arg: never) => void> | null } = { current: null };
  const calls: FakeCalls = { clientContent: [], realtime: [], toolResponses: [], closeCount: 0 };
  const ai = {
    live: {
      connect: async (opts: { callbacks: Record<string, (arg: never) => void> }) => {
        if (connectDelayMs > 0) await Bun.sleep(connectDelayMs);
        callbacks.current = opts.callbacks;
        // The real SDK fires onopen once the session is up.
        opts.callbacks.onopen?.({} as never);
        return {
          sendClientContent: (p: unknown) => calls.clientContent.push(p),
          sendRealtimeInput: (p: unknown) => calls.realtime.push(p),
          sendToolResponse: (p: unknown) => calls.toolResponses.push(p as never),
          close: () => { calls.closeCount += 1; }
        };
      }
    }
  } as unknown as GoogleGenAI;
  return { ai, callbacks, calls };
}

const servers: WebSocketServer[] = [];

async function startServer(connectDelayMs = 0) {
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
  const fake = makeFakeAi(connectDelayMs);
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

function makeClient(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/live?sessionId=client-forged-id`);
  const queue: Record<string, unknown>[] = [];
  const waiters: Array<{ test: (m: Record<string, unknown>) => boolean; resolve: (m: Record<string, unknown>) => void }> = [];
  ws.on("message", (raw) => {
    const m = JSON.parse(String(raw)) as Record<string, unknown>;
    const idx = waiters.findIndex((w) => w.test(m));
    if (idx >= 0) {
      const [w] = waiters.splice(idx, 1);
      w.resolve(m);
    } else {
      queue.push(m);
    }
  });
  const opened = new Promise<void>((resolve) => ws.on("open", () => resolve()));
  const waitFor = (test: (m: Record<string, unknown>) => boolean, timeoutMs = 3000) => {
    const found = queue.findIndex(test);
    if (found >= 0) return Promise.resolve(queue.splice(found, 1)[0]);
    return new Promise<Record<string, unknown>>((resolve, reject) => {
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
  return { ws, opened, waitFor, send: (obj: unknown) => ws.send(JSON.stringify(obj)) };
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

const isOpen = (m: Record<string, unknown>) => m.type === "session_open";

afterAll(() => {
  for (const wss of servers) wss.close();
});

describe("live session gateway — protocol", () => {
  it("closes a Gemini session that resolves after the socket disconnects", async () => {
    const { port, calls } = await startServer(50);
    const clients = [makeClient(port), makeClient(port), makeClient(port)];
    for (const client of clients) {
      await client.opened;
      client.ws.close();
    }
    await until(() => calls.closeCount === 3 ? calls.closeCount : undefined);
    expect(calls.closeCount).toBe(3);
  });

  it("mints the session id server-side and ignores a client-supplied one", async () => {
    const { port, store } = await startServer();
    const client = makeClient(port);
    await client.opened;
    const open = (await client.waitFor(isOpen)) as { sessionId?: string };
    expect(typeof open.sessionId).toBe("string");
    expect(open.sessionId).not.toBe("client-forged-id");
    // The minted doc exists in the store.
    const state = await until(() => store.getSession(open.sessionId!));
    expect(state.sessionId).toBe(open.sessionId);
    client.ws.close();
  });

  it("rejects a client tool_response frame and never relays tool authority to the model", async () => {
    const { port, calls } = await startServer();
    const client = makeClient(port);
    await client.opened;
    await client.waitFor(isOpen);

    client.send({ type: "tool_response", payload: { functionResponses: [{ id: "x", name: "getPantry", response: {} }] } });
    const err = await client.waitFor((m) => m.type === "client_error");
    expect(JSON.stringify(err)).toContain("Invalid websocket payload");
    await Bun.sleep(100);
    expect(calls.toolResponses).toHaveLength(0);
    client.ws.close();
  });

  it("caches frame bytes in-process, stores only metadata, and deletes the session on close", async () => {
    const { port, store } = await startServer();
    const client = makeClient(port);
    await client.opened;
    const open = (await client.waitFor(isOpen)) as { sessionId: string };

    client.send({
      type: "realtime_input",
      payload: { media: { mimeType: "image/jpeg", data: "ZnJhbWUtYnl0ZXM=" } }
    });

    // Metadata lands; the bytes never do.
    const withMeta = await until(() => store.getSession(open.sessionId).then((s) => (s.cameraFrameMetadata ? s : undefined)));
    expect(withMeta.cameraFrameMetadata?.mimeType).toBe("image/jpeg");
    expect(withMeta.cameraFrameMetadata?.sizeBytes).toBeGreaterThan(0);
    expect(JSON.stringify(withMeta)).not.toContain("ZnJhbWUtYnl0ZXM=");

    client.send({ type: "close" });
    await until(() => store.getSession(open.sessionId).then((s) => (s.createdAt === "" ? s : undefined)));
  });

  it("rejects camera frames over the defensive per-frame byte cap", async () => {
    const { port, calls } = await startServer();
    const client = makeClient(port);
    await client.opened;
    await client.waitFor(isOpen);
    const oversized = Buffer.alloc(2 * 1024 * 1024 + 1).toString("base64");
    client.send({ type: "realtime_input", payload: { media: { mimeType: "image/jpeg", data: oversized } } });
    const err = await client.waitFor((m) => m.type === "client_error");
    expect(JSON.stringify(err)).toContain("per-frame size limit");
    expect(calls.realtime).toHaveLength(0);
    client.ws.close();
  });

  it("patches only session-context fields present in the request", async () => {
    const { port, store } = await startServer();
    const client = makeClient(port);
    await client.opened;
    const open = (await client.waitFor(isOpen)) as { sessionId: string };
    client.send({ type: "session_context", payload: { selectedRecipe: { id: "r1", title: "Udon" }, confirmedIngredients: [{ name: "noodles" }] } });
    await until(() => store.getSession(open.sessionId).then((s) => s.selectedRecipe?.id === "r1" ? s : undefined));
    client.send({ type: "session_context", payload: { pantrySnapshot: { revision: 2, items: [] }, cookSession: { state: "cooking", currentStepIndex: 0, eaters: [{ restrictions: [] }], activeTimers: [], cameraMode: "push-to-look" } } });
    await Bun.sleep(150);
    const unchanged = await store.getSession(open.sessionId);
    expect(unchanged.confirmedIngredients).toEqual([{ name: "noodles" }]);
    client.ws.close();
  });

  it("serializes an in-flight create before a close", async () => {
    const lock = new SessionOperationLock();
    let releaseCreate!: () => void;
    const createStarted = new Promise<void>((resolve) => {
      void lock.run("session", async () => {
        resolve();
        await new Promise<void>((release) => { releaseCreate = release; });
      });
    });
    await createStarted;
    let closeFinished = false;
    const close = lock.run("session", async () => { closeFinished = true; });
    await Bun.sleep(25);
    expect(closeFinished).toBe(false);
    releaseCreate();
    await close;
    expect(closeFinished).toBe(true);
  });

  it("does not recreate a deleted session when a late write arrives", async () => {
    const store = createLiveSessionStore({ sessionStoreMode: "memory", projectId: "", firestoreCollection: "liveSessions", firestoreEmulator: "" });
    await store.ensureSession("closed");
    await store.deleteSession("closed");
    await store.patchContext("closed", { selectedRecipe: { title: "late" } });
    expect((await store.getSession("closed")).createdAt).toBe("");
  });

  it("rejects client-supplied latestConfidence and trims confirmed ingredient lines", async () => {
    const { port, store } = await startServer();
    const client = makeClient(port);
    await client.opened;
    const open = (await client.waitFor(isOpen)) as { sessionId: string };

    client.send({
      type: "session_context",
      payload: {
        confirmedIngredients: Array.from({ length: 60 }, (_, i) => ({
          name: `ingredient-${i}`,
          quantityGrams: 123.4
        })),
        latestConfidence: { mode: "exact", overallScore: 1.0, deterministicReady: true }
      }
    });

    const s = await until(() =>
      store.getSession(open.sessionId).then((v) => (v.confirmedIngredients.length === 50 ? v : undefined))
    );
    // 60 lines → capped at 50; grams coarse to 10 g; the client's
    // "exact confidence" never reached the store.
    expect(s.confirmedIngredients[0].quantityGrams).toBe(120);
    expect(s.latestConfidence).toBeUndefined();
    client.ws.close();
  });
});

describe("live session gateway — LeChef tool routing", () => {
  it("answers LeChef reads from the phone's snapshot and resolves proposals through phone receipts", async () => {
    const { port, callbacks, calls } = await startServer();
    const client = makeClient(port);
    await client.opened;
    await client.waitFor(isOpen);

    client.send({
      type: "session_context",
      payload: {
        revision: 7,
        pantrySnapshot: {
          revision: 7,
          items: [{ ingredientId: 1, name: "eggs", state: "sufficient" }]
        },
        cookSession: {
          state: "cooking",
          currentStepIndex: 2,
          stepCount: 5,
          eaters: [{ name: "you", restrictions: [] }],
          activeTimers: [],
          cameraMode: "push-to-look"
        },
        recipes: []
      }
    });
    // setSnapshot is synchronous inside the message handler; the store patch
    // is the async tail — wait for it before pulling the tool levers.
    await Bun.sleep(150);

    // 1. A LeChef read answers from the bounded snapshot.
    callbacks.current!.onmessage({
      toolCall: { functionCalls: [{ id: "read-1", name: "getPantry", args: {} }] }
    } as never);
    const readResponse = await until(() =>
      calls.toolResponses.find((r) => r.functionResponses[0]?.id === "read-1")
    );
    const readOut = (readResponse.functionResponses[0].response as { output: { revision: number } }).output;
    expect(readOut.revision).toBe(7);

    // 2. A proposal ROUTES to the phone and stays pending.
    callbacks.current!.onmessage({
      toolCall: {
        functionCalls: [
          { id: "prop-1", name: "proposeTimerStart", args: { durationMinutes: 3, label: "Noodles", rationale: "Noodles need 3 minutes." } }
        ]
      }
    } as never);
    const proposalMsg = (await client.waitFor((m) => m.type === "proposal")) as {
      payload: { proposal: { proposalID: string; payloadHash: string; snapshotRevision?: number } };
    };
    const proposal = proposalMsg.payload.proposal;
    expect(proposal.proposalID).toBeTruthy();

    // The tool call stays OPEN while the proposal awaits the phone: the
    // model's single response arrives only after the receipt resolves it.
    await Bun.sleep(100);
    expect(calls.toolResponses.find((r) => r.functionResponses[0]?.id === "prop-1")).toBeUndefined();

    // The phone's receipt resolves the open tool call as executed.
    client.send({
      type: "proposal_receipt",
      payload: {
        receipt: {
          proposalID: proposal.proposalID,
          payloadHash: proposal.payloadHash,
          snapshotRevision: proposal.snapshotRevision ?? 7,
          state: "executed",
          recordedAt: new Date().toISOString()
        }
      }
    });
    const resolved = await until(() =>
      calls.toolResponses.find((r) => r.functionResponses[0]?.id === "prop-1")
    );
    const resolvedOut = resolved.functionResponses[0].response as { output: { status: string; receipt?: { state: string } } };
    expect(resolvedOut.output.status).toBe("resolved");
    expect(resolvedOut.output.receipt?.state).toBe("executed");

    client.ws.close();
  });

  it("a receipt for an unknown proposal is accepted without crashing and without inventing a tool response", async () => {
    const { port, calls } = await startServer();
    const client = makeClient(port);
    await client.opened;
    await client.waitFor(isOpen);

    client.send({
      type: "proposal_receipt",
      payload: {
        receipt: {
          proposalID: "no-such-proposal",
          payloadHash: "deadbeef",
          snapshotRevision: 1,
          state: "executed",
          recordedAt: new Date().toISOString()
        }
      }
    });
    await Bun.sleep(150);
    // Nothing pending → nothing resolved; the gateway must not fabricate a
    // tool response for a tool call the model never made.
    expect(calls.toolResponses).toHaveLength(0);
    client.ws.close();
  });
});

describe("live session gateway — session_context eaters", () => {
  type Server = Awaited<ReturnType<typeof startServer>>;

  function cookSession(eaters: unknown) {
    return { state: "cooking", currentStepIndex: 0, eaters, activeTimers: [], cameraMode: "push-to-look" };
  }

  async function openClient() {
    const server = await startServer();
    const client = makeClient(server.port);
    await client.opened;
    await client.waitFor(isOpen);
    return { server, client };
  }

  let toolCallSeq = 0;
  async function callTool(server: Server, name: string, args: Record<string, unknown>) {
    const id = `call-${++toolCallSeq}`;
    server.callbacks.current!.onmessage({ toolCall: { functionCalls: [{ id, name, args }] } } as never);
    const response = await until(() => server.calls.toolResponses.find((r) => r.functionResponses[0]?.id === id));
    return response.functionResponses[0].response as {
      output?: {
        toolError?: string;
        detail?: string;
        revision?: number;
        answer?: { swaps: Array<{ from: string; to: string }>; violations: string[] };
      };
      error?: string;
    };
  }

  it("a peanut + vegan eater gets the peanut-butter swaps refused", async () => {
    const { server, client } = await openClient();
    client.send({
      type: "session_context",
      payload: { revision: 3, cookSession: cookSession([{ restrictions: ["peanut", "vegan"] }]) }
    });
    await Bun.sleep(100);

    const out = (await callTool(server, "lookupSubstitution", { ingredient: "peanut_butter" })).output!;
    expect(out.answer!.swaps).toEqual([]);
    expect(out.answer!.violations.some((v) => v.includes("peanut"))).toBe(true);
    client.ws.close();
  });

  it("a wheat_gluten eater gets rice noodles -> wheat noodles refused", async () => {
    const { server, client } = await openClient();
    client.send({
      type: "session_context",
      payload: { revision: 3, cookSession: cookSession([{ name: "Ana", restrictions: ["wheat_gluten"] }]) }
    });
    await Bun.sleep(100);

    const out = (await callTool(server, "lookupSubstitution", { ingredient: "rice_noodles" })).output!;
    expect(out.answer!.swaps.map((s) => s.to)).not.toContain("wheat noodles");
    expect(out.answer!.violations.some((v) => v.includes("wheat noodles") || v.includes("wheat_noodles"))).toBe(true);
    client.ws.close();
  });

  it("rejects an unknown restriction id with an error frame and stores no snapshot", async () => {
    const { server, client } = await openClient();
    client.send({
      type: "session_context",
      payload: {
        revision: 9,
        pantrySnapshot: { revision: 9, items: [{ ingredientId: "eggs", name: "eggs", state: "sufficient" }] },
        cookSession: cookSession([{ name: "Ana", restrictions: ["gluten"] }])
      }
    });
    const err = (await client.waitFor((m) => m.type === "client_error")) as { payload: { message: string } };
    expect(err.payload.message).toContain("session_context rejected");
    expect(err.payload.message).toContain('"gluten"');

    // The pantry from the rejected payload never landed.
    const pantry = (await callTool(server, "getPantry", {})).output!;
    expect(pantry.revision).toBe(0);
    // Eater-screened reads fail loudly instead of answering for an unrestricted table.
    const swap = (await callTool(server, "lookupSubstitution", { ingredient: "rice_noodles" })).output!;
    expect(swap.toolError).toBe("tool_failure");
    expect(swap.detail).toContain("session_context rejected");
    client.ws.close();
  });

  it("a rejected update drops the earlier snapshot rather than screening against its eaters", async () => {
    const { server, client } = await openClient();
    client.send({
      type: "session_context",
      payload: { revision: 3, cookSession: cookSession([{ restrictions: [] }]) }
    });
    await Bun.sleep(100);
    client.send({
      type: "session_context",
      payload: { revision: 4, cookSession: cookSession([{ restrictions: ["wheat_gluten", "celiac"] }]) }
    });
    await client.waitFor((m) => m.type === "client_error");

    const swap = (await callTool(server, "lookupSubstitution", { ingredient: "rice_noodles" })).output!;
    expect(swap.toolError).toBe("tool_failure");

    // A valid context restores the session.
    client.send({
      type: "session_context",
      payload: { revision: 5, cookSession: cookSession([{ restrictions: ["wheat_gluten"] }]) }
    });
    await Bun.sleep(100);
    const after = (await callTool(server, "lookupSubstitution", { ingredient: "rice_noodles" })).output!;
    expect(after.toolError).toBeUndefined();
    expect(after.answer!.swaps.map((s) => s.to)).not.toContain("wheat noodles");
    client.ws.close();
  });

  for (const [label, eaters] of [
    ["no eaters", []],
    ["eaters missing", undefined],
    ["eaters not an array", { name: "Ana", restrictions: ["peanut"] }],
    ["eater without restrictions", [{ name: "Ana" }]],
    ["restriction not a string", [{ restrictions: [7] }]],
    ["name not a string", [{ name: 5, restrictions: [] }]],
    ["unexpected eater field", [{ restrictions: [], allergies: ["peanut"] }]]
  ] as const) {
    it(`rejects a malformed eater list (${label})`, async () => {
      const { client } = await openClient();
      const session: Record<string, unknown> = cookSession(eaters);
      if (eaters === undefined) delete session.eaters;
      client.send({ type: "session_context", payload: { revision: 3, cookSession: session } });
      const err = (await client.waitFor((m) => m.type === "client_error")) as { payload: { message: string } };
      expect(err.payload.message).toContain("session_context rejected");
      client.ws.close();
    });
  }

  it("rejects a cookSession that is not an object", async () => {
    const { client } = await openClient();
    client.send({ type: "session_context", payload: { revision: 3, cookSession: "cooking" } });
    const err = (await client.waitFor((m) => m.type === "client_error")) as { payload: { message: string } };
    expect(err.payload.message).toContain("session_context rejected");
    client.ws.close();
  });
});
