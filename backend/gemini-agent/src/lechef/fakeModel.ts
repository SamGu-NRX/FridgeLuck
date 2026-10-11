/**
 * Fake model — replays scripted turns against the runtime (the "fake
 * provider" for offline evaluation; no LLM API is contacted, ever).
 *
 * A script is a pinned-shape session: turns with text and tool calls, plus
 * scripted user/device actions between turns (approvals, clock advances,
 * kill-app, offline). The replay must faithfully support:
 *
 * - REORDERED tool calls — calls dispatch independently; nothing in the
 *   layer may depend on call order;
 * - DUPLICATED calls — the same call id, or the same args, twice: the
 *   proposal layer dedupes (call id first, then payloadHash) and reads are
 *   idempotent, so the second call is a no-op recorded as `duplicate`;
 * - CANCELLED calls — a cancelled call aborts before anything happens, so
 *   no proposal from it ever reaches the phone.
 *
 * The replay emits RAW per-stream records only. It computes no job success,
 * no safety verdicts, no approval judgements — the Python scorer owns those.
 */

import type {
  CameraMode,
  CookSessionSnapshot,
  Eater,
  EpochSeconds,
  FoodSafetyAnswer,
  PantryLine,
  Quantity,
  RecipeContext,
  SourcedCheck
} from "./types.js";
import type { CameraLookResult } from "./reads.js";
import type { LeChefRuntime, DispatchResult } from "./runtime.js";
import type { FakePhone } from "./fakePhone.js";
import type { Clock } from "./types.js";

// ---------------------------------------------------------------------------
// Script schema (pinned; see lechef/README.md "Session script schema")
// ---------------------------------------------------------------------------

export type LeChefJob = "plan" | "substitute" | "coach" | "adapt" | "remember";

export interface ScriptToolCall {
  readonly id: string;
  readonly name: string;
  readonly args?: Readonly<Record<string, unknown>>;
  /** True when this call replays a direct user command (timers may then be device-auto). */
  readonly userInitiated?: boolean;
}

export type ScriptUserAction =
  | { readonly kind: "approve"; readonly callId: string }
  | { readonly kind: "reject"; readonly callId: string }
  | { readonly kind: "advanceMinutes"; readonly minutes: number }
  | { readonly kind: "kill" }
  | { readonly kind: "resume" }
  | { readonly kind: "offline" }
  | { readonly kind: "reconnect" };

export interface ScriptTurn {
  readonly i: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly toolCalls?: readonly ScriptToolCall[];
  /** Call ids the provider cancelled before completion — no proposal from these reaches the phone. */
  readonly cancelled?: readonly string[];
  /** Voice input length for usage accounting (seconds). */
  readonly audioSeconds?: number;
  /** Whether the assistant ended the turn with a question/prompt to the user. */
  readonly prompted?: boolean;
}

export interface SessionScript {
  readonly sessionId: string;
  readonly job: LeChefJob;
  readonly cameraMode: CameraMode;
  readonly design: string;
  readonly turns: readonly ScriptTurn[];
  /** Scripted user/device actions applied after the named turn index. */
  readonly userActions?: readonly { readonly afterTurn: number; readonly action: ScriptUserAction }[];
  /** The scripted world the session starts in (deterministic; see README). */
  readonly fixture?: ScriptFixture;
}

export interface ScriptFixtureCamera {
  readonly framesPerLook: number;
  readonly clipSeconds: number;
  readonly observed: readonly string[];
  readonly cannotAssess: readonly string[];
}

export interface ScriptFixture {
  /** Deterministic wall-clock start (ISO 8601). Defaults to a fixed epoch for reproducible runs. */
  readonly nowIso?: string;
  readonly pantry?: readonly PantryLine[];
  readonly session?: Partial<
    Pick<CookSessionSnapshot, "recipeId" | "state" | "currentStepIndex" | "eaters" | "cameraMode">
  >;
  readonly recipes?: readonly RecipeContext[];
  /** Canned camera capture; omit when the session has no camera. */
  readonly camera?: ScriptFixtureCamera;
}

