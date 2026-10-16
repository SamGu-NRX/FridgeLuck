/**
 * Suite runner (SPEC §7): executes each scripted session against the real
 * runtime + FakePhone with a ManualClock, records a RunRecord, and applies
 * the scripted user actions (approvals, clock advances, device events,
 * kills/relaunches). Deterministic: same script in, same RunRecord out.
 */

import { FakePhone } from "../fakePhone.js";
import { LeChefRuntime, REGISTERED_TOOLS } from "../runtime.js";
import { ManualClock } from "../run/clock.js";
import type { ActionReceiptWire, ActionProposalWire, ProposalTool } from "../types.js";
import { FakeModel, buildScripts, type ScriptedCall, type SuiteAction, type SuiteScript } from "./scripts.js";

export interface RecordedCall {
  readonly turn: number;
  readonly name: string;
  readonly args: Record<string, unknown>;
  readonly result: Record<string, unknown>;
}

export interface Resolution {
  readonly proposalID: string;
  readonly kind: string;
  /** How the proposal reached its terminal state. */
  readonly resolution: "approved-by-user" | "device-auto" | "rejected-by-user" | "expired" | "rejected-by-phone" | "still-pending";
  readonly receipt?: ActionReceiptWire;
}

export interface RunRecord {
  readonly scriptId: string;
  readonly job: SuiteScript["job"];
  readonly situation: string;
  readonly utterances: readonly string[];
  readonly calls: readonly RecordedCall[];
  readonly proposals: readonly ActionProposalWire[];
  readonly receipts: readonly ActionReceiptWire[];
  readonly resolutions: readonly Resolution[];
  /** Guard expectations attached to the script (safety-attack sessions); empty otherwise. */
  readonly guards: readonly import("./guards.js").GuardExpectation[];
  readonly cameraRefusals: number;
  readonly cameraVerdictsRelayed: number;
  /** Voice device events dropped because the session's mic is denied (situation "mic-denied"). */
  readonly micDeniedVoiceEventsDropped: number;
  readonly finalState: {
    readonly timers: number;
    readonly savedNotes: number;
    readonly loggedMeals: number;
    readonly pantryRevision: number;
    readonly currentStepIndex: number;
  };
}

const DEVICE_AUTO_KINDS = new Set(["timer_start", "timer_adjust"]);

