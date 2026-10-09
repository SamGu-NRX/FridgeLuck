import { randomUUID } from "node:crypto";
import type { IncomingMessage } from "node:http";
import {
  Modality,
  type GoogleGenAI,
  type LiveServerMessage,
} from "@google/genai";
import type { WebSocketServer } from "ws";
import type WebSocket from "ws";
import type { AppConfig } from "../config.js";
import type { SessionLedgers } from "../inventory/sessionLedgers.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";
import { SYSTEM_PROMPT, TOOL_DECLARATIONS } from "../agent/systemPrompt.js";
import {
  applyApprovedProposal,
  buildToolRegistry,
  dispatchToolCall,
  type ToolDeps,
} from "../agent/toolRegistry.js";
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
import type { MutationProposalStore } from "../authority/mutationAuthority.js";

// Live session gateway.
//
// Authority and abuse boundaries enforced HERE (structural, not prompt-based):
//
// 1. Session ids are SERVER-MINTED per connection. A client-supplied
//    `sessionId` query param is ignored (and logged) — sessions cannot
//    attach to another client's state.
// 2. Inventory mutations are propose → confirm. The model's tool call only
//    registers a pending proposal; `confirm_mutation` / `cancel_mutation`
//    envelopes — which only the trusted client can send on its own
//    connection — resolve it. Execution uses the proposal id as the ledger
//    idempotency key, so repeated confirms apply at most once.
// 3. `tool_response` is NOT accepted from clients: every declared tool
//    executes server-side, and a client-supplied tool response would be a
//    forged-source channel (fake tool output, fake confidence mode).
// 4. `session_context` accepts recipe/ingredient context from the phone but
//    NEVER `latestConfidence` — a client-pushed confidence assessment would
//    forge the exact-mode gate that guards model responses. Confidence
//    enters session state only via the server's own tool execution.
// 5. Bounded usage: concurrent session cap, per-connection envelope budget,
//    and a session lifetime cap. Cost containment, not authentication.
// 6. Client-facing error payloads are stable codes. Provider error strings,
//    close reasons, and raw upstream messages are logged server-side only;
//    a response-guard failure withholds the upstream message entirely.

type ClientEnvelopeType =
  | "client_content"
  | "realtime_input"
  | "session_context"
  | "confirm_mutation"
  | "cancel_mutation"
  | "close";

const CLIENT_ENVELOPE_TYPES: readonly ClientEnvelopeType[] = [
  "client_content",
  "realtime_input",
  "session_context",
  "confirm_mutation",
  "cancel_mutation",
  "close"
];

function safeParseEnvelope(raw: string): {
  type: ClientEnvelopeType;
  payload?: Record<string, unknown>;
} | null {
  try {
    const parsed = JSON.parse(raw) as { type?: unknown; payload?: unknown };
    if (!parsed || typeof parsed !== "object") return null;
    if (
      typeof parsed.type !== "string" ||
      !CLIENT_ENVELOPE_TYPES.includes(parsed.type as ClientEnvelopeType)
    ) {
      return null;
    }
    return {
      type: parsed.type as ClientEnvelopeType,
      ...(parsed.payload !== undefined &&
      typeof parsed.payload === "object" &&
      parsed.payload !== null
        ? { payload: parsed.payload as Record<string, unknown> }
        : {})
    };
  } catch {
    return null;
  }
}

/**
 * Server mints every session id. Any client-supplied sessionId is ignored —
 * its only trace is a log line, so attach attempts are observable.
 */
function mintSessionId(req: IncomingMessage): string {
  try {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.searchParams.get("sessionId")) {
      console.log(
        JSON.stringify({
          severity: "WARNING",
          message:
            "live_session_client_sessionid_ignored: sessions are server-minted"
        })
      );
    }
  } catch {
    /* unparseable url: nothing to log, session still minted */
  }
  return randomUUID();
}

// ─── session_context narrowing ────────────────────────────────────────────────

const CONTEXT_TITLE_MAX_CHARS = 200;
const CONTEXT_INSTRUCTIONS_MAX_CHARS = 10_000;
const CONTEXT_INGREDIENTS_MAX_COUNT = 32;
const CONTEXT_INGREDIENT_NAME_MAX_CHARS = 120;
const CONTEXT_CONFIRMED_MAX_COUNT = 64;

function sanitizeString(value: unknown, maxChars: number): string | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  return value.length <= maxChars ? value : value.slice(0, maxChars);
}