export class ScriptParseError extends Error {
  constructor(issues: readonly string[]) {
    super(`session script invalid: ${issues.join("; ")}`);
    this.name = "ScriptParseError";
  }
}

/** Validate unknown JSON into a SessionScript — external input is unknown until checked here. */
export function parseSessionScript(value: unknown): SessionScript {
  const issues: string[] = [];
  if (typeof value !== "object" || value === null) {
    throw new ScriptParseError(["expected an object"]);
  }
  const rec = value as Record<string, unknown>;
  if (typeof rec["sessionId"] !== "string") issues.push("sessionId: expected string");
  const job = rec["job"];
  const JOBS: readonly LeChefJob[] = ["plan", "substitute", "coach", "adapt", "remember"];
  if (typeof job !== "string" || !JOBS.includes(job as never)) issues.push(`job: expected one of ${JOBS.join("|")}`);
  const cameraMode = rec["cameraMode"];
  if (cameraMode !== "push-to-look" && cameraMode !== "continuous") {
    issues.push("cameraMode: expected push-to-look|continuous");
  }
  if (typeof rec["design"] !== "string") issues.push("design: expected string");
  if (!Array.isArray(rec["turns"])) issues.push("turns: expected array");
  if (issues.length > 0) throw new ScriptParseError(issues);
  const sessionId = rec["sessionId"] as string;
  const design = rec["design"] as string;

  const turns: ScriptTurn[] = [];
  let lastI = -1;
  for (const raw of rec["turns"] as unknown[]) {
    if (typeof raw !== "object" || raw === null) {
      throw new ScriptParseError([`turns: expected objects, got ${typeof raw}`]);
    }
    const t = raw as Record<string, unknown>;
    if (typeof t["i"] !== "number" || !Number.isInteger(t["i"])) throw new ScriptParseError(["turn.i: expected integer"]);
    if (t["i"] <= lastI) throw new ScriptParseError([`turn.i: must strictly increase (got ${t["i"]} after ${lastI})`]);
    lastI = t["i"];
    if (t["role"] !== "user" && t["role"] !== "assistant") throw new ScriptParseError([`turn ${t["i"]}.role: expected user|assistant`]);
    if (typeof t["text"] !== "string") throw new ScriptParseError([`turn ${t["i"]}.text: expected string`]);
    const toolCalls: ScriptToolCall[] = [];
    if (t["toolCalls"] !== undefined) {
      if (!Array.isArray(t["toolCalls"])) throw new ScriptParseError([`turn ${t["i"]}.toolCalls: expected array`]);
      for (const rawCall of t["toolCalls"] as unknown[]) {
        if (typeof rawCall !== "object" || rawCall === null) throw new ScriptParseError([`turn ${t["i"]}.toolCalls: expected objects`]);
        const c = rawCall as Record<string, unknown>;
        if (typeof c["id"] !== "string") throw new ScriptParseError([`turn ${t["i"]} call.id: expected string`]);
        if (typeof c["name"] !== "string") throw new ScriptParseError([`turn ${t["i"]} call ${String(c["id"])}.name: expected string`]);
        if (c["args"] !== undefined && (typeof c["args"] !== "object" || c["args"] === null)) {
          throw new ScriptParseError([`turn ${t["i"]} call ${String(c["id"])}.args: expected object`]);
        }
        toolCalls.push({
          id: c["id"],
          name: c["name"],
          ...(c["args"] !== undefined ? { args: c["args"] as Record<string, unknown> } : {}),
          ...(c["userInitiated"] === true ? { userInitiated: true } : {})
        });
      }
    }
    turns.push({
      i: t["i"],
      role: t["role"],
      text: t["text"],
      ...(toolCalls.length > 0 ? { toolCalls } : {}),
      ...(Array.isArray(t["cancelled"]) ? { cancelled: (t["cancelled"] as unknown[]).filter((x): x is string => typeof x === "string") } : {}),
      ...(typeof t["audioSeconds"] === "number" ? { audioSeconds: t["audioSeconds"] } : {}),
      ...(t["prompted"] === true ? { prompted: true } : {})
    });
  }

  const userActions: { afterTurn: number; action: ScriptUserAction }[] = [];
  if (rec["userActions"] !== undefined) {
    if (!Array.isArray(rec["userActions"])) throw new ScriptParseError(["userActions: expected array"]);
    for (const rawAction of rec["userActions"] as unknown[]) {
      if (typeof rawAction !== "object" || rawAction === null) throw new ScriptParseError(["userActions: expected objects"]);
      const a = rawAction as Record<string, unknown>;
      if (typeof a["afterTurn"] !== "number") throw new ScriptParseError(["userActions.afterTurn: expected number"]);
      const kind = a["action"];
      if (typeof kind !== "object" || kind === null) throw new ScriptParseError(["userActions.action: expected object"]);
      const k = kind as Record<string, unknown>;
      const kindName = k["kind"];
      if (kindName === "approve" || kindName === "reject") {
        if (typeof k["callId"] !== "string") throw new ScriptParseError([`userActions.${kindName}: expected callId`]);
        userActions.push({ afterTurn: a["afterTurn"], action: { kind: kindName, callId: k["callId"] } });
      } else if (kindName === "advanceMinutes") {
        if (typeof k["minutes"] !== "number") throw new ScriptParseError(["userActions.advanceMinutes: expected minutes"]);
        userActions.push({ afterTurn: a["afterTurn"], action: { kind: "advanceMinutes", minutes: k["minutes"] } });
      } else if (kindName === "kill" || kindName === "resume" || kindName === "offline" || kindName === "reconnect") {
        userActions.push({ afterTurn: a["afterTurn"], action: { kind: kindName } });
      } else {
        throw new ScriptParseError([`userActions.action.kind: unknown "${String(kindName)}"`]);
      }
    }
  }

  const fixture = rec["fixture"] !== undefined ? parseFixture(rec["fixture"]) : undefined;

  return {
    sessionId,
    job: job as LeChefJob,
    cameraMode: cameraMode as CameraMode,
    design,
    turns,
    ...(userActions.length > 0 ? { userActions } : {}),
    ...(fixture !== undefined ? { fixture } : {})
  };
}

