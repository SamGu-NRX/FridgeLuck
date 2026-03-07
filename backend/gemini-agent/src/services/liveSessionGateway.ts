import type { IncomingMessage } from "node:http";
import { Modality, type GoogleGenAI, type LiveServerMessage } from "@google/genai";
import type { WebSocketServer } from "ws";
import type WebSocket from "ws";
import type { AppConfig } from "../config.js";

interface LiveClientEnvelope {
  type: "client_content" | "realtime_input" | "tool_response" | "close";
  payload?: Record<string, unknown>;
}

function safeParseEnvelope(raw: string): LiveClientEnvelope | null {
  try {
    const parsed = JSON.parse(raw) as LiveClientEnvelope;
    if (!parsed || typeof parsed !== "object") return null;
    if (!["client_content", "realtime_input", "tool_response", "close"].includes(parsed.type)) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

export function attachLiveSessionGateway(
  wss: WebSocketServer,
  ai: GoogleGenAI,
  config: AppConfig
): void {
  wss.on("connection", (socket: WebSocket, req: IncomingMessage) => {
    if (!req.url?.startsWith("/v1/live")) {
      socket.close(1008, "Unsupported websocket path.");
      return;
    }

    let session: any | undefined;

    const closeSession = () => {
      try {
        session?.close();
      } catch {
        // ignore
      }
      session = undefined;
    };

    void (async () => {
      session = await ai.live.connect({
        model: config.liveModel,
        config: {
          responseModalities: [Modality.TEXT]
        },
        callbacks: {
          onopen: () => {
            socket.send(JSON.stringify({ type: "session_open" }));
          },
          onmessage: (message: LiveServerMessage) => {
            socket.send(JSON.stringify({ type: "server_message", payload: message }));
          },
          onerror: (event: any) => {
            socket.send(
              JSON.stringify({
                type: "session_error",
                payload: { message: event.message ?? "Unknown live session error." }
              })
            );
          },
          onclose: (event: any) => {
            socket.send(
              JSON.stringify({
                type: "session_close",
                payload: { code: event.code, reason: event.reason }
              })
            );
          }
        }
      });
    })().catch((error: unknown) => {
      const message = error instanceof Error ? error.message : "Failed to establish Gemini Live session.";
      socket.send(JSON.stringify({ type: "session_error", payload: { message } }));
      socket.close(1011, "Gemini Live connect failed.");
    });

    socket.on("message", (raw: Buffer) => {
      const envelope = safeParseEnvelope(raw.toString("utf8"));
      if (!envelope) {
        socket.send(
          JSON.stringify({
            type: "client_error",
            payload: { message: "Invalid websocket payload." }
          })
        );
        return;
      }

      if (!session) {
        socket.send(
          JSON.stringify({
            type: "client_error",
            payload: { message: "Live session not initialized yet." }
          })
        );
        return;
      }

      switch (envelope.type) {
        case "client_content":
          session.sendClientContent(envelope.payload ?? {});
          break;
        case "realtime_input":
          session.sendRealtimeInput(envelope.payload ?? {});
          break;
        case "tool_response":
          session.sendToolResponse(envelope.payload ?? {});
          break;
        case "close":
          closeSession();
          socket.close(1000, "Client requested close.");
          break;
      }
    });

    socket.on("close", () => {
      closeSession();
    });

    socket.on("error", () => {
      closeSession();
    });
  });
}
