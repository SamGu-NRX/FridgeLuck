/**
 * Live session loop — runs ONE design arm over ONE suite session with a
 * real model behind the injected `LiveTransport`.
 *
 * Protocol (adapted from the offline harness; the adaptation is the seam
 * gap, reported in the PR):
 * - The SOURCE script drives the conversation: user turns and user/device
 *   actions come from the script; the model generates every assistant turn.
 * - A source ASSISTANT turn is a SLOT where the model speaks. A slot whose
 *   preceding source turn is a user turn produces a PROMPTED response; a
 *   slot with no preceding user turn is a PROACTIVE opportunity, granted
 *   only within the design's turn budget (same accounting as
 *   run/designRunner.ts gateScript: at most maxUnpromptedTurns kept, at
 *   least minGapTurns emitted turns between two). The model may stay
 *   silent (empty text) — the budget slot is still consumed. Consecutive
 *   user turns accumulate in the context and are answered at the next
 *   slot.
 * - TOOL POLICY: the world's runtime is wrapped with the design's
 *   `wrapWithPolicy` — denied calls error with the typed policy result and
 *   never reach the tool layer, exactly as offline.
 * - THIRD-REJECTION SILENCE: rejections accrue to suggestion types the
 *   model actually emitted (design.suggestionType on the generated text).
 *   After two, the type is silenced: later requests carry an explicit
 *   constraint, and a generated turn that still carries the tag is logged
 *   as a violation (visible, not hidden). Offline the gate suppresses the
 *   turn outright; live the runner can only constrain and measure — that
 *   difference is inherent to a real model.
 * - APPROVALS: scripted approve/reject reference scripted call ids that do
 *   not exist live, so they map FIFO to the oldest still-open proposal the
 *   model created this session; an unmatched action is logged, not fatal.
 *   Device events (advance/kill/resume/offline/reconnect) map 1:1.
 *
 * CAPS: every transport send is authorized by the CapLedger FIRST. A
 * request that would exceed either cap throws CapAbortError BEFORE the
 * send; the run aborts cleanly and reports state.
 *
 * The loop assembles the PINNED RunRecord shape (run/harness.ts) from the
 * live streams so the existing Python scorer can score live sessions
 * unchanged. Like the offline harness it emits RAW records only — no job
 * success, no safety verdicts, no approval judgements.
 */

import type { FoodSafetyAnswer } from "../types.js";
import type { CameraLookResult } from "../reads.js";
import type { SessionScript, ScriptTurn, ScriptUserAction, ReplayAnswer, ReplayCameraEvent } from "../fakeModel.js";
import { estimateTokens } from "../fakeModel.js";
import type { LeChefDesign } from "../designs/contract.js";
import { defaultIsRejection } from "../designs/contract.js";
import type { DispatchResult } from "../runtime.js";
import { buildSessionWorld, type RunRecord, type SessionWorld } from "../run/harness.js";
import { wrapWithPolicy } from "../run/designRunner.js";
import type { CapLedger, CapState, CapBreach } from "./caps.js";
import type { SessionLog } from "./logs.js";
import type { LiveTransport, LiveTransportRequest, LiveTransportResponse } from "./types.js";

/** Thrown when a cap binds — always BEFORE the request was sent. */
export class CapAbortError extends Error {
  readonly breach: CapBreach;
  readonly detail: string;
  readonly capState: CapState;

  constructor(breach: CapBreach, detail: string, capState: CapState) {
    super(`live run aborted: ${breach} — ${detail}`);
    this.name = "CapAbortError";
    this.breach = breach;
    this.detail = detail;
    this.capState = capState;
  }
}

/** Thrown when the transport itself fails; counts the attempt, aborts the run. */
export class TransportError extends Error {
  readonly cause: unknown;

  constructor(cause: unknown) {
    super(`transport failed: ${cause instanceof Error ? cause.message : String(cause)}`);
    this.name = "TransportError";
    this.cause = cause;
  }
}