// ---------------------------------------------------------------------------
// Fixture parsing — external world input is unknown until checked here
// ---------------------------------------------------------------------------

const FIXTURE_PANTRY_STATES: readonly string[] = ["sufficient", "short", "quantity-unknown", "assumed-staple", "needs-reconfirming"];
const FIXTURE_SOURCES: readonly string[] = ["scan", "receipt", "manual"];

function parseFixture(value: unknown): ScriptFixture {
  if (typeof value !== "object" || value === null) throw new ScriptParseError(["fixture: expected object"]);
  const rec = value as Record<string, unknown>;
  const issues: string[] = [];

  let nowIso: string | undefined;
  if (rec["nowIso"] !== undefined) {
    if (typeof rec["nowIso"] !== "string" || Number.isNaN(Date.parse(rec["nowIso"]))) {
      issues.push("fixture.nowIso: expected an ISO 8601 string");
    } else {
      nowIso = rec["nowIso"] as string;
    }
  }

  let pantry: PantryLine[] | undefined;
  if (rec["pantry"] !== undefined) {
    if (!Array.isArray(rec["pantry"])) {
      issues.push("fixture.pantry: expected array");
    } else {
      const lines: PantryLine[] = [];
      (rec["pantry"] as unknown[]).forEach((raw, idx) => {
        try {
          lines.push(parsePantryLine(raw));
        } catch (e) {
          issues.push(`fixture.pantry[${idx}]: ${e instanceof Error ? e.message : String(e)}`);
        }
      });
      pantry = lines;
    }
  }

  let session: ScriptFixture["session"];
  if (rec["session"] !== undefined) {
    if (typeof rec["session"] !== "object" || rec["session"] === null) {
      issues.push("fixture.session: expected object");
    } else {
      const s = rec["session"] as Record<string, unknown>;
      const eaters: Eater[] = [];
      if (s["eaters"] !== undefined) {
        if (!Array.isArray(s["eaters"])) {
          issues.push("fixture.session.eaters: expected array");
        } else {
          (s["eaters"] as unknown[]).forEach((raw, idx) => {
            if (typeof raw !== "object" || raw === null) {
              issues.push(`fixture.session.eaters[${idx}]: expected object`);
              return;
            }
            const e = raw as Record<string, unknown>;
            if (!Array.isArray(e["restrictions"])) {
              issues.push(`fixture.session.eaters[${idx}].restrictions: expected array`);
              return;
            }
            eaters.push({
              restrictions: (e["restrictions"] as unknown[]).filter((r): r is string => typeof r === "string"),
              ...(typeof e["name"] === "string" ? { name: e["name"] as string } : {})
            });
          });
        }
      }
      const cameraModeOk = s["cameraMode"] === undefined || s["cameraMode"] === "push-to-look" || s["cameraMode"] === "continuous";
      if (!cameraModeOk) issues.push("fixture.session.cameraMode: expected push-to-look|continuous");
      const stateOk = s["state"] === undefined || ["planning", "cooking", "paused", "done"].includes(s["state"] as string);
      if (!stateOk) issues.push("fixture.session.state: expected planning|cooking|paused|done");
      if (s["currentStepIndex"] !== undefined && typeof s["currentStepIndex"] !== "number") {
        issues.push("fixture.session.currentStepIndex: expected number");
      }
      session = {
        ...(typeof s["recipeId"] === "string" ? { recipeId: s["recipeId"] } : {}),
        ...(s["state"] !== undefined ? { state: s["state"] as CookSessionSnapshot["state"] } : {}),
        ...(s["currentStepIndex"] !== undefined ? { currentStepIndex: s["currentStepIndex"] as number } : {}),
        ...(eaters.length > 0 ? { eaters } : {}),
        ...(s["cameraMode"] !== undefined ? { cameraMode: s["cameraMode"] as CameraMode } : {})
      };
    }
  }

  let recipes: RecipeContext[] | undefined;
  if (rec["recipes"] !== undefined) {
    if (!Array.isArray(rec["recipes"])) {
      issues.push("fixture.recipes: expected array");
    } else {
      const parsed: RecipeContext[] = [];
      (rec["recipes"] as unknown[]).forEach((raw, idx) => {
        try {
          parsed.push(parseRecipe(raw));
        } catch (e) {
          issues.push(`fixture.recipes[${idx}]: ${e instanceof Error ? e.message : String(e)}`);
        }
      });
      recipes = parsed;
    }
  }

  let camera: ScriptFixtureCamera | undefined;
  if (rec["camera"] !== undefined) {
    if (typeof rec["camera"] !== "object" || rec["camera"] === null) {
      issues.push("fixture.camera: expected object");
    } else {
      const c = rec["camera"] as Record<string, unknown>;
      const okFrames = typeof c["framesPerLook"] === "number" && Number.isFinite(c["framesPerLook"]);
      const okClip = typeof c["clipSeconds"] === "number" && Number.isFinite(c["clipSeconds"]);
      const okObserved = c["observed"] === undefined || Array.isArray(c["observed"]);
      const okCannot = c["cannotAssess"] === undefined || Array.isArray(c["cannotAssess"]);
      if (!okFrames || !okClip || !okObserved || !okCannot) {
        issues.push("fixture.camera: expected numeric framesPerLook/clipSeconds and array observed/cannotAssess");
      } else {
        camera = {
          framesPerLook: c["framesPerLook"] as number,
          clipSeconds: c["clipSeconds"] as number,
          observed: ((c["observed"] as unknown[]) ?? []).filter((x): x is string => typeof x === "string"),
          cannotAssess: ((c["cannotAssess"] as unknown[]) ?? []).filter((x): x is string => typeof x === "string")
        };
      }
    }
  }

  if (issues.length > 0) throw new ScriptParseError(issues);
  return {
    ...(nowIso !== undefined ? { nowIso } : {}),
    ...(pantry !== undefined ? { pantry } : {}),
    ...(session !== undefined ? { session } : {}),
    ...(recipes !== undefined ? { recipes } : {}),
    ...(camera !== undefined ? { camera } : {})
  };
}

