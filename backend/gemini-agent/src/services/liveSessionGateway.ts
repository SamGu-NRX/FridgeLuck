import type { IncomingMessage } from "node:http";
import {
  Modality,
  type GoogleGenAI,
  type LiveServerMessage,
} from "@google/genai";
import type { WebSocketServer } from "ws";
import type WebSocket from "ws";
import type { AppConfig } from "../config.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";
import { SYSTEM_PROMPT, TOOL_DECLARATIONS } from "../agent/systemPrompt.js";
import { buildToolRegistry, dispatchToolCall } from "../agent/toolRegistry.js";
import {
  traceConfidenceDecision,
  traceToolCall,
  startTrace,
} from "../observability/tracing.js";
import { guardLiveResponse } from "../observability/responseGuard.js";
import type {
  LiveSessionStore,
  StoredRecipeContext,
  StoredIngredientContext,
} from "../session/liveSessionStore.js";

interface LiveClientEnvelope {
  type:
    | "client_content"
    | "realtime_input"
    | "tool_response"
    | "session_context"
    | "close";
  payload?: Record<string, unknown>;
}

function safeParseEnvelope(raw: string): LiveClientEnvelope | null {
  try {
    const parsed = JSON.parse(raw) as LiveClientEnvelope;
    if (!parsed || typeof parsed !== "object") return null;
    if (
      ![
        "client_content",
        "realtime_input",
        "tool_response",
        "session_context",
        "close",
      ].includes(parsed.type)
    ) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

function extractSessionId(req: IncomingMessage): string {
  try {
    const url = new URL(req.url ?? "/", "http://localhost");
    return url.searchParams.get("sessionId") ?? globalThis.crypto.randomUUID();
  } catch {
    return globalThis.crypto.randomUUID();
  }
}

export function attachLiveSessionGateway(
  wss: WebSocketServer,
  ai: GoogleGenAI,
  config: AppConfig,
  ledger: InventoryLedger,
  confidenceService: ConfidenceService,
  sessionStore: LiveSessionStore,
): void {
  const toolRegistry = buildToolRegistry();
  const toolDeps = { ai, config, ledger, confidenceService, sessionStore };

  wss.on("connection", (socket: WebSocket, req: IncomingMessage) => {
    if (!req.url?.startsWith("/v1/live")) {
      socket.close(1008, "Unsupported websocket path.");
      return;
    }

    const sessionId = extractSessionId(req);
    console.log(
      JSON.stringify({
        severity: "INFO",
        message: "live_session_connecting",
        sessionId,
      }),
    );
    void sessionStore.ensureSession(sessionId);

    type LiveSession = Awaited<ReturnType<typeof ai.live.connect>>;
    type ToolResponsePayload = Parameters<LiveSession["sendToolResponse"]>[0];
    let session: LiveSession | undefined;

    const closeSession = () => {
      try {
        session?.close();
      } catch {
        /* no-op */
      }
      session = undefined;
    };

    void (async () => {
      session = await ai.live.connect({
        model: config.liveModel,
        config: {
          systemInstruction: SYSTEM_PROMPT,
          tools: TOOL_DECLARATIONS,
          responseModalities: [Modality.TEXT],
        },
        callbacks: {
          onopen: () => {
            socket.send(JSON.stringify({ type: "session_open", sessionId }));
            console.log(
              JSON.stringify({
                severity: "INFO",
                message: "live_session_open",
                sessionId,
              }),
            );
          },

          onmessage: (message: LiveServerMessage) => {
            const toolCalls = (
              message as LiveServerMessage & {
                toolCall?: {
                  functionCalls?: Array<{
                    id: string;
                    name: string;
                    args?: Record<string, unknown>;
                  }>;
                };
              }
            ).toolCall;
            const fnCalls = toolCalls?.functionCalls;
            if (fnCalls?.length) {
              void (async () => {
                for (const fnCall of fnCalls) {
                  const tr = startTrace(fnCall.name, sessionId, fnCall.args);

                  const { result, error } = await dispatchToolCall(
                    fnCall.name,
                    fnCall.args ?? {},
                    toolRegistry,
                    toolDeps,
                    sessionId,
                  );

                  const resultObj = result as Record<string, unknown> | null;
                  const assessment = resultObj?.confidence_assessment as
                    | ConfidenceAssessResponse
                    | undefined;

                  if (assessment) {
                    traceConfidenceDecision(assessment, fnCall.name, sessionId);
                    await sessionStore.recordLatestConfidence(
                      sessionId,
                      assessment,
                    );
                    if (
                      assessment.mode === "estimate_only" &&
                      !assessment.deterministicReady
                    ) {
                      resultObj!._policy_note =
                        "estimate_only: do not present exact macros or exact gram amounts.";
                    }
                  }

                  traceToolCall(
                    tr.build(!error, {
                      confidenceMode: assessment?.mode,
                      confidenceScore: assessment?.overallScore,
                      errorMessage: error,
                    }),
                  );

                  session?.sendToolResponse({
                    functionResponses: [
                      {
                        id: fnCall.id,
                        name: fnCall.name,
                        response: error ? { error } : { output: result },
                      },
                    ],
                  });
                }
              })().catch((err: unknown) => {
                const message =
                  err instanceof Error ? err.message : "Tool dispatch error.";
                console.error(
                  JSON.stringify({ severity: "ERROR", message, sessionId }),
                );
              });

              return;
            }

            void (async () => {
              const liveSession = await sessionStore.getSession(sessionId);
              const guarded = guardLiveResponse(
                message as unknown as Record<string, unknown>,
                liveSession.latestConfidence,
              );
              socket.send(
                JSON.stringify({ type: "server_message", payload: guarded }),
              );
            })().catch(() => {
              socket.send(
                JSON.stringify({ type: "server_message", payload: message }),
              );
            });
          },

          onerror: (event: { message?: string }) => {
            const errMsg = event.message ?? "Unknown live session error.";
            console.error(
              JSON.stringify({
                severity: "ERROR",
                message: "live_session_error",
                errMsg,
                sessionId,
              }),
            );
            socket.send(
              JSON.stringify({
                type: "session_error",
                payload: { message: errMsg },
              }),
            );
          },

          onclose: (event: { code?: number; reason?: string }) => {
            console.log(
              JSON.stringify({
                severity: "INFO",
                message: "live_session_close",
                code: event.code,
                reason: event.reason,
                sessionId,
              }),
            );
            socket.send(
              JSON.stringify({
                type: "session_close",
                payload: { code: event.code, reason: event.reason },
              }),
            );
          },
        },
      });
    })().catch((error: unknown) => {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to establish Gemini Live session.";
      socket.send(
        JSON.stringify({ type: "session_error", payload: { message } }),
      );
      socket.close(1011, "Gemini Live connect failed.");
    });

    socket.on("message", (raw: Buffer) => {
      const envelope = safeParseEnvelope(raw.toString("utf8"));
      if (!envelope) {
        socket.send(
          JSON.stringify({
            type: "client_error",
            payload: { message: "Invalid websocket payload." },
          }),
        );
        return;
      }

      if (!session) {
        socket.send(
          JSON.stringify({
            type: "client_error",
            payload: { message: "Live session not initialized yet." },
          }),
        );
        return;
      }

      switch (envelope.type) {
        case "client_content":
          void recordClientText(sessionStore, sessionId, envelope.payload);
          session.sendClientContent(envelope.payload ?? {});
          break;
        case "realtime_input":
          void recordLatestFrame(sessionStore, sessionId, envelope.payload);
          session.sendRealtimeInput(envelope.payload ?? {});
          break;
        case "tool_response":
          session.sendToolResponse(
            (envelope.payload ?? {}) as unknown as ToolResponsePayload,
          );
          break;
        case "session_context":
          void sessionStore.patchContext(sessionId, {
            selectedRecipe: envelope.payload?.selectedRecipe as
              | StoredRecipeContext
              | undefined,
            confirmedIngredients: envelope.payload?.confirmedIngredients as
              | StoredIngredientContext[]
              | undefined,
            latestConfidence: envelope.payload?.latestConfidence as
              | ConfidenceAssessResponse
              | undefined,
          });
          break;
        case "close":
          closeSession();
          socket.close(1000, "Client requested close.");
          break;
      }
    });

    socket.on("close", () => {
      console.log(
        JSON.stringify({
          severity: "INFO",
          message: "websocket_closed",
          sessionId,
        }),
      );
      closeSession();
    });

    socket.on("error", (err: Error) => {
      console.error(
        JSON.stringify({
          severity: "ERROR",
          message: "websocket_error",
          error: err.message,
          sessionId,
        }),
      );
      closeSession();
    });
  });
}

async function recordClientText(
  sessionStore: LiveSessionStore,
  sessionId: string,
  payload?: Record<string, unknown>,
): Promise<void> {
  const turns = payload?.turns as
    | Array<{ parts?: Array<{ text?: string }> }>
    | undefined;
  const text = turns
    ?.flatMap((turn) => turn.parts ?? [])
    .map((part) => part.text ?? "")
    .join(" ")
    .trim();
  if (text) {
    await sessionStore.recordUserMessage(sessionId, text);
  }
}

async function recordLatestFrame(
  sessionStore: LiveSessionStore,
  sessionId: string,
  payload?: Record<string, unknown>,
): Promise<void> {
  const candidates = [payload?.media, payload?.video];
  for (const candidate of candidates) {
    const frame = candidate as { mimeType?: string; data?: string } | undefined;
    if (frame?.mimeType?.startsWith("image/") && frame.data) {
      await sessionStore.recordLatestFrame(sessionId, {
        mimeType: frame.mimeType,
        dataBase64: frame.data,
        updatedAt: new Date().toISOString(),
      });
      return;
    }
  }
}
