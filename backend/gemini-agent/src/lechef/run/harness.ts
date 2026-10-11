/**
 * Run harness — runs design x session against the fake provider + fake
 * phone and emits one RunRecord per session. The RunRecord shape is PINNED:
 * the Part 2 Python scorer consumes exactly this. The harness emits RAW
 * records only — it computes no job success, no safety verdicts, and no
 * approval judgements; the scorer owns those.
 *
 * Timestamps in the RunRecord are ISO 8601 strings (evaluation layer). The
 * wire layer (ActionProposal/ActionReceipt bytes) stays in epoch seconds —
 * see lechef/README.md, "Timestamps".
 */

import type { CameraMode } from "../types.js";
import { FakePhone } from "../fakePhone.js";
import type { CameraDevice } from "../reads.js";
import { createLeChefRuntime } from "../runtime.js";
import {
  replayScript,
  type LeChefJob,
  type ReplayAnswer,
  type ReplayCameraEvent,
  type ReplayToolCall,
  type ReplayUsage,
  type ScriptFixture,
  type ScriptFixtureCamera,
  type SessionScript
} from "../fakeModel.js";
import { ManualClock } from "./clock.js";

export interface RunRecord {
  readonly sessionId: string;
  readonly job: LeChefJob;
  readonly cameraMode: CameraMode;
  readonly design: string;
  readonly turns: readonly {
    readonly i: number;
    readonly role: "user" | "assistant";
    readonly text: string;
    readonly toolCallIds: readonly string[];
    readonly prompted: boolean;
  }[];
  readonly toolCalls: readonly {
    readonly id: string;
    readonly name: string;
    readonly args: Readonly<Record<string, unknown>>;
    readonly result: unknown;
    readonly status: ReplayToolCall["status"];
    readonly dupOf?: string;
  }[];
  readonly proposals: readonly {
    readonly id: string;
    readonly tool: string;
    readonly payload: unknown;
    readonly payloadHash: string;
    readonly requiredApproval: "device-auto" | "explicit";
    readonly userInitiated: boolean;
    readonly state: "proposed" | "approved" | "executed" | "rejected" | "cancelled" | "expired";
  }[];
  readonly receipts: readonly {
    readonly proposalID: string;
    readonly state: "executed" | "rejected" | "expired" | "cancelled";
    readonly recordedAt: string;
  }[];
  readonly timers: readonly {
    readonly label: string;
    readonly minutes: number;
    readonly proposalId: string;
    readonly createdAt: string;
    readonly deadline: string;
    readonly firedAt?: string;
    readonly survivedKill: boolean;
  }[];
  readonly events: readonly { readonly kind: string; readonly at: string }[];
  readonly answers: readonly ReplayAnswer[];
  readonly camera: readonly ReplayCameraEvent[];
  readonly usage: ReplayUsage;
}

function iso(epochSecondsValue: number): string {
  return new Date(epochSecondsValue * 1000).toISOString();
}

/** Canned camera device built from the script fixture; no model, no verdicts. */
export function cannedCamera(fixture: ScriptFixtureCamera, mode: CameraMode): CameraDevice {
  return {
    mode,
    capture(input: { maxClipSeconds: number }) {
      return {
        observed: [...fixture.observed],
        cannotAssess: [...fixture.cannotAssess],
        framesSent: fixture.framesPerLook,
        clipSeconds: Math.min(fixture.clipSeconds, input.maxClipSeconds)
      };
    }
  };
}

/** One offline session: script → replay → raw RunRecord. Deterministic. */
export function runSession(script: SessionScript): RunRecord {
  const fixture: ScriptFixture = script.fixture ?? {};
  const startMs = fixture.nowIso !== undefined ? Date.parse(fixture.nowIso) : undefined;
  const clock = new ManualClock(startMs !== undefined && !Number.isNaN(startMs) ? startMs : undefined);
  const phone = new FakePhone({
    clock,
    ...(fixture.pantry !== undefined ? { pantry: fixture.pantry } : {}),
    ...(fixture.session !== undefined ? { session: fixture.session } : {})
  });
  const camera = fixture.camera ? cannedCamera(fixture.camera, script.cameraMode) : undefined;

  const runtime = createLeChefRuntime({
    clock,
    phone,
    catalog: () => fixture.recipes ?? [],
    ...(camera !== undefined ? { camera } : {})
  });

  const replay = replayScript(script, runtime, phone, clock);

  const proposals = runtime.proposals.proposals().map((p) => ({
    id: p.id,
    tool: p.tool,
    payload: p.payload,
    payloadHash: p.payloadHash,
    requiredApproval: p.requiredApproval,
    userInitiated: p.userInitiated,
    state: runtime.proposals.stateOf(p.id)
  }));

  const receipts = phone.receipts().map((r) => ({
    proposalID: r.proposalID,
    state: r.state,
    recordedAt: iso(r.recordedAt)
  }));

  const timers = phone.timerRecords().map((t) => ({
    label: t.label,
    minutes: t.minutes,
    proposalId: t.proposalId,
    createdAt: iso(t.createdAt),
    deadline: iso(t.deadline),
    ...(t.firedAt !== undefined ? { firedAt: iso(t.firedAt) } : {}),
    survivedKill: t.survivedKill
  }));

  const events = phone
    .events()
    .map((e) => ({ kind: e.kind, at: iso(e.at) }))
    .sort((a, b) => (a.at === b.at ? a.kind.localeCompare(b.kind) : a.at.localeCompare(b.at)));

  return {
    sessionId: script.sessionId,
    job: script.job,
    cameraMode: script.cameraMode,
    design: script.design,
    turns: replay.turns,
    toolCalls: replay.toolCalls,
    proposals,
    receipts,
    timers,
    events,
    answers: replay.answers,
    camera: replay.camera,
    usage: replay.usage
  };
}