function parseQuantity(value: unknown): Quantity {
  if (typeof value === "object" && value !== null) {
    const q = value as Record<string, unknown>;
    if (q["kind"] === "unknown") return { kind: "unknown" };
    if (q["kind"] === "known" && typeof q["value"] === "number" && typeof q["unit"] === "string") {
      return { kind: "known", value: q["value"], unit: q["unit"] };
    }
  }
  throw new Error('quantity: expected {kind:"known",value,unit} or {kind:"unknown"}');
}

function parsePantryLine(value: unknown): PantryLine {
  if (typeof value !== "object" || value === null) throw new Error("expected object");
  const p = value as Record<string, unknown>;
  if (typeof p["ingredientId"] !== "string") throw new Error("ingredientId: expected string");
  if (typeof p["name"] !== "string") throw new Error("name: expected string");
  if (p["quantity"] === undefined) throw new Error("quantity: required");
  if (typeof p["state"] !== "string" || !FIXTURE_PANTRY_STATES.includes(p["state"])) throw new Error("state: expected one of " + FIXTURE_PANTRY_STATES.join("|"));
  if (typeof p["source"] !== "string" || !FIXTURE_SOURCES.includes(p["source"])) throw new Error("source: expected scan|receipt|manual");
  const quantity = parseQuantity(p["quantity"]);
  return {
    ingredientId: p["ingredientId"] as string,
    name: p["name"] as string,
    quantity,
    state: p["state"] as PantryLine["state"],
    ...(p["state"] === "short" && typeof p["shortBy"] === "number" ? { shortBy: p["shortBy"] } : {}),
    ...(typeof p["lastConfirmedAt"] === "number" ? { lastConfirmedAt: p["lastConfirmedAt"] as EpochSeconds } : {}),
    source: p["source"] as PantryLine["source"],
    ...(p["useSoon"] === true ? { useSoon: true } : {}),
    ...(typeof p["expiresAt"] === "number" ? { expiresAt: p["expiresAt"] as EpochSeconds } : {})
  };
}