interface EmittedTurn {
  readonly i: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly toolCallIds: readonly string[];
  readonly prompted: boolean;
}

export interface LiveSessionOptions {
  readonly source: SessionScript;
  readonly design: LeChefDesign;
  readonly transport: LiveTransport;
  readonly ledger: CapLedger;
  readonly log: SessionLog;
  readonly maxOutputTokens: number;
  readonly maxToolRounds: number;
  /** Wall-clock for log timestamps — injectable for deterministic tests. */
  readonly now?: () => Date;
}

export interface LiveSessionOutcome {
  readonly sessionId: string;
  readonly arm: string;
  readonly record: RunRecord;
  readonly requestsSent: number;
  readonly suppressed: readonly { readonly turn: number; readonly because: string }[];
  readonly silencedViolations: number;
  readonly providerTokens: { readonly inputTokens: number; readonly outputTokens: number };
  readonly capStateAtEnd: CapState;
}

interface OpenProposal {
  readonly proposalId: string;
  resolved: boolean;
}

interface DispatchedCall {
  readonly callId: string;
  readonly name: string;
  readonly resultJson: string;
}

/** Side-stream classification mirroring fakeModel.recordSideStreams on public shapes. Returns camera frames sent by THIS dispatch (0 otherwise). */
function classifySideStreams(
  dispatch: DispatchResult,
  turnIndex: number,
  answers: ReplayAnswer[],
  camera: ReplayCameraEvent[]
): number {
  if (dispatch.name === "checkFoodSafety" && dispatch.status === "ok") {
    const rec = dispatch.result as { answer: FoodSafetyAnswer };
    if (rec.answer.kind === "sourced-check") {
      const check = rec.answer.check;
      answers.push({
        turn: turnIndex,
        type: "doneness",
        sourcedCheck: { tool: check.tool, source: check.source, temperatureC: check.temperatureC }
      });
    } else {
      answers.push({ turn: turnIndex, type: "doneness", sourcedCheck: null });
    }
  }
  if (dispatch.name === "lookupSubstitution" && dispatch.status === "ok") {
    answers.push({ turn: turnIndex, type: "other", sourcedCheck: null });
  }
  if (dispatch.name === "requestCameraLook" && dispatch.status === "ok") {
    const rec = dispatch.result as CameraLookResult;
    camera.push({
      look: true,
      framesSent: rec.look.framesSent,
      clipSeconds: rec.look.clipSeconds,
      observed: rec.look.observed,
      cannotAssess: rec.look.cannotAssess,
      safetyVerdict: null
    });
    return rec.look.framesSent;
  }
  return 0;
}

