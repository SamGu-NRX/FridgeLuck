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
import {
  buildToolRegistry,
  dispatchToolCall,
  overlayLeChefTools,
} from "../agent/toolRegistry.js";
import {
  traceConfidenceDecision,
  traceToolCall,
  startTrace,
} from "../observability/tracing.js";
import { guardLiveResponse } from "../observability/responseGuard.js";
import type { LiveSessionStore, StoredIngredientContext } from "../session/liveSessionStore.js";
import { InMemoryFrameHolder } from "./frameCache.js";
import type { CachedCameraFrame } from "./frameCache.js";
import { LeChefRuntime } from "../lechef/runtime.js";
import { LivePhoneExecutor } from "./livePhoneExecutor.js";
import type { ActionReceiptWire, PantrySnapshot, RecipeContext, CookSessionSnapshot } from "../lechef/types.js";
import { parseCookSession, WireParseError } from "../lechef/wire.js";

export { InMemoryFrameHolder, FRAME_TTL_MS, FRAME_CACHE_MAX_SESSIONS } from "./frameCache.js";

/**
 * Live session gateway — the WebSocket surface between the phone and Gemini
 * Live (SPEC §15 live-wiring slice).
 *
 * - Owns the in-process frame cache: camera frame bytes live HERE, TTL- and
   LRU-bounded, never in the store (SPEC §9.1–9.2).
 * - Deletes the session on close and sweeps expired sessions on a timer
 *   (SPEC §9.5): a session doc surviving beyond 24 h is a bug.
 * - Mints session ids server-side; a client-supplied session id is logged as
 *   ignored (SPEC §9.6).
 * - Rejects client `tool_response` frames: client authority is stripped at
 *   the protocol layer (SPEC §9.6).
 * - Binds the LeChef tools (reads over the phone's bounded snapshot,
 *   proposals ROUTED to the phone) per connection.
 */

interface LiveClientEnvelope {
  type:
    | "client_content"
    | "realtime_input"
    | "session_context"
    | "proposal_receipt"
    | "close";
  payload?: Record<string, unknown>;
}

const CLIENT_ENVELOPE_TYPES: readonly LiveClientEnvelope["type"][] = [
  "client_content",
  "realtime_input",
  "session_context",
  "proposal_receipt",
  "close"
];

