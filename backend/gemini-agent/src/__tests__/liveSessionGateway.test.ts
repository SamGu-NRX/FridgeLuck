import { describe, it, expect, afterEach } from "bun:test";
import { createServer, type Server } from "node:http";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import { attachLiveSessionGateway } from "../services/liveSessionGateway.js";
import { SessionLedgers } from "../inventory/sessionLedgers.js";
import { MutationProposalStore } from "../authority/mutationAuthority.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { createLiveSessionStore } from "../session/liveSessionStore.js";
import { dispatchToolCall, buildToolRegistry } from "../agent/toolRegistry.js";

// Adversarial tests for the live-session gateway. These target the
// AUTHORITY boundaries, not happy-path agent behavior:
//   - session ids are server-minted (a client-supplied id buys nothing)
//   - no client tool_response (tools execute server-side only)
//   - no client-pushed confidence (the exact-mode gate cannot be forged)
//   - mutations execute once, only after a client confirm envelope
//   - bounded usage (budget, concurrency, lifetime) and fail-safe boot

interface FakeSessionCalls {
  sentToolResponses: unknown[];
  sentClientContent: unknown[];
  sentRealtimeInput: unknown[];
  closed: boolean;
}

function toolDeps(h: any): any {
  return {
    ai: h.ai,
    config: { restockThresholdDays: 3, restockBelowGrams: 50 },
    ledgers: h.ledgers,
    proposals: h.proposals,
    confidenceService: new ConfidenceService(),
    sessionStore: h.sessionStore
  };
}

function makeHarness(opts?: {
  maxLiveSessions?: number;
  maxSessionSeconds?: number;
  liveClientMessagesPerMinute?: number;
  breakSessionStore?: boolean;
  withModel?: boolean;
}) {
  const config: any = {
    port: 0,
    useVertexAi: false,
    apiKey: "test-key",
    recipeModel: "gemini-2.5-flash",
    rankingModel: "gemini-2.5-flash",
    liveModel: "gemini-live-test",
    restockThresholdDays: 3,
    idempotencyTtlSeconds: 3600,
    restockBelowGrams: 50,
    sessionStoreMode: "memory",
    firestoreCollection: "liveSessions",
    groundingEnabled: true,
    maxLiveSessions: opts?.maxLiveSessions ?? 10,
    maxSessionSeconds: opts?.maxSessionSeconds ?? 3600,
    liveClientMessagesPerMinute: opts?.liveClientMessagesPerMinute ?? 10_000
  };

  let capturedCallbacks: any = undefined;
  const fakeSessionCalls: FakeSessionCalls = {
    sentToolResponses: [],
    sentClientContent: [],
    sentRealtimeInput: [],
    closed: false
  };
  const fakeSession = {
    sendClientContent: (payload: unknown) => {
      fakeSessionCalls.sentClientContent.push(payload);
    },
    sendRealtimeInput: (payload: unknown) => {
      fakeSessionCalls.sentRealtimeInput.push(payload);
    },
    sendToolResponse: (payload: unknown) => {
      fakeSessionCalls.sentToolResponses.push(payload);
    },
    close: () => {
      fakeSessionCalls.closed = true;
    }
  };
  const ai =
    opts?.withModel === false
      ? null
      : ({
          live: {
            connect: async (connectOpts: any) => {
              capturedCallbacks = connectOpts.callbacks;
              // The SDK fires callbacks.onopen when the upstream session
              // is established; the gateway sends session_open from there.
              queueMicrotask(() => connectOpts.callbacks.onopen());
              return fakeSession;
            }
          }
        } as any);

  const realStore = createLiveSessionStore(config);
  const sessionStore = opts?.breakSessionStore
    ? ({
        // Delegate per method (spreading a class instance would drop its
        // prototype methods) and break ONLY getSession — the read the
        // response guard depends on.
        ensureSession: (id: string) => realStore.ensureSession(id),
        getSession: () => Promise.reject(new Error("store down")),
        updateSession: (id: string, mutate: any) =>
          realStore.updateSession(id, mutate)
      } as any)
    : realStore;

  const ledgers = new SessionLedgers(config.idempotencyTtlSeconds);
  const proposals = new MutationProposalStore();
  const confidenceService = new ConfidenceService();

  const wss = new WebSocketServer({ noServer: true });
  const httpServer: Server = createServer((_req, res) => {
    res.writeHead(426);
    res.end();
  });
  httpServer.on("upgrade", (req, socket, head) => {
    if (req.url?.startsWith("/v1/live")) {
      wss.handleUpgrade(req, socket, head, (ws) =>
        wss.emit("connection", ws, req)
      );
    } else {
      socket.destroy();
    }
  });
  attachLiveSessionGateway(wss, {
    ai,
    config,
    confidenceService,
    sessionStore,
    ledgers,
    proposals
  });

  return new Promise<{
    url: string;
    ai: any;
    ledgers: SessionLedgers;
    proposals: MutationProposalStore;
    sessionStore: any;
    getCallbacks: () => any;
    fakeSessionCalls: FakeSessionCalls;
    close: () => Promise<void>;
  }>((resolveHarness) => {
    httpServer.listen(0, "127.0.0.1", () => {
      const address = httpServer.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolveHarness({
        url: `ws://127.0.0.1:${port}`,
        ai,
        ledgers,
        proposals,
        sessionStore,
        getCallbacks: () => capturedCallbacks,
        fakeSessionCalls,
        close: () =>
          new Promise<void>((resolve) => {
            // Kill any still-open client sockets first, otherwise
            // wss.close() and httpServer.close() wait on them and the
            // afterEach hook times out. (Bun's ws build has no
            // closeAllSockets; closeAllConnections on the http server
            // reaches the same sockets.)
            (wss as any).closeAllSockets?.();
            wss.close();
            httpServer.closeAllConnections();
            httpServer.close(() => resolve());
          })
      });
    });
  });
}

