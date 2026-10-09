import { afterAll, describe, expect, it } from "bun:test";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createApp } from "../http/app.js";
import {
  attachTransportFrameCap,
  createLiveUpgradeHandler,
  WS_MAX_PAYLOAD_BYTES
} from "../http/liveUpgrade.js";
import { WS_MAX_PAYLOAD_BYTES as WS_MAX_PAYLOAD_FROM_LIMITS } from "../http/limits.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import type { AppConfig } from "../types/contracts.js";

// Upgrade routing + transport-ceiling tests. The units under test are
// createLiveUpgradeHandler (only /v1/live upgrades may complete; every other
// upgrade attempt must have its socket destroyed) and attachTransportFrameCap
// (the 8 MiB transport ceiling must actually kill oversized frames — Bun's
// ws runtime ignores WebSocketServer.maxPayload, so the explicit cap is what
// makes the ceiling real in this repo's runtime; under Node maxPayload would
// close first). packet025 owns the smaller semantic caps underneath this.

const testConfig: AppConfig = {
  port: 0,
  useVertexAi: false,
  recipeModel: "test-recipe-model",
  rankingModel: "test-ranking-model",
  liveModel: "test-live-model",
  restockThresholdDays: 3,
  idempotencyTtlSeconds: 3600,
  restockBelowGrams: 50,
  sessionStoreMode: "memory",
  firestoreCollection: "liveSessions",
  groundingEnabled: true
};

const servers: Array<Server> = [];
afterAll(() => {
  for (const server of servers.splice(0)) {
    server.close();
  }
});

function startWithUpgradeHandler(
  configure: (server: Server, wss: WebSocketServer) => void
): Promise<string> {
  const wss = new WebSocketServer({ noServer: true, maxPayload: WS_MAX_PAYLOAD_BYTES });
  // Same wiring order as production server.ts: cap first, then configuration.
  attachTransportFrameCap(wss);
  const app = createApp({
    config: testConfig,
    ai: {} as never,
    ledger: new InventoryLedger({ idempotencyTtlSeconds: 3600 }),
    confidenceService: new ConfidenceService()
  });
  const server = createServer(app);
  configure(server, wss);
  servers.push(server);
  return new Promise<string>((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolve(`ws://127.0.0.1:${port}`);
    });
  });
}

interface CloseOutcome {
  opened: boolean;
  closeCode?: number;
  closeReason?: string;
  errorMessage?: string;
}

/** Wait for a client terminal event (open+close, or error). */
function awaitTerminal(ws: WebSocket, timeoutMs = 3000): Promise<CloseOutcome> {
  return new Promise((resolve) => {
    const outcome: CloseOutcome = { opened: false };
    const timer = setTimeout(() => {
      resolve({ ...outcome, errorMessage: outcome.errorMessage ?? "timeout awaiting terminal event" });
    }, timeoutMs);
    const finish = (patch: Partial<CloseOutcome>) => {
      clearTimeout(timer);
      resolve({ ...outcome, ...patch });
    };
    ws.on("open", () => {
      outcome.opened = true;
    });
    ws.on("close", (code: number, reason: Buffer) => {
      finish({ closeCode: code, closeReason: reason.toString() });
    });
    ws.on("error", (error: Error) => {
      finish({ errorMessage: `${(error as NodeJS.ErrnoException).code ?? ""} ${error.message}` });
    });
  });
}

describe("live websocket upgrade routing", () => {
  it("completes /v1/live upgrades and destroys sockets for other paths", async () => {
    const base = await startWithUpgradeHandler((server, wss) => {
      server.on("upgrade", createLiveUpgradeHandler(wss));
      wss.on("connection", (socket) => {
        socket.send(JSON.stringify({ type: "connected" }));
      });
    });

    // Accepted path: upgrade completes, connection handler runs, frames flow.
    const accepted = new WebSocket(`${base}/v1/live?sessionId=test-session`);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("upgrade never completed")), 3000);
      accepted.on("open", () => {
        clearTimeout(timer);
        resolve();
      });
      accepted.on("error", (error: Error) => {
        clearTimeout(timer);
        reject(new Error(`upgrade failed: ${error.message}`));
      });
    });

    // Rejected path: socket destroyed before any 101 response.
    const rejected = new WebSocket(`${base}/v1/other`);
    const rejectedOutcome = await awaitTerminal(rejected);
    expect(rejectedOutcome.opened).toBeFalse();

    accepted.close();
    rejected.close();
  });

  it("kills frames over the 8 MiB transport ceiling with a 1009 close", async () => {
    const base = await startWithUpgradeHandler((server, wss) => {
      server.on("upgrade", createLiveUpgradeHandler(wss));
      // Echo handler: whatever the client sends comes back — unless the
      // transport cap kills the connection first.
      wss.on("connection", (socket) => {
        socket.on("message", (data: unknown) => {
          socket.send(data as string);
        });
      });
    });

    const client = new WebSocket(`${base}/v1/live?sessionId=cap-test`);
    await new Promise<void>((resolve) => client.on("open", resolve));

    // One byte over the ceiling: a hard transport limit, not a semantic cap.
    const oversized = Buffer.alloc(WS_MAX_PAYLOAD_BYTES + 1, 0x41);
    client.send(oversized);

    const outcome = await new Promise<{ code?: number; reason?: string; error?: string }>((resolve) => {
      const timer = setTimeout(() => resolve({ error: "timeout awaiting close" }), 8000);
      client.on("close", (code: number, reason: Buffer) => {
        clearTimeout(timer);
        resolve({ code, reason: reason.toString() });
      });
      client.on("error", (error: Error) => {
        clearTimeout(timer);
        resolve({ error: error.message });
      });
    });

    // The connection must die with 1009 (message too big) — via the explicit
    // frame cap under Bun, or maxPayload under Node. An error carrying 1009
    // also counts; a silent acceptance does not.
    const evidence =
      outcome.code === 1009 ||
      (outcome.error ?? "").includes("1009") ||
      (outcome.error ?? "").includes("Max payload");
    expect(evidence).toBeTrue();
    if (outcome.code !== undefined) {
      expect(outcome.code).toBe(1009);
      expect(outcome.reason).toBe("Frame too large");
    }
    client.close();
  });

  it("small frames inside the ceiling are delivered normally", async () => {
    const base = await startWithUpgradeHandler((server, wss) => {
      server.on("upgrade", createLiveUpgradeHandler(wss));
      wss.on("connection", (socket) => {
        socket.on("message", (data: unknown) => {
          socket.send(data as string);
        });
      });
    });

    const client = new WebSocket(`${base}/v1/live?sessionId=echo-test`);
    await new Promise<void>((resolve) => client.on("open", resolve));

    // Sequential request/response exchanges inside the ceiling.
    const roundTrip = (payload: string) =>
      new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`echo never arrived: ${payload}`)), 3000);
        client.once("message", (data: Buffer) => {
          clearTimeout(timer);
          resolve(data.toString());
        });
        client.send(payload);
      });

    const first = await roundTrip(JSON.stringify({ type: "realtime_input", payload: { ok: true } }));
    const second = await roundTrip("ping-payload");
    expect(first).toBe(JSON.stringify({ type: "realtime_input", payload: { ok: true } }));
    expect(second).toBe("ping-payload");

    client.close();
  });

  it("exposes the same ceiling constant from liveUpgrade and limits", () => {
    expect(WS_MAX_PAYLOAD_BYTES).toBe(8 * 1024 * 1024);
    expect(WS_MAX_PAYLOAD_FROM_LIMITS).toBe(WS_MAX_PAYLOAD_BYTES);
  });
});