/**
 * Bounds client-supplied recipe context. Invalid fields are DROPPED, not
 * rejected — the phone's context is advisory; the ledger stays authoritative.
 */
function sanitizeRecipeContext(raw: unknown): StoredRecipeContext | undefined {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return undefined;
  }
  const entry = raw as Record<string, unknown>;
  const title = sanitizeString(entry.title, CONTEXT_TITLE_MAX_CHARS);
  if (!title) return undefined;

  const context: Record<string, unknown> = { title };
  const instructions = sanitizeString(
    entry.instructions,
    CONTEXT_INSTRUCTIONS_MAX_CHARS
  );
  if (instructions !== undefined) context.instructions = instructions;

  if (Array.isArray(entry.ingredients)) {
    const names = entry.ingredients
      .slice(0, CONTEXT_INGREDIENTS_MAX_COUNT)
      .map((item) => sanitizeString(item, CONTEXT_INGREDIENT_NAME_MAX_CHARS))
      .filter((name): name is string => name !== undefined);
    if (names.length > 0) context.ingredients = names;
  }
  return context as unknown as StoredRecipeContext;
}

function sanitizeConfirmedIngredients(
  raw: unknown
): StoredIngredientContext[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: StoredIngredientContext[] = [];
  for (const item of raw.slice(0, CONTEXT_CONFIRMED_MAX_COUNT)) {
    if (typeof item !== "object" || item === null || Array.isArray(item))
      continue;
    const entry = item as Record<string, unknown>;
    const name = sanitizeString(entry.name, CONTEXT_INGREDIENT_NAME_MAX_CHARS);
    if (!name) continue;
    out.push({ name } as unknown as StoredIngredientContext);
  }
  return out.length > 0 ? out : undefined;
}

// ─── gateway attachment ──────────────────────────────────────────────────────

export interface LiveSessionGatewayDeps {
  /** Model client; null = fail-safe mode: connections close model_unavailable. */
  ai: GoogleGenAI | null;
  config: AppConfig;
  confidenceService: ConfidenceService;
  sessionStore: LiveSessionStore;
  ledgers: SessionLedgers;
  proposals: MutationProposalStore;
}

type LiveModelSession = Awaited<ReturnType<GoogleGenAI["live"]["connect"]>>;