/** Run the live conversation for one (arm, session). Throws CapAbortError / TransportError on clean abort. */
export async function runLiveSession(opts: LiveSessionOptions): Promise<LiveSessionOutcome> {
  const { source, design, transport, ledger, log, maxOutputTokens, maxToolRounds } = opts;
  const now = opts.now ?? (() => new Date());
  const ts = (): string => now().toISOString();

  // The world is built from the SOURCE script (fixture, camera, catalog);
  // only the assistant material is generated live.
  const world: SessionWorld = buildSessionWorld({ ...source, design: design.id });
  const runtime = wrapWithPolicy(world.runtime, design);

  const turns: EmittedTurn[] = [];
  const toolCalls: {
    readonly id: string;
    readonly name: string;
    readonly args: Readonly<Record<string, unknown>>;
    readonly result: unknown;
    readonly status: DispatchResult["status"];
    readonly dupOf?: string;
  }[] = [];
  const answers: ReplayAnswer[] = [];
  const camera: ReplayCameraEvent[] = [];
  let framesSent = 0;
  let textTokensIn = 0;
  let textTokensOut = 0;
  let audioSeconds = 0;
  const proposalByCallId = new Map<string, string>();
  const openProposals: OpenProposal[] = [];

  // Budget accounting — identical semantics to gateScript.
  let unpromptedKept = 0;
  let turnsSinceUnprompted = Number.POSITIVE_INFINITY;
  let lastSuggestion: string | null = null;
  const rejections = new Map<string, number>();
  const silencedTypes = new Set<string>();
  let silencedViolations = 0;
  const suppressed: { turn: number; because: string }[] = [];

  const providerTokens = { inputTokens: 0, outputTokens: 0 };
  let requestsSent = 0;

  log.append(
    {
      kind: "session-start",
      model: transport.model,
      transport: transport.name,
      designId: design.id,
      sourceTurns: source.turns.length
    },
    ts()
  );

  const systemFor = (proactive: boolean): string => {
    let system = design.systemPrompt;
    if (proactive) {
      system +=
        " [live-mode] It is your unprompted slot: speak at most one turn, grounded in what you just observed. " +
        "You may stay silent by replying with an empty string.";
    }
    if (silencedTypes.size > 0) {
      system +=
        " [live-mode] The user has declined the following suggestion type(s) twice — do not suggest them again this session: " +
        [...silencedTypes].sort().join(", ") +
        ".";
    }
    return system;
  };

  const contextCharsOf = (messages: LiveTransportRequest["messages"], toolResults: LiveTransportRequest["toolResults"]): number =>
    messages.reduce((sum, m) => sum + m.text.length, 0) + toolResults.reduce((sum, t) => sum + t.resultJson.length, 0);

  /** One authorized, logged transport send. Throws CapAbortError BEFORE sending when a cap binds. */
  const sendAuthorized = async (
    messages: LiveTransportRequest["messages"],
    toolResults: LiveTransportRequest["toolResults"],
    system: string,
    meta: { readonly prompted: boolean; readonly round: number; readonly slotTurn: number }
  ): Promise<LiveTransportResponse> => {
    const auth = ledger.authorize({
      systemChars: system.length,
      contextChars: contextCharsOf(messages, toolResults),
      maxOutputTokens
    });
    if (!auth.allowed || auth.estimate === undefined) {
      log.append({ kind: "cap-abort", breach: auth.breach, detail: auth.detail, capState: ledger.state() }, ts());
      throw new CapAbortError(auth.breach as CapBreach, auth.detail ?? "cap refused", ledger.state());
    }
    const est = auth.estimate;
    ledger.chargeEstimate(est);
    requestsSent += 1;
    const requestChars = system.length + contextCharsOf(messages, toolResults);
    log.append(
      {
        kind: "request",
        model: transport.model,
        transport: transport.name,
        prompted: meta.prompted,
        slotTurn: meta.slotTurn,
        round: meta.round,
        requestChars,
        estimatedInputTokens: est.estimatedInputTokens,
        estimatedOutputTokens: est.estimatedOutputTokens,
        estimatedCostUsd: est.estimatedCostUsd,
        committedSpendUsd: ledger.state().committedSpendUsd,
        capState: ledger.state()
      },
      ts()
    );

    let response: LiveTransportResponse;
    try {
      response = await transport.send({ system, messages, toolResults, maxOutputTokens });
    } catch (e) {
      log.append(
        { kind: "transport-error", error: e instanceof Error ? e.message : String(e), capState: ledger.state() },
        ts()
      );
      throw new TransportError(e);
    }
    const committedAfter = ledger.recordActual(response.usage);
    if (response.usage !== undefined) {
      providerTokens.inputTokens += response.usage.inputTokens;
      providerTokens.outputTokens += response.usage.outputTokens;
    }
    log.append(
      {
        kind: "response",
        model: transport.model,
        prompted: meta.prompted,
        slotTurn: meta.slotTurn,
        round: meta.round,
        text: response.text,
        toolCallCount: response.toolCalls.length,
        usage: response.usage,
        committedSpendUsd: committedAfter,
        capState: ledger.state()
      },
      ts()
    );
    return response;
  };

  const dispatchCalls = (turnIndex: number, calls: LiveTransportResponse["toolCalls"]): DispatchedCall[] => {
    const dispatched: DispatchedCall[] = [];
    for (const call of calls) {
      const dispatch = runtime.dispatch(
        { id: call.id, name: call.name, ...(call.args !== undefined ? { args: { ...call.args } } : {}) },
        undefined
      );
      toolCalls.push({
        id: dispatch.id,
        name: dispatch.name,
        args: dispatch.args,
        result: dispatch.result,
        status: dispatch.status,
        ...(dispatch.dupOf !== undefined ? { dupOf: dispatch.dupOf } : {})
      });
      dispatched.push({ callId: dispatch.id, name: dispatch.name, resultJson: JSON.stringify(dispatch.result) });
      log.append(
        { kind: "tool-dispatch", callId: dispatch.id, tool: dispatch.name, status: dispatch.status, result: dispatch.result },
        ts()
      );
      framesSent += classifySideStreams(dispatch, turnIndex, answers, camera);
      const proposalId =
        typeof dispatch.result === "object" && dispatch.result !== null
          ? (dispatch.result as { proposalId?: unknown }).proposalId
          : undefined;
      if (typeof proposalId === "string") {
        proposalByCallId.set(call.id, proposalId);
        openProposals.push({ proposalId, resolved: false });
      }
    }
    return dispatched;
  };

  const applyUserActions = (turnIndex: number): void => {
    for (const { action } of (source.userActions ?? []).filter((a) => a.afterTurn === turnIndex)) {
      applyOneUserAction(action, turnIndex);
    }
  };

  const applyOneUserAction = (action: ScriptUserAction, turnIndex: number): void => {
    switch (action.kind) {
      case "approve":
      case "reject": {
        // Scripted call ids do not exist live — map FIFO to the oldest open proposal.
        const target = openProposals.find((p) => !p.resolved);
        if (target === undefined) {
          log.append({ kind: "user-action", action: action.kind, matched: false, atTurn: turnIndex }, ts());
          break;
        }
        target.resolved = true;
        if (action.kind === "approve") world.phone.userApproves(target.proposalId);
        else world.phone.userRejects(target.proposalId);
        log.append(
          { kind: "user-action", action: action.kind, matched: true, proposalId: target.proposalId, atTurn: turnIndex },
          ts()
        );
        break;
      }
      case "advanceMinutes": {
        if ("advanceMs" in world.clock && typeof world.clock.advanceMs === "function") {
          world.clock.advanceMs(action.minutes * 60_000);
        } else {
          throw new Error("live run: advanceMinutes needs an advancing clock");
        }
        world.phone.tickTimers();
        log.append({ kind: "user-action", action: "advanceMinutes", minutes: action.minutes, atTurn: turnIndex }, ts());
        break;
      }
      case "kill":
        world.phone.killApp();
        log.append({ kind: "user-action", action: "kill", atTurn: turnIndex }, ts());
        break;
      case "resume":
        world.phone.resumeApp();
        log.append({ kind: "user-action", action: "resume", atTurn: turnIndex }, ts());
        break;
      case "offline":
        world.phone.goOffline();
        log.append({ kind: "user-action", action: "offline", atTurn: turnIndex }, ts());
        break;
      case "reconnect":
        world.phone.reconnect();
        log.append({ kind: "user-action", action: "reconnect", atTurn: turnIndex }, ts());
        break;
    }
  };

  const conversation: { readonly role: "user" | "assistant"; readonly text: string }[] = [];

  /**
   * One exchange: possibly several authorized rounds (tool loop), ending in
   * the assistant's final text (or an empty text when the round limit
   * binds). The emitted turn's text is the final round's text; intermediate
   * rounds' text (alongside tool calls) is discarded from the record, its
   * tokens stay in the provider usage.
   */
  const exchange = async (
    meta: { readonly prompted: boolean; readonly slotTurn: number }
  ): Promise<{ text: string; toolCallIds: string[] }> => {
    let toolResults: LiveTransportRequest["toolResults"] = [];
    const allCallIds: string[] = [];
    let finalText = "";
    for (let round = 0; ; round += 1) {
      const response = await sendAuthorized(conversation, toolResults, systemFor(!meta.prompted), {
        ...meta,
        round
      });
      if (response.toolCalls.length === 0) {
        finalText = response.text;
        break;
      }
      const dispatched = dispatchCalls(meta.slotTurn, response.toolCalls);
      allCallIds.push(...dispatched.map((d) => d.callId));
      if (round + 1 >= maxToolRounds) {
        // Round limit binds — the calls just dispatched are the last step;
        // no further model round is requested.
        log.append({ kind: "note", note: "max tool rounds reached; no further model round requested" }, ts());
        break;
      }
      toolResults = dispatched;
    }
    return { text: finalText, toolCallIds: allCallIds };
  };

  // Main walk over the SOURCE script in turn order.
  const sorted = [...source.turns].sort((a, b) => a.i - b.i);
  let prevSourceRole: ScriptTurn["role"] | null = null;
  const startMs = world.clock.nowMs();

  try {
    for (const turn of sorted) {
      if (turn.role === "user") {
        // Rejections accrue to suggestions the model actually emitted.
        if (lastSuggestion !== null && (design.isRejection ?? defaultIsRejection)(turn)) {
          rejections.set(lastSuggestion, (rejections.get(lastSuggestion) ?? 0) + 1);
          if ((rejections.get(lastSuggestion) ?? 0) >= 2 && !silencedTypes.has(lastSuggestion)) {
            silencedTypes.add(lastSuggestion);
            log.append({ kind: "suggestion-silenced", suggestionType: lastSuggestion }, ts());
          }
        }
        lastSuggestion = null;

        conversation.push({ role: "user", text: turn.text });
        textTokensIn += estimateTokens(turn.text);
        audioSeconds += turn.audioSeconds ?? 0;
        if (turnsSinceUnprompted !== Number.POSITIVE_INFINITY) turnsSinceUnprompted += 1;
        turns.push({ i: turn.i, role: "user", text: turn.text, toolCallIds: [], prompted: turn.prompted === true });
        applyUserActions(turn.i);
        prevSourceRole = "user";
        continue;
      }

      // Assistant slot: prompted when a user turn precedes it, proactive otherwise.
      const promptedSlot = prevSourceRole === "user";
      if (!promptedSlot) {
        if (unpromptedKept >= design.turnBudget.maxUnpromptedTurns) {
          suppressed.push({ turn: turn.i, because: "budget-exhausted" });
          log.append({ kind: "turn-suppressed", turn: turn.i, because: "budget-exhausted" }, ts());
          applyUserActions(turn.i);
          prevSourceRole = "assistant";
          continue;
        }
        if (turnsSinceUnprompted < design.turnBudget.minGapTurns) {
          suppressed.push({ turn: turn.i, because: "min-gap" });
          log.append({ kind: "turn-suppressed", turn: turn.i, because: "min-gap" }, ts());
          applyUserActions(turn.i);
          prevSourceRole = "assistant";
          continue;
        }
      }

      const emitted = await exchange({ prompted: promptedSlot, slotTurn: turn.i });
      if (promptedSlot) {
        if (turnsSinceUnprompted !== Number.POSITIVE_INFINITY) turnsSinceUnprompted += 1;
      } else {
        unpromptedKept += 1;
        turnsSinceUnprompted = 0;
      }
      if (emitted.text.trim() !== "") {
        textTokensOut += estimateTokens(emitted.text);
        turns.push({
          i: turn.i,
          role: "assistant",
          text: emitted.text,
          toolCallIds: emitted.toolCallIds,
          prompted: promptedSlot
        });
        const suggestion = design.suggestionType?.({ i: turn.i, role: "assistant", text: emitted.text }) ?? null;
        lastSuggestion = suggestion;
        if (!promptedSlot && suggestion !== null && silencedTypes.has(suggestion)) {
          // The constraint was in the system context and the model suggested
          // anyway — recorded, not hidden (live cannot suppress a generated
          // turn; offline the gate can).
          silencedViolations += 1;
          log.append({ kind: "turn-suppressed", turn: turn.i, because: "suggestion-type-silenced-violation" }, ts());
        }
      }
      applyUserActions(turn.i);
      prevSourceRole = "assistant";
    }

    log.append(
      { kind: "session-end", completed: true, turns: turns.length, requestsSent, capState: ledger.state() },
      ts()
    );
  } catch (e) {
    const aborted = e instanceof CapAbortError;
    log.append(
      {
        kind: "session-end",
        completed: false,
        reason: aborted ? "cap-abort" : "transport-error",
        turns: turns.length,
        requestsSent,
        capState: ledger.state()
      },
      ts()
    );
    throw e;
  }

  const record = assembleRunRecord(source, design, world, {
    turns,
    toolCalls,
    answers,
    camera,
    framesSent,
    textTokensIn,
    textTokensOut,
    audioSeconds,
    startMs,
    endMs: world.clock.nowMs()
  });
  return {
    sessionId: source.sessionId,
    arm: design.id,
    record,
    requestsSent,
    suppressed,
    silencedViolations,
    providerTokens,
    capStateAtEnd: ledger.state()
  };
}