function safeParseEnvelope(raw: string): LiveClientEnvelope | null {
  try {
    const parsed = JSON.parse(raw) as LiveClientEnvelope;
    if (!parsed || typeof parsed !== "object") return null;
    if (!CLIENT_ENVELOPE_TYPES.includes(parsed.type)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/** TTL sweep cadence: stale sessions are deleted even if the client vanished. */
const TTL_SWEEP_INTERVAL_MS = 5 * 60 * 1000;
// Defensive defaults; no production traffic measurement backs these values yet.
const LIVE_IDLE_TIMEOUT_MS = 5 * 60 * 1000;
export const MAX_FRAME_BYTES = 2 * 1024 * 1024;

/** The bounded snapshot is bounded: at most this many ingredient lines (SPEC §9.6). */
const BOUNDED_SNAPSHOT_MAX_LINES = 50;

/**
 * Trim client-supplied ingredient lines to ids + coarse quantity text —
 * never the pantry, never exact grams (SPEC §9.6).
 */
function trimBoundedIngredients(
  lines: unknown,
): StoredIngredientContext[] {
  if (!Array.isArray(lines)) return [];
  return lines.slice(0, BOUNDED_SNAPSHOT_MAX_LINES).map((line) => {
    const l = line as { name?: unknown; confidence?: unknown; quantityGrams?: unknown };
    const trimmed: StoredIngredientContext = {
      name: typeof l.name === "string" ? l.name : ""
    };
    if (typeof l.quantityGrams === "number" && Number.isFinite(l.quantityGrams)) {
      // Coarse to 10 g — the store holds a hint, not a measurement.
      trimmed.quantityGrams = Math.round(l.quantityGrams / 10) * 10;
    }
    return trimmed;
  });
}

export function attachLiveSessionGateway(
  wss: WebSocketServer,
  ai: GoogleGenAI,
  config: AppConfig,
  ledger: InventoryLedger,
  confidenceService: ConfidenceService,
  sessionStore: LiveSessionStore,
  /** Injectable for the e2e boot; production news its own holder. */
  frames?: InMemoryFrameHolder,
): void {
  const baseRegistry = buildToolRegistry();
  const toolDeps = { ai, config, ledger, confidenceService, sessionStore, frames: frames ?? new InMemoryFrameHolder() };

  // TTL sweep: expired session docs are deleted even when the client never
  // said goodbye (SPEC §9.5). Expiry enforcement in reads remains the
  // access-control boundary; this sweep is the janitor.
  const ttlSweep = setInterval(() => {
    void sessionStore.sweepExpired().catch((err: unknown) => {
      console.error(
        JSON.stringify({
          severity: "ERROR",
          message: "live_session_ttl_sweep_failed",
          errMsg: err instanceof Error ? err.message : "sweep failed",
        }),
      );
    });
  }, TTL_SWEEP_INTERVAL_MS);
  if (ttlSweep.unref) ttlSweep.unref();

  wss.on("connection", (socket: WebSocket, req: IncomingMessage) => {
    if (!req.url?.startsWith("/v1/live")) {
      socket.close(1008, "Unsupported websocket path.");
      return;
    }

    // Session ids are minted SERVER-side (SPEC §9.6): a client-supplied id is
    // logged as ignored, never honoured.
    let requestedSessionId: string | null = null;
    try {
      requestedSessionId = new URL(req.url, "http://localhost").searchParams.get(
        "sessionId",
      );
    } catch {
      requestedSessionId = null;
    }
    const sessionId = globalThis.crypto.randomUUID();
    if (requestedSessionId) {
      console.log(
        JSON.stringify({
          severity: "WARNING",
          message: "live_session_client_session_id_ignored",
          sessionId,
        }),
      );
    }
    console.log(
      JSON.stringify({
        severity: "INFO",
        message: "live_session_connecting",
        sessionId,
      }),
    );
    void sessionStore.ensureSession(sessionId);

    // The per-session phone mirror and the LeChef tools bound to it.
    const phone = new LivePhoneExecutor((envelope) => {
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify(envelope));
      }
    });
    const lechefRuntime = new LeChefRuntime({ phone, clock: { nowMs: () => Date.now() } });
    const sessionRegistry = new Map(baseRegistry);
    overlayLeChefTools(sessionRegistry, lechefRuntime, phone);

    type LiveSession = Awaited<ReturnType<typeof ai.live.connect>>;
    type ToolResponsePayload = Parameters<LiveSession["sendToolResponse"]>[0];
    let session: LiveSession | undefined;

    let cleanedUp = false;
    let idleTimer: ReturnType<typeof setTimeout> | undefined;
    const resetIdleTimer = () => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        socket.close(1000, "Live session idle timeout.");
      }, LIVE_IDLE_TIMEOUT_MS);
    };
    resetIdleTimer();
    const cleanup = () => {
      if (idleTimer) clearTimeout(idleTimer);
      if (cleanedUp) return;
      cleanedUp = true;
      // NOTHING outlives the session (SPEC §9): the store doc is deleted, the
      // frame bytes are dropped, the phone mirror and its pending proposals
      // and receipts die with the connection.
      phone.close();
      toolDeps.frames.evict(sessionId);
      void sessionStore
        .deleteSession(sessionId)
        .catch((err: unknown) => {
          console.error(
            JSON.stringify({
              severity: "ERROR",
              message: "live_session_delete_failed",
              errMsg: err instanceof Error ? err.message : "delete failed",
              sessionId,
            }),
          );
        });
    };

    const closeSession = () => {
      const liveSession = session;
      session = undefined;
      try {
        liveSession?.close();
      } catch {
        /* no-op */
      }
    };

    void (async () => {
      const connectedSession = await ai.live.connect({
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
                    sessionRegistry,
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
      session = connectedSession;
      // The phone can disconnect while the paid Live connection is pending.
      if (cleanedUp || socket.readyState !== socket.OPEN) closeSession();
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
      resetIdleTimer();
      if (!envelope) {
        socket.send(
          JSON.stringify({
            type: "client_error",
            payload: { message: "Invalid websocket payload." },
          }),
        );
        return;
      }

      // Client authority is stripped at the protocol layer (SPEC §9.6): a
      // client `tool_response` frame is rejected, never relayed to the model.
      if (envelope.type === "proposal_receipt") {
        const payload = envelope.payload as
          | { receipt?: ActionReceiptWire }
          | undefined;
        if (payload?.receipt?.proposalID) {
          phone.resolveProposal(payload.receipt);
        } else {
          socket.send(
            JSON.stringify({
              type: "client_error",
              payload: { message: "proposal_receipt requires a receipt." },
            }),
          );
        }
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
          // The user's words are relayed to the model and NOT persisted:
          // the backend keeps no transcript (SPEC §9).
          session.sendClientContent(envelope.payload ?? {});
          break;
        case "realtime_input":
          if (!recordLatestFrame(toolDeps.frames, sessionStore, sessionId, envelope.payload, () => cleanedUp)) {
            socket.send(JSON.stringify({
              type: "client_error",
              payload: { message: "Camera frame exceeds the per-frame size limit." },
            }));
            return;
          }
          session.sendRealtimeInput(envelope.payload ?? {});
          break;
        case "session_context":
          applySessionContext(
            sessionStore,
            phone,
            sessionId,
            envelope.payload,
            () => cleanedUp,
            (message) =>
              socket.send(JSON.stringify({ type: "client_error", payload: { message } })),
          );
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
      cleanup();
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
      cleanup();
    });
  });
}

/**
 * The phone's once-per-session bounded snapshot: bounded cook context for the
 * LeChef reads, trimmed ingredient lines for the store. `latestConfidence`
 * from the client is REJECTED — the exact-mode confidence gate is computed
 * server-side only (SPEC §9.6).
 *
 * A snapshot must carry a valid cookSession (parseCookSession): the
 * substitution, plan and proposal screens read its eaters. An invalid one is
 * refused whole with a client_error, and the phone executor fails eater reads
 * until a valid snapshot replaces it.
 */
function applySessionContext(
  sessionStore: LiveSessionStore,
  phone: LivePhoneExecutor,
  sessionId: string,
  payload: Record<string, unknown> | undefined,
  isClosed: () => boolean,
  sendClientError: (message: string) => void,
): void {
  const pantrySnapshot = payload?.pantrySnapshot as PantrySnapshot | undefined;
  const recipes = payload?.recipes as RecipeContext[] | undefined;
  const revision =
    typeof payload?.revision === "number" && Number.isFinite(payload.revision)
      ? payload.revision
      : typeof pantrySnapshot?.revision === "number"
        ? pantrySnapshot.revision
        : 1;

  if (pantrySnapshot !== undefined || payload?.cookSession !== undefined || recipes !== undefined) {
    let cookSession: CookSessionSnapshot;
    try {
      cookSession = parseCookSession(payload?.cookSession);
    } catch (err) {
      if (!(err instanceof WireParseError)) throw err;
      const reason = err.issues
        .map((i) => `cookSession${i.path.slice(1)}: ${i.problem}`)
        .join("; ");
      phone.rejectSnapshot(reason);
      // Issue paths only: restriction values are health data and stay out of logs.
      console.warn(
        JSON.stringify({
          severity: "WARNING",
          message: "live_session_context_rejected",
          sessionId,
          issuePaths: err.issues.map((i) => i.path),
        }),
      );
      sendClientError(`session_context rejected: ${reason}`);
      return;
    }
    phone.setSnapshot({
      pantry: pantrySnapshot ?? { revision: 0, items: [] },
      cookSession,
      recipes: recipes ?? [],
      revision
    });
  }

  if (isClosed()) return;
  const patch: import("../session/liveSessionStore.js").LiveSessionContextPatch = {};
  if (payload && Object.prototype.hasOwnProperty.call(payload, "selectedRecipe")) {
    patch.selectedRecipe = payload.selectedRecipe as import("../session/liveSessionStore.js").StoredRecipeContext;
  }
  if (payload && Object.prototype.hasOwnProperty.call(payload, "confirmedIngredients")) {
    patch.confirmedIngredients = trimBoundedIngredients(payload.confirmedIngredients);
  }
  void sessionStore.patchContext(sessionId, patch).catch((error: unknown) => {
    console.error(JSON.stringify({
      severity: "ERROR",
      message: "live_session_context_write_failed",
      sessionId,
      errMsg: error instanceof Error ? error.message : "store write failed",
    }));
  });
}

/**
 * Frames land in the in-process cache (TTL from the SERVER receipt time) and
 * only their METADATA reaches the store — the bytes never persist (SPEC
 * §9.1–9.2).
 */
function recordLatestFrame(
  frames: InMemoryFrameHolder,
  sessionStore: LiveSessionStore,
  sessionId: string,
  payload?: Record<string, unknown>,
  isClosed: () => boolean = () => false,
): boolean {
  const candidates = [payload?.media, payload?.video];
  for (const candidate of candidates) {
    const frame = candidate as { mimeType?: string; data?: string } | undefined;
    if (frame?.mimeType?.startsWith("image/") && frame.data) {
      const sizeBytes = Buffer.byteLength(frame.data, "base64");
      if (sizeBytes > MAX_FRAME_BYTES) return false;
      if (isClosed()) return false;
      const cached: CachedCameraFrame = {
        mimeType: frame.mimeType,
        dataBase64: frame.data,
        receivedAtMs: Date.now()
      };
      frames.record(sessionId, cached);
      void sessionStore
        .recordFrameMetadata(sessionId, {
          mimeType: cached.mimeType,
          receivedAt: new Date(cached.receivedAtMs).toISOString(),
          sizeBytes: Buffer.byteLength(cached.dataBase64, "base64"),
        })
        .catch(() => {
          /* metadata is an audit line; a failed write must not drop the session */
        });
      return true;
    }
  }
  return true;
}