export function attachLiveSessionGateway(
  wss: WebSocketServer,
  deps: LiveSessionGatewayDeps
): void {
  const { ai, config, confidenceService, sessionStore, ledgers, proposals } =
    deps;
  const toolRegistry = buildToolRegistry();
  const toolDeps: ToolDeps = {
    ai,
    config,
    ledgers,
    confidenceService,
    sessionStore,
    proposals
  };
  let activeSessions = 0;

  wss.on("connection", (socket: WebSocket, req: IncomingMessage) => {
    if (!req.url?.startsWith("/v1/live")) {
      socket.close(1008, "Unsupported websocket path.");
      return;
    }

    if (activeSessions >= config.maxLiveSessions) {
      socket.close(1013, "Session capacity reached.");
      return;
    }
    activeSessions += 1;

    const sessionId = mintSessionId(req);
    console.log(
      JSON.stringify({
        severity: "INFO",
        message: "live_session_connecting",
        sessionId
      })
    );
    void sessionStore.ensureSession(sessionId);

    // Per-connection envelope budget: cost containment for forwarding
    // client audio/video/text upstream. Refill happens on a minute timer.
    let budgetUsed = 0;
    const budgetTimer = setInterval(() => {
      budgetUsed = 0;
    }, 60_000);

    let session: LiveModelSession | undefined;

    const closeSession = () => {
      try {
        session?.close();
      } catch {
        /* no-op */
      }
      session = undefined;
    };

    // Session lifetime cap: the model session and the socket both close
    // when the cap elapses, with the client seeing a normal close.
    const lifetimeTimer = setTimeout(() => {
      if (socket.readyState === socket.OPEN) {
        socket.send(
          JSON.stringify({
            type: "session_close",
            payload: { code: 1000, reason: "session_expired" }
          })
        );
        socket.close(1000, "Session expired.");
      }
      closeSession();
    }, config.maxSessionSeconds * 1000);

    const cleanupConnection = () => {
      clearInterval(budgetTimer);
      clearTimeout(lifetimeTimer);
      closeSession();
      activeSessions = Math.max(0, activeSessions - 1);
    };

    if (!ai) {
      // Fail-safe mode: no credentials, no live session. Stable client code;
      // nothing about the deployment's config leaks into the payload.
      console.log(
        JSON.stringify({
          severity: "WARNING",
          message: "live_session_refused_model_unavailable",
          sessionId
        })
      );
      socket.send(
        JSON.stringify({
          type: "session_error",
          payload: { message: "model_unavailable" }
        })
      );
      socket.close(1013, "Model unavailable.");
      cleanupConnection();
      return;
    }

    void (async () => {
      session = await ai.live.connect({
        model: config.liveModel,
        config: {
          systemInstruction: SYSTEM_PROMPT,
          tools: TOOL_DECLARATIONS,
          responseModalities: [Modality.TEXT]
        },
        callbacks: {
          onopen: () => {
            socket.send(JSON.stringify({ type: "session_open", sessionId }));
            console.log(
              JSON.stringify({
                severity: "INFO",
                message: "live_session_open",
                sessionId
              })
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
                    sessionId
                  );

                  const resultObj = result as Record<string, unknown> | null;
                  const assessment = resultObj?.confidence_assessment as
                    | ConfidenceAssessResponse
                    | undefined;

                  if (assessment) {
                    traceConfidenceDecision(assessment, fnCall.name, sessionId);
                    await sessionStore.recordLatestConfidence(
                      sessionId,
                      assessment
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
                      errorMessage: error
                    })
                  );

                  session?.sendToolResponse({
                    functionResponses: [
                      {
                        id: fnCall.id,
                        name: fnCall.name,
                        response: error ? { error } : { output: result }
                      }
                    ]
                  });
                }
              })().catch((err: unknown) => {
                console.error(
                  JSON.stringify({
                    severity: "ERROR",
                    message: "tool_dispatch_loop_failed",
                    errorName: err instanceof Error ? err.name : typeof err,
                    sessionId
                  })
                );
              });

              return;
            }

            void (async () => {
              const liveSession = await sessionStore.getSession(sessionId);
              const guarded = guardLiveResponse(
                message as unknown as Record<string, unknown>,
                liveSession.latestConfidence
              );
              socket.send(
                JSON.stringify({ type: "server_message", payload: guarded })
              );
            })().catch((guardError: unknown) => {
              // Guard/session-store failure: WITHHOLD the upstream message.
              // Forwarding it raw would bypass the lexical confidence guard —
              // the bypass the earlier design left open in this exact catch.
              console.error(
                JSON.stringify({
                  severity: "ERROR",
                  message: "live_response_guard_failed",
                  errorName:
                    guardError instanceof Error
                      ? guardError.name
                      : typeof guardError,
                  sessionId
                })
              );
              if (socket.readyState === socket.OPEN) {
                socket.send(
                  JSON.stringify({
                    type: "session_error",
                    payload: { message: "response_guard_failed" }
                  })
                );
              }
            });
          },

          onerror: (event: { message?: string }) => {
            // Provider error text stays server-side; the client gets a
            // stable code only.
            console.error(
              JSON.stringify({
                severity: "ERROR",
                message: "live_session_error",
                errMsg: event.message ?? "Unknown live session error.",
                sessionId
              })
            );
            if (socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({
                  type: "session_error",
                  payload: { message: "live_provider_error" }
                })
              );
            }
          },

          onclose: (event: { code?: number; reason?: string }) => {
            // Close reasons can carry provider detail; code only for the
            // client, reason to server logs.
            console.log(
              JSON.stringify({
                severity: "INFO",
                message: "live_session_close",
                code: event.code,
                reason: event.reason,
                sessionId
              })
            );
            if (socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({
                  type: "session_close",
                  payload: { code: event.code }
                })
              );
            }
          }
        }
      });
    })().catch((error: unknown) => {
      console.error(
        JSON.stringify({
          severity: "ERROR",
          message: "live_connect_failed",
          errorName: error instanceof Error ? error.name : typeof error,
          sessionId
        })
      );
      if (socket.readyState === socket.OPEN) {
        socket.send(
          JSON.stringify({
            type: "session_error",
            payload: { message: "live_connect_failed" }
          })
        );
        socket.close(1011, "Gemini Live connect failed.");
      }
      cleanupConnection();
    });

    const sendMutationResult = (payload: Record<string, unknown>) => {
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify({ type: "mutation_result", payload }));
      }
    };

    const resolveProposal = async (
      proposalId: unknown,
      action: "confirm" | "cancel"
    ): Promise<void> => {
      if (typeof proposalId !== "string" || proposalId.length === 0) {
        sendMutationResult({
          status: "rejected",
          reason: "unknown_proposal",
          proposalId: null
        });
        return;
      }

      const outcome =
        action === "confirm"
          ? proposals.confirm(sessionId, proposalId)
          : proposals.cancel(sessionId, proposalId);

      if (!outcome.ok) {
        sendMutationResult({
          status: "rejected",
          reason: outcome.reason,
          proposalId
        });
        return;
      }

      if (action === "cancel") {
        sendMutationResult({
          status: "cancelled",
          proposalId,
          operation: outcome.proposal.operation,
          itemCount: outcome.proposal.items.length
        });
        return;
      }

      // Approved. Execute once — the proposal id is the ledger idempotency
      // key — then audit against the session-scoped ledger.
      try {
        const result = applyApprovedProposal(
          outcome.proposal,
          ledgers.get(sessionId)
        );
        await sessionStore.appendMutationAudit(sessionId, {
          operation: outcome.proposal.operation,
          idempotencyKey: outcome.proposal.id,
          itemCount: outcome.proposal.items.length,
          committed: result.committed,
          createdAt: new Date().toISOString()
        });
        sendMutationResult({
          status: "executed",
          proposalId,
          operation: outcome.proposal.operation,
          itemCount: outcome.proposal.items.length,
          committed: result.committed
        });
      } catch (err) {
        console.error(
          JSON.stringify({
            severity: "ERROR",
            message: "mutation_apply_failed",
            errorName: err instanceof Error ? err.name : typeof err,
            sessionId
          })
        );
        sendMutationResult({
          status: "failed",
          reason: "ledger_error",
          proposalId
        });
      }
    };

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

      // Envelope budget: applies to forwarding types only. Confirm/cancel
      // stay cheap and available — they are the user's authority act.
      if (
        envelope.type === "client_content" ||
        envelope.type === "realtime_input" ||
        envelope.type === "session_context"
      ) {
        budgetUsed += 1;
        if (budgetUsed > config.liveClientMessagesPerMinute) {
          socket.send(
            JSON.stringify({
              type: "client_error",
              payload: { message: "message_budget_exceeded" }
            })
          );
          return;
        }
      }

      switch (envelope.type) {
        case "client_content":
          if (!session) {
            socket.send(
              JSON.stringify({
                type: "client_error",
                payload: { message: "Live session not initialized yet." }
              })
            );
            return;
          }
          void recordClientText(sessionStore, sessionId, envelope.payload);
          session.sendClientContent(envelope.payload ?? {});
          break;
        case "realtime_input":
          if (!session) {
            socket.send(
              JSON.stringify({
                type: "client_error",
                payload: { message: "Live session not initialized yet." }
              })
            );
            return;
          }
          void recordLatestFrame(sessionStore, sessionId, envelope.payload);
          session.sendRealtimeInput(envelope.payload ?? {});
          break;
        case "session_context":
          // latestConfidence is deliberately NOT accepted here: confidence
          // assessments enter session state only via server tool execution.
          if (envelope.payload?.latestConfidence !== undefined) {
            socket.send(
              JSON.stringify({
                type: "client_error",
                payload: { message: "latestConfidence_not_accepted" }
              })
            );
          }
          void sessionStore.patchContext(sessionId, {
            selectedRecipe: sanitizeRecipeContext(
              envelope.payload?.selectedRecipe
            ),
            confirmedIngredients: sanitizeConfirmedIngredients(
              envelope.payload?.confirmedIngredients
            )
          });
          break;
        case "confirm_mutation":
          void resolveProposal(envelope.payload?.proposalId, "confirm");
          break;
        case "cancel_mutation":
          void resolveProposal(envelope.payload?.proposalId, "cancel");
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
          sessionId
        })
      );
      cleanupConnection();
    });

    socket.on("error", (err: Error) => {
      console.error(
        JSON.stringify({
          severity: "ERROR",
          message: "websocket_error",
          error: err.message,
          sessionId
        })
      );
      cleanupConnection();
    });
  });
}

async function recordClientText(
  sessionStore: LiveSessionStore,
  sessionId: string,
  payload?: Record<string, unknown>
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
  payload?: Record<string, unknown>
): Promise<void> {
  const candidates = [payload?.media, payload?.video];
  for (const candidate of candidates) {
    const frame = candidate as { mimeType?: string; data?: string } | undefined;
    if (frame?.mimeType?.startsWith("image/") && frame.data) {
      await sessionStore.recordLatestFrame(sessionId, {
        mimeType: frame.mimeType,
        dataBase64: frame.data,
        updatedAt: new Date().toISOString()
      });
      return;
    }
  }
}