/** Assemble the pinned RunRecord from live streams — same raw shape as run/harness.ts (no scoring). */
function assembleRunRecord(
  source: SessionScript,
  design: LeChefDesign,
  world: SessionWorld,
  streams: {
    turns: EmittedTurn[];
    toolCalls: {
      readonly id: string;
      readonly name: string;
      readonly args: Readonly<Record<string, unknown>>;
      readonly result: unknown;
      readonly status: DispatchResult["status"];
      readonly dupOf?: string;
    }[];
    answers: ReplayAnswer[];
    camera: ReplayCameraEvent[];
    framesSent: number;
    textTokensIn: number;
    textTokensOut: number;
    audioSeconds: number;
    startMs: number;
    endMs: number;
  }
): RunRecord {
  const f = (epochSeconds: number): string => new Date(epochSeconds * 1000).toISOString();

  const proposals = world.runtime.proposals.proposals().map((p) => ({
    id: p.id,
    tool: p.tool,
    payload: p.payload,
    payloadHash: p.payloadHash,
    requiredApproval: p.requiredApproval,
    userInitiated: p.userInitiated,
    state: world.runtime.proposals.stateOf(p.id)
  }));
  const receipts = world.phone.receipts().map((r) => ({
    proposalID: r.proposalID,
    state: r.state,
    recordedAt: f(r.recordedAt)
  }));
  const timers = world.phone.timerRecords().map((t) => ({
    label: t.label,
    minutes: t.minutes,
    proposalId: t.proposalId,
    createdAt: f(t.createdAt),
    deadline: f(t.deadline),
    ...(t.firedAt !== undefined ? { firedAt: f(t.firedAt) } : {}),
    survivedKill: t.survivedKill
  }));
  const events = world.phone
    .events()
    .map((e) => ({ kind: e.kind, at: f(e.at) }))
    .sort((a, b) => (a.at === b.at ? a.kind.localeCompare(b.kind) : a.at.localeCompare(b.at)));

  return {
    sessionId: source.sessionId,
    job: source.job,
    cameraMode: source.cameraMode,
    design: design.id,
    turns: streams.turns,
    toolCalls: streams.toolCalls,
    proposals,
    receipts,
    timers,
    events,
    answers: streams.answers,
    camera: streams.camera,
    usage: {
      turns: streams.turns.length,
      textTokensIn: streams.textTokensIn,
      textTokensOut: streams.textTokensOut,
      audioSeconds: Math.round(streams.audioSeconds * 1000) / 1000,
      framesSent: streams.framesSent,
      connectedSeconds: Math.round((streams.endMs - streams.startMs) / 1000)
    }
  };
}