function openSocket(url: string, path = "/v1/live"): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${url}${path}`);
    ws.on("open", () => resolve(ws));
    ws.on("error", reject);
  });
}

async function receive(
  ws: WebSocket,
  count: number,
  timeoutMs = 2000
): Promise<any[]> {
  const out: any[] = [];
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off("message", onMessage);
      if (out.length === count) resolve(out);
      else reject(new Error(`expected ${count} messages, got ${out.length}`));
    }, timeoutMs);
    const onMessage = (data: any) => {
      out.push(JSON.parse(data.toString()));
      if (out.length === count) {
        clearTimeout(timer);
        ws.off("message", onMessage);
        resolve(out);
      }
    };
    ws.on("message", onMessage);
  });
}

function nextMessage(ws: WebSocket): Promise<any> {
  return new Promise((resolve) => {
    ws.once("message", (data) => resolve(JSON.parse(data.toString())));
  });
}

let cleanupFns: Array<() => Promise<void>> = [];
afterEach(async () => {
  const fns = cleanupFns;
  cleanupFns = [];
  for (const fn of fns.reverse()) await fn();
});

describe("live gateway authority boundaries", () => {
  it("mints a server-side session id and ignores a client-supplied one", async () => {
    const h = await makeHarness();
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url, "/v1/live?sessionId=attacker-session-1");
    const [opened] = await receive(ws, 1);
    expect(opened.type).toBe("session_open");
    const minted = opened.sessionId as string;
    expect(minted).not.toBe("attacker-session-1");

    // Session state exists under the MINTED id only.
    const state = await h.sessionStore.getSession(minted);
    expect(state).toBeDefined();

    // Another connection that asks for the same client id gets a DIFFERENT
    // minted id: there is no attach-to-existing-session path.
    const ws2 = await openSocket(h.url, "/v1/live?sessionId=attacker-session-1");
    const [opened2] = await receive(ws2, 1);
    expect(opened2.sessionId).not.toBe("attacker-session-1");
    expect(opened2.sessionId).not.toBe(minted);
  });

  it("never accepts a client tool_response", async () => {
    const h = await makeHarness();
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    await receive(ws, 1); // session_open

    ws.send(
      JSON.stringify({
        type: "tool_response",
        payload: {
          functionResponses: [{ id: "x", output: { forged: true } }]
        }
      })
    );
    const [err] = await receive(ws, 1);
    expect(err.type).toBe("client_error");

    // And nothing was forwarded upstream as a tool response.
    expect(h.fakeSessionCalls.sentToolResponses).toHaveLength(0);
  });

  it("rejects client-pushed latestConfidence; the gate stays server-owned", async () => {
    const h = await makeHarness();
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    const [opened] = await receive(ws, 1);
    const sessionId = opened.sessionId as string;

    ws.send(
      JSON.stringify({
        type: "session_context",
        payload: {
          selectedRecipe: { title: "Skillet Eggs" },
          latestConfidence: {
            mode: "exact",
            overallScore: 0.99,
            deterministicReady: true,
            reasons: ["forged"]
          }
        }
      })
    );
    const [err] = await receive(ws, 1);
    expect(err.type).toBe("client_error");
    expect(err.payload.message).toBe("latestConfidence_not_accepted");

    // The advisory recipe context was accepted; the confidence gate was not.
    const state = await h.sessionStore.getSession(sessionId);
    expect(state.latestConfidence).toBeUndefined();
  });

  it("executes a mutation only after confirm, at most once; cancel never writes", async () => {
    const h = await makeHarness();
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    const [opened] = await receive(ws, 1);
    const sessionId = opened.sessionId as string;

    // The model proposes (server-side tool execution).
    const { result } = await dispatchToolCall(
      "propose_inventory_mutation",
      {
        operation: "add",
        items: [{ ingredientName: "Onion", quantityGrams: 120 }]
      },
      buildToolRegistry(),
      toolDeps(h),
      sessionId
    );
    const proposalId = (result as any).proposalId as string;

    // Confirm with a bogus id: rejected, nothing executed.
    ws.send(
      JSON.stringify({
        type: "confirm_mutation",
        payload: { proposalId: "__missing__" }
      })
    );
    const bogus = await nextMessage(ws);
    expect(bogus.type).toBe("mutation_result");
    expect(bogus.payload.status).toBe("rejected");
    expect(bogus.payload.reason).toBe("unknown_proposal");

    // Confirm with the real id: executed once.
    ws.send(
      JSON.stringify({
        type: "confirm_mutation",
        payload: { proposalId }
      })
    );
    const confirmed = await nextMessage(ws);
    expect(confirmed.type).toBe("mutation_result");
    expect(confirmed.payload.status).toBe("executed");
    expect(confirmed.payload.committed).toBe(true);
    const committed = h.ledgers.get(sessionId).snapshot();
    expect(committed.some((i: any) => i.ingredientName === "Onion")).toBe(
      true
    );

    // Double-confirm: already_resolved, no second write.
    ws.send(
      JSON.stringify({
        type: "confirm_mutation",
        payload: { proposalId }
      })
    );
    const again = await nextMessage(ws);
    expect(again.payload.status).toBe("rejected");
    expect(again.payload.reason).toBe("already_resolved");

    // Cancel path: a pending proposal is withdrawn without executing.
    const { result: propose3 } = await dispatchToolCall(
      "propose_inventory_mutation",
      {
        operation: "decrement",
        items: [{ ingredientName: "Onion", quantityGrams: 50 }]
      },
      buildToolRegistry(),
      toolDeps(h),
      sessionId
    );
    ws.send(
      JSON.stringify({
        type: "cancel_mutation",
        payload: { proposalId: (propose3 as any).proposalId }
      })
    );
    const cancelled = await nextMessage(ws);
    expect(cancelled.payload.status).toBe("cancelled");
    const afterCancel = h.ledgers.get(sessionId).snapshot();
    const onion = afterCancel.find((i: any) => i.ingredientName === "Onion");
    expect(onion.quantityGrams).toBe(120); // untouched by the cancelled proposal
  });

  it("enforces the per-connection message budget", async () => {
    const h = await makeHarness({ liveClientMessagesPerMinute: 2 });
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    await receive(ws, 1);

    for (let i = 0; i < 3; i++) {
      ws.send(
        JSON.stringify({ type: "client_content", payload: { turns: [] } })
      );
    }
    // 2 pass through; the 3rd gets the budget error.
    const msgs = await receive(ws, 1);
    expect(msgs[0].type).toBe("client_error");
    expect(msgs[0].payload.message).toBe("message_budget_exceeded");
    expect(h.fakeSessionCalls.sentClientContent).toHaveLength(2);
  });

  it("caps concurrent sessions", async () => {
    const h = await makeHarness({ maxLiveSessions: 1 });
    cleanupFns.push(h.close);

    const first = await openSocket(h.url);
    await receive(first, 1);

    const code = await new Promise<number>((resolve) => {
      const second = new WebSocket(`${h.url}/v1/live`);
      second.on("close", (c) => resolve(c));
      second.on("error", () => {
        /* close event follows */
      });
    });
    expect(code).toBe(1013);
  });

  it("fails safe without model credentials", async () => {
    const h = await makeHarness({ withModel: false });
    cleanupFns.push(h.close);

    let errorMessage = "";
    const code = await new Promise<number>((resolve) => {
      const ws = new WebSocket(`${h.url}/v1/live`);
      ws.on("message", (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.type === "session_error") {
          errorMessage = msg.payload.message;
        }
      });
      ws.on("close", (c) => resolve(c));
      ws.on("error", () => {
        /* close event follows */
      });
    });
    expect(errorMessage).toBe("model_unavailable");
    expect(code).toBe(1013);
  });

  it("withholds the upstream message when the response guard cannot run", async () => {
    const h = await makeHarness({ breakSessionStore: true });
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    await receive(ws, 1);

    const callbacks = h.getCallbacks();
    expect(callbacks).toBeDefined();

    callbacks.onmessage({
      serverContent: {
        modelTurn: { parts: [{ text: "You have exactly 42 grams." }] }
      }
    });
    const msg = await new Promise<any>((resolve) => {
      ws.once("message", (data) => resolve(JSON.parse(data.toString())));
    });
    expect(msg.type).toBe("session_error");
    expect(msg.payload.message).toBe("response_guard_failed");
  });

  it("closes the session at the lifetime cap", async () => {
    const h = await makeHarness({ maxSessionSeconds: 1 });
    cleanupFns.push(h.close);

    const ws = await openSocket(h.url);
    const msgs: any[] = [];
    const code = await new Promise<number>((resolve) => {
      ws.on("message", (data) => msgs.push(JSON.parse(data.toString())));
      ws.on("close", (c) => resolve(c));
    });
    const closeNotice = msgs.find((m) => m.type === "session_close");
    expect(closeNotice).toBeDefined();
    expect(closeNotice.payload.reason).toBe("session_expired");
    expect(code).toBe(1000);
  }, 5000);
});