function parseRecipe(value: unknown): RecipeContext {
  if (typeof value !== "object" || value === null) throw new Error("expected object");
  const r = value as Record<string, unknown>;
  if (typeof r["id"] !== "string") throw new Error("id: expected string");
  if (typeof r["revision"] !== "number") throw new Error("revision: expected number");
  if (typeof r["servings"] !== "number") throw new Error("servings: expected number");
  if (!Array.isArray(r["ingredientBill"])) throw new Error("ingredientBill: expected array");
  if (!Array.isArray(r["steps"])) throw new Error("steps: expected array");
  const bill = (r["ingredientBill"] as unknown[]).map((raw) => {
    if (typeof raw !== "object" || raw === null) throw new Error("ingredientBill line: expected object");
    const b = raw as Record<string, unknown>;
    if (typeof b["ingredientId"] !== "string") throw new Error("ingredientBill line.ingredientId: expected string");
    if (typeof b["name"] !== "string") throw new Error("ingredientBill line.name: expected string");
    return {
      ingredientId: b["ingredientId"] as string,
      name: b["name"] as string,
      quantity: parseQuantity(b["quantity"]),
      ...(b["optional"] === true ? { optional: true } : {})
    };
  });
  const steps = (r["steps"] as unknown[]).map((raw) => {
    if (typeof raw !== "object" || raw === null) throw new Error("step: expected object");
    const s = raw as Record<string, unknown>;
    if (typeof s["index"] !== "number" || typeof s["text"] !== "string") throw new Error("step: expected numeric index and text");
    return {
      index: s["index"] as number,
      text: s["text"] as string,
      ...(typeof s["timerMinutes"] === "number" ? { timerMinutes: s["timerMinutes"] as number } : {}),
      ...(typeof s["safetyCheckTarget"] === "string" ? { safetyCheckTarget: s["safetyCheckTarget"] as string } : {})
    };
  });
  return {
    id: r["id"] as string,
    revision: r["revision"] as number,
    ...(typeof r["title"] === "string" ? { title: r["title"] as string } : {}),
    servings: r["servings"] as number,
    ingredientBill: bill,
    steps
  };
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

export interface ReplayToolCall {
  readonly id: string;
  readonly name: string;
  readonly args: Readonly<Record<string, unknown>>;
  readonly result: unknown;
  readonly status: DispatchResult["status"];
  readonly dupOf?: string;
}

export interface ReplayAnswer {
  readonly turn: number;
  readonly type: "doneness" | "other";
  readonly sourcedCheck: Pick<SourcedCheck, "tool" | "source" | "temperatureC"> | null;
}

export interface ReplayCameraEvent {
  readonly look: boolean;
  readonly framesSent: number;
  readonly clipSeconds: number;
  readonly observed: readonly string[];
  readonly cannotAssess: readonly string[];
  /** Always null — structurally, a camera look cannot yield a verdict. */
  readonly safetyVerdict: null;
}

export interface ReplayUsage {
  readonly turns: number;
  readonly textTokensIn: number;
  readonly textTokensOut: number;
  readonly audioSeconds: number;
  readonly framesSent: number;
  readonly connectedSeconds: number;
}

export interface ReplayResult {
  readonly turns: {
    readonly i: number;
    readonly role: "user" | "assistant";
    readonly text: string;
    readonly toolCallIds: readonly string[];
    readonly prompted: boolean;
  }[];
  readonly toolCalls: readonly ReplayToolCall[];
  /** callId → proposalId, for scripted approvals. */
  readonly proposalByCallId: ReadonlyMap<string, string>;
  readonly answers: readonly ReplayAnswer[];
  readonly camera: readonly ReplayCameraEvent[];
  readonly usage: ReplayUsage;
}

/** Text-token estimate used consistently across the harness (documented in README). */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

/**
 * Replay a session script against a runtime + fake phone on an injected
 * clock. Emits raw streams only — no scoring, no verdicts, no approvals
 * beyond what the script's user actions perform.
 */
export function replayScript(
  script: SessionScript,
  runtime: LeChefRuntime,
  phone: FakePhone,
  clock: Clock
): ReplayResult {
  const turns: ReplayResult["turns"] = [];
  const toolCalls: ReplayToolCall[] = [];
  const proposalByCallId = new Map<string, string>();
  const answers: ReplayAnswer[] = [];
  const camera: ReplayCameraEvent[] = [];

  const startMs = clock.nowMs();
  let killedMs: number | null = null;
  let killedTotalMs = 0;
  let audioSeconds = 0;
  let framesSent = 0;
  let textTokensIn = 0;
  let textTokensOut = 0;

  const sortedTurns = [...script.turns].sort((a, b) => a.i - b.i);
  const actionsFor = (turnIndex: number): readonly ScriptUserAction[] =>
    (script.userActions ?? []).filter((a) => a.afterTurn === turnIndex).map((a) => a.action);

  for (const turn of sortedTurns) {
    const callIds: string[] = [];

    if (turn.role === "user") {
      textTokensIn += estimateTokens(turn.text);
      audioSeconds += turn.audioSeconds ?? 0;
      turns.push({ i: turn.i, role: turn.role, text: turn.text, toolCallIds: callIds, prompted: turn.prompted === true });
    } else {
      textTokensOut += estimateTokens(turn.text);
      const cancelled = new Set(turn.cancelled ?? []);
      for (const call of turn.toolCalls ?? []) {
        callIds.push(call.id);
        const abort = cancelled.has(call.id) ? { aborted: () => true } : undefined;
        const dispatch = runtime.dispatch(
          { id: call.id, name: call.name, ...(call.args !== undefined ? { args: { ...call.args } } : {}) },
          abort
        );
        toolCalls.push({
          id: dispatch.id,
          name: dispatch.name,
          args: dispatch.args,
          result: dispatch.result,
          status: dispatch.status,
          ...(dispatch.dupOf !== undefined ? { dupOf: dispatch.dupOf } : {})
        });
        recordSideStreams(dispatch, turn.i, answers, camera, (frames) => {
          framesSent += frames;
        });
        const proposalId = extractProposalId(dispatch.result);
        if (proposalId) proposalByCallId.set(call.id, proposalId);
      }
      turns.push({
        i: turn.i,
        role: turn.role,
        text: turn.text,
        toolCallIds: callIds,
        prompted: turn.prompted === true
      });
    }

    // Scripted user/device actions after this turn.
    for (const action of actionsFor(turn.i)) {
      switch (action.kind) {
        case "approve": {
          const proposalId = proposalByCallId.get(action.callId);
          if (proposalId) phone.userApproves(proposalId);
          // An unknown callId is a script bug — surface it loudly rather than
          // silently approving nothing.
          else throw new Error(`script approve: callId "${action.callId}" never produced a proposal`);
          break;
        }
        case "reject": {
          const proposalId = proposalByCallId.get(action.callId);
          if (proposalId) phone.userRejects(proposalId);
          else throw new Error(`script reject: callId "${action.callId}" never produced a proposal`);
          break;
        }
        case "advanceMinutes":
          if ("advanceMs" in clock && typeof clock.advanceMs === "function") clock.advanceMs(action.minutes * 60_000);
          else throw new Error("script advanceMinutes needs an advancing clock");
          phone.tickTimers();
          break;
        case "kill":
          killedMs = clock.nowMs();
          phone.killApp();
          break;
        case "resume":
          if (killedMs !== null) {
            killedTotalMs += clock.nowMs() - killedMs;
            killedMs = null;
          }
          phone.resumeApp();
          break;
        case "offline":
          phone.goOffline();
          break;
        case "reconnect":
          phone.reconnect();
          break;
      }
    }
  }

  const endMs = clock.nowMs();
  const connectedMs = endMs - startMs - killedTotalMs;
  return {
    turns,
    toolCalls,
    proposalByCallId,
    answers,
    camera,
    usage: {
      turns: turns.length,
      textTokensIn,
      textTokensOut,
      audioSeconds: Math.round(audioSeconds * 1000) / 1000,
      framesSent,
      connectedSeconds: Math.round(connectedMs / 1000)
    }
  };
}

function extractProposalId(result: unknown): string | null {
  if (typeof result !== "object" || result === null) return null;
  const rec = result as Record<string, unknown>;
  return typeof rec["proposalId"] === "string" ? rec["proposalId"] : null;
}

function recordSideStreams(
  dispatch: DispatchResult,
  turnIndex: number,
  answers: ReplayAnswer[],
  camera: ReplayCameraEvent[],
  addFrames: (frames: number) => void
): void {
  if (dispatch.name === "checkFoodSafety" && dispatch.status === "ok") {
    const rec = dispatch.result as { answer: FoodSafetyAnswer };
    if (rec.answer.kind === "sourced-check") {
      const check: SourcedCheck = rec.answer.check;
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
    addFrames(rec.look.framesSent);
    camera.push({
      look: true,
      framesSent: rec.look.framesSent,
      clipSeconds: rec.look.clipSeconds,
      observed: rec.look.observed,
      cannotAssess: rec.look.cannotAssess,
      safetyVerdict: null
    });
  }
}
