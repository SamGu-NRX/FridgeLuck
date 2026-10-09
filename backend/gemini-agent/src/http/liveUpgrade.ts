import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";
import type { WebSocketServer, WebSocket } from "ws";

/**
 * WebSocket transport ceiling owned HERE (this service's wiring): 8 MiB.
 * packet025 owns the smaller semantic message caps that live underneath it.
 * Pairs with `maxPayload` on the WebSocketServer in src/server.ts.
 */
export const WS_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;

export type WebSocketUpgradeHandler = (
  request: IncomingMessage,
  socket: Socket,
  head: Buffer
) => void;

/**
 * The live-session upgrade gate, preserved verbatim from the original
 * src/server.ts wiring: only `/v1/live` upgrades; every other upgrade
 * attempt has its socket destroyed.
 */
export function createLiveUpgradeHandler(wss: WebSocketServer): WebSocketUpgradeHandler {
  return (request: IncomingMessage, socket: Socket, head: Buffer) => {
    if (!request.url?.startsWith("/v1/live")) {
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws: WebSocket) => {
      wss.emit("connection", ws, request);
    });
  };
}

function frameBytes(data: string | Buffer | ArrayBuffer): number {
  return typeof data === "string" ? Buffer.byteLength(data) : data.byteLength;
}

/**
 * Hard transport cap on live-session frames, enforced HERE rather than
 * relying on the WebSocketServer's `maxPayload` alone: Bun's `ws` runtime
 * does not enforce `maxPayload` on received frames, so an oversized frame
 * would otherwise flow to connection handlers untouched. Under Node the
 * `maxPayload` check closes first and this handler never fires; under Bun
 * this is the enforcement that makes the 8 MiB ceiling real. Registered
 * before the session gateway so the connection dies at the transport layer
 * first. This is a TRANSPORT cap only — packet025 owns the smaller semantic
 * message caps.
 */
export function attachTransportFrameCap(wss: WebSocketServer): void {
  wss.on("connection", (socket: WebSocket) => {
    socket.on("message", (data: string | Buffer | ArrayBuffer) => {
      if (frameBytes(data) > WS_MAX_PAYLOAD_BYTES) {
        socket.close(1009, "Frame too large");
      }
    });
  });
}