export function runScript(script: SuiteScript): RunRecord {
  const clock = new ManualClock();
  const phone = new FakePhone({
    clock,
    items: [...script.fixture.items],
    eaters: script.fixture.eaters ?? [],
    recipes: script.fixture.recipes ?? [],
    ...(script.fixture.recipeId !== undefined ? { recipeId: script.fixture.recipeId } : {}),
    ...(script.fixture.sessionState !== undefined ? { sessionState: script.fixture.sessionState } : {}),
    ...(script.fixture.currentStepIndex !== undefined ? { currentStepIndex: script.fixture.currentStepIndex } : {}),
    ...(script.fixture.cameraMode !== undefined ? { cameraMode: script.fixture.cameraMode } : {}),
    ...(script.fixture.cameraScript !== undefined ? { cameraScript: script.fixture.cameraScript } : {}),
    ...(script.fixture.substituteNames !== undefined ? { substituteNames: script.fixture.substituteNames } : {})
  });
  const runtime = new LeChefRuntime({ phone, clock });
  const model = new FakeModel(script.turns);

  const utterances: string[] = [];
  const calls: RecordedCall[] = [];
  const proposals: ActionProposalWire[] = [];
  const pendingIds: string[] = [];
  const deviceAutoIds: string[] = [];
  let cameraRefusals = 0;
  let cameraVerdictsRelayed = 0;
  let micDeniedVoiceEventsDropped = 0;

  const dispatchCalls = (turnIndex: number, scripted: readonly ScriptedCall[] | undefined): void => {
    if (scripted === undefined) return;
    for (const call of scripted) {
      if (!REGISTERED_TOOLS.includes(call.name)) {
        calls.push({ turn: turnIndex, name: call.name, args: call.args ?? {}, result: { toolError: "unknown_tool" } });
        continue;
      }
      const result = runtime.dispatch(call.name, call.args ?? {});
      calls.push({ turn: turnIndex, name: call.name, args: call.args ?? {}, result });
      if (call.name.startsWith("propose") && result.submitted === true && typeof result.proposalID === "string") {
        const wire = parseProposalFromEvidence(result);
        if (wire !== null) proposals.push(wire);
        if (result.status === "pending_explicit_approval") pendingIds.push(result.proposalID);
        if (result.status === "resolved") deviceAutoIds.push(result.proposalID);
      }
      if (call.name === "cameraLook") {
        if (result.refused === true) cameraRefusals++;
        const observation = result.observation as { observed?: readonly string[] } | null;
        if (observation?.observed?.some((o) => /\bsafe\b|\bunsafe\b|cooked through/i.test(o))) cameraVerdictsRelayed++;
      }
    }
  };

  const applyAction = (action: SuiteAction): void => {
    switch (action.kind) {
      case "approveAll":
        for (const id of [...pendingIds]) {
          phone.approve(id);
        }
        break;
      case "rejectAll":
        for (const id of [...pendingIds]) {
          phone.reject(id);
        }
        break;
      case "advanceMinutes":
        clock.advanceMs(action.minutes * 60_000);
        break;
      case "deviceEvent":
        // Mic-denied sessions: a voice command is never transcribed, so it
        // never reaches the phone — the attempt is dropped and counted.
        if (script.situation === "mic-denied" && action.source === "voice") {
          micDeniedVoiceEventsDropped++;
          break;
        }
        // Deterministic id: the scripted model cites it via userInitiationEventId.
        phone.recordDeviceEvent({ id: `evt-${action.command}-${action.source}`, command: action.command as ProposalTool, source: action.source, ...(action.detail !== undefined ? { detail: action.detail } : {}) });
        break;
      case "bumpRevision":
        phone.bumpRevision();
        break;
      case "killAndRelaunch":
        phone.relaunch(phone.receipts());
        break;
      case "goOffline":
        phone.goOffline();
        break;
      case "resubmitLast": {
        // Re-submit the last submitted proposal WIRE unchanged (same
        // proposalID): the phone must return the existing receipt and never
        // re-execute. The wire comes from the tool's acceptance-record
        // evidence, exactly as a replaying client would hold it.
        const last = proposals[proposals.length - 1];
        if (last !== undefined) phone.submitProposal(last);
        break;
      }
    }
  };

  for (let t = 0; t < model.turnCount; t++) {
    if (script.actions !== undefined) {
      for (const { afterTurn, action } of script.actions) {
        if (afterTurn === t - 1) applyAction(action); // afterTurn -1: before the session
      }
    }
    const turn = model.turn(t);
    utterances.push(turn.utterance ?? "");
    dispatchCalls(t, turn.calls);
    if (script.actions !== undefined) {
      for (const { afterTurn, action } of script.actions) {
        if (afterTurn === t) applyAction(action);
      }
    }
  }

  const receipts = [...phone.receipts().values()];
  const resolutions: Resolution[] = proposals.map((p) => {
    const receipt = receipts.find((r) => r.proposalID === p.proposalID);
    let resolution: Resolution["resolution"];
    if (receipt === undefined) resolution = "still-pending";
    else if (receipt.state === "executed") resolution = deviceAutoIds.includes(p.proposalID) ? "device-auto" : "approved-by-user";
    else if (receipt.state === "expired") resolution = "expired";
    else if (receipt.reason === "declined by the user") resolution = "rejected-by-user";
    else resolution = "rejected-by-phone";
    return { proposalID: p.proposalID, kind: p.kind, resolution, ...(receipt !== undefined ? { receipt } : {}) };
  });

  const state = phone.state();
  return {
    scriptId: script.id,
    job: script.job,
    situation: script.situation,
    utterances,
    calls,
    proposals,
    receipts,
    resolutions,
    guards: script.guards ?? [],
    cameraRefusals,
    cameraVerdictsRelayed,
    micDeniedVoiceEventsDropped,
    finalState: {
      timers: state.timers.length,
      savedNotes: state.savedNotes,
      loggedMeals: state.loggedMeals.length,
      pantryRevision: state.pantryRevision,
      currentStepIndex: state.currentStepIndex
    }
  };
}

/** Recover the wire envelope the tool serialized into its evidence. */
function parseProposalFromEvidence(result: Record<string, unknown>): ActionProposalWire | null {
  const evidence = result.evidence as { kind: string; detail?: string }[] | undefined;
  const record = evidence?.find((e) => e.kind === "acceptance-record");
  if (record?.detail === undefined) return null;
  try {
    return JSON.parse(record.detail) as ActionProposalWire;
  } catch {
    return null;
  }
}
