import { describe, it, expect } from "bun:test";
import { FakePhone, PhoneOfflineError } from "../../lechef/fakePhone.js";
import { createProposalLayer } from "../../lechef/proposals.js";
import { ManualClock } from "../../lechef/run/clock.js";
import { payloadHash } from "../../lechef/wire.js";
import { PROPOSAL_TTL_SECONDS } from "../../lechef/types.js";
import type { ActionProposal, PantryLine } from "../../lechef/types.js";

function harness(options?: { pantry?: PantryLine[]; rePresent?: boolean }) {
  const clock = new ManualClock(Date.UTC(2026, 0, 1, 18, 0, 0));
  const phone = new FakePhone({
    clock,
    pantry: options?.pantry ?? [
      { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 6, unit: "piece" }, state: "sufficient", source: "scan" }
    ],
    session: { state: "cooking", currentStepIndex: 0 },
    ...(options?.rePresent !== undefined ? { rePresentPendingOnKill: options.rePresent } : {})
  });
  const layer = createProposalLayer({ clock, phone, idPrefix: "p" });
  return { clock, phone, layer };
}

describe("fake phone: device-owned timer deadlines", () => {
  it("executes an approved user timer with an absolute deadline", () => {
    const { clock, phone, layer } = harness();
    const start = Math.floor(clock.nowMs() / 1000);
    // User initiation is a device event the phone recorded (SPEC 4), cited by the proposal.
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a nine minute egg timer" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "boil eggs", minutes: 9, userInitiation: { eventId: cmd.id } });
    const timer = phone.activeTimers()[0];
    expect(timer.deadline).toBe(start + 9 * 60);
    expect(timer.proposalId).toBe(out.proposal!.id);
    expect(phone.receiptFor(out.proposal!.id)!.state).toBe("executed");
  });

  it("fires timers by absolute deadline even when the tick is late (kill-app resume)", () => {
    const { clock, phone, layer } = harness();
    const start = Math.floor(clock.nowMs() / 1000);
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    layer.proposeTimerStart({ callId: "c1", label: "boil eggs", minutes: 10, userInitiation: { eventId: cmd.id } });
    clock.advanceMs(5 * 60 * 1000); // halfway
    phone.killApp(); // the app dies
    clock.advanceMs(10 * 60 * 1000); // deadline passes while dead
    expect(phone.activeTimers()).toHaveLength(1); // still there, unfired
    phone.resumeApp(); // on resume the deadline is honored...
    expect(phone.activeTimers()).toHaveLength(0);
    const timer = phone.timerRecords()[0];
    expect(timer.firedAt).toBe(start + 10 * 60); // ...at the ORIGINAL deadline
    expect(timer.survivedKill).toBe(true);
  });

  it("records a killed timer as survivedKill with its deadline intact", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    layer.proposeTimerStart({ callId: "c1", label: "rest steak", minutes: 3, userInitiation: { eventId: cmd.id } });
    phone.killApp();
    expect(phone.timerRecords()[0].survivedKill).toBe(true);
    expect(phone.timerRecords()[0].deadline).toBeGreaterThan(0);
  });

  it("adjusts a live timer by delta and by set — elapsed time counts for delta only (review fix 7)", () => {
    const { clock, phone, layer } = harness();
    const start = Math.floor(clock.nowMs() / 1000);
    const cmdStart = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "sauce", minutes: 10, userInitiation: { eventId: cmdStart.id } });
    clock.advanceMs(4 * 60 * 1000); // four minutes of cooking elapse before the user speaks
    const timerId = phone.activeTimers()[0].timerId;
    const cmdDelta = phone.recordUserCommand({ command: "proposeTimerAdjust", source: "voice", detail: "add five minutes" });
    const adj = layer.proposeTimerAdjust({ callId: "c2", timerId, deltaMinutes: 5, userInitiation: { eventId: cmdDelta.id } });
    expect(adj.state).toBe("executed");
    // The device-owned deadline extends from where the timer actually was
    // (start + 10 min), not from now — the four elapsed minutes still count.
    expect(phone.timerRecords()[0].deadline).toBe(start + 15 * 60);
    expect(phone.timerRecords()[0].minutes).toBe(15);
    const now = Math.floor(clock.nowMs() / 1000);
    const cmdSet = phone.recordUserCommand({ command: "proposeTimerAdjust", source: "touch" });
    const set = layer.proposeTimerAdjust({ callId: "c3", timerId, newMinutes: 2, userInitiation: { eventId: cmdSet.id } });
    expect(set.state).toBe("executed");
    // A set is a fresh start: now + the new duration.
    expect(phone.timerRecords()[0].deadline).toBe(now + 2 * 60);
    expect(phone.timerRecords()[0].minutes).toBe(2);
    expect(out.proposal).not.toBeNull();
  });

  it("adjusting an unknown timer is rejected, not executed", () => {
    const { phone, layer } = harness();
    const out = layer.proposeTimerAdjust({ callId: "c1", timerId: "nope", newMinutes: 5 });
    expect(out.state).toBe("proposed"); // explicit: the well-formed proposal waits for the user
    phone.userApproves(out.proposal!.id);
    // The phone refuses at execution time — an unknown timer never silently no-ops.
    expect(phone.receiptFor(out.proposal!.id)!.state).toBe("rejected");
    expect(phone.activeTimers()).toHaveLength(0);
  });
});

describe("fake phone: revision and mutations", () => {
  it("bumps the revision on every executed mutation", () => {
    const { phone, layer } = harness();
    const before = phone.revision();
    const step = layer.proposeStepAdvance({ callId: "c1", stepIndex: 2 });
    phone.userApproves(step.proposal!.id); // explicit approval, then the phone executes
    const afterStep = phone.revision();
    expect(afterStep).toBeGreaterThan(before);
    const corr = layer.proposeInventoryCorrection({
      callId: "c2",
      ingredientId: "egg",
      name: "Eggs",
      observedQuantity: { kind: "known", value: 2, unit: "piece" },
      reason: "used four"
    });
    phone.userApproves(corr.proposal!.id);
    expect(phone.revision()).toBeGreaterThan(afterStep);
    expect(phone.pantrySnapshot().items[0].quantity).toEqual({ kind: "known", value: 2, unit: "piece" });
  });

  it("advances the step and records history after approval", () => {
    const { phone, layer } = harness();
    const out = layer.proposeStepAdvance({ callId: "c1", stepIndex: 3 });
    expect(phone.sessionSnapshot().currentStepIndex).toBe(0); // proposed only
    phone.userApproves(out.proposal!.id);
    expect(phone.sessionSnapshot().currentStepIndex).toBe(3);
    expect(phone.sessionSnapshot().stepHistory).toEqual([{ stepIndex: 0, at: expect.any(Number), action: "advanced" }]);
  });

  it("rejects a pending proposal on user action and records the receipt", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" });
    phone.userRejects(out.proposal!.id);
    expect(phone.receiptFor(out.proposal!.id)!.state).toBe("rejected");
    expect(phone.pendingProposalIds()).toHaveLength(0);
  });
});

describe("fake phone: expiry and re-presentation", () => {
  it("expires pending proposals past their TTL", () => {
    const { clock, phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" });
    clock.advanceMs(301 * 1000);
    expect(phone.proposalState(out.proposal!.id)).toBe("expired");
  });

  it("re-presents pending proposals on kill when configured", () => {
    const { phone, layer } = harness({ rePresent: true });
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" });
    phone.killApp();
    const events = phone.events().map((e) => e.detail);
    expect(events.some((d) => d.includes(`${out.proposal!.id} re-presented`))).toBe(true);
  });
});

describe("fake phone: offline and reconnect", () => {
  it("rejects snapshot reads and submissions while offline", () => {
    const { phone, layer } = harness();
    phone.goOffline();
    expect(() => phone.pantrySnapshot()).toThrow(PhoneOfflineError);
    expect(() => phone.sessionSnapshot()).toThrow(PhoneOfflineError);
    expect(() =>
      layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" })
    ).toThrow(PhoneOfflineError);
    expect(layer.proposals()).toHaveLength(0); // nothing half-filed
  });

  it("reconnects and re-reads bounded snapshots at the new revision", () => {
    const { clock, phone, layer } = harness();
    const corr = layer.proposeInventoryCorrection({
      callId: "pre",
      ingredientId: "egg",
      name: "Eggs",
      observedState: "short",
      reason: "test prep"
    });
    phone.userApproves(corr.proposal!.id); // executes → revision 2, eggs short
    phone.goOffline();
    // While offline the kitchen keeps living; on reconnect callers re-read snapshots.
    clock.advanceMs(60 * 1000);
    phone.reconnect();
    const snap = phone.pantrySnapshot();
    expect(snap.revision).toBeGreaterThanOrEqual(2);
    expect(snap.items[0].state).toBe("short");
  });
});
describe("fake phone: the phone owns approval policy (review fix 2)", () => {
  /** Craft a proposal directly, bypassing the model layer — the forgery path. */
  function craft(proposal: ActionProposal): ActionProposal {
    return proposal;
  }

  it("a forged device-auto meal log never executes — the proposal's approval class is a claim, not authority", () => {
    const { phone, layer } = harness();
    const payload = { kind: "mealLog" as const, recipeId: "carbonara", revision: 1, servings: 2, swaps: [], sourcedFrom: "voice" as const };
    const forged = craft({
      id: "forged-1",
      tool: "proposeMealLog",
      payload,
      payloadHash: payloadHash(payload),
      snapshotRevision: phone.revision(),
      createdAt: Math.floor(phone.pantrySnapshot().capturedAt),
      expiresAt: Math.floor(phone.pantrySnapshot().capturedAt) + PROPOSAL_TTL_SECONDS,
      requiredApproval: "device-auto", // the model's claim
      userInitiated: true
    });
    phone.submitProposal(forged);
    // The phone's own policy: meal logs are never device-auto, whatever they claim.
    expect(phone.proposalState("forged-1")).toBe("proposed");
    expect(phone.mealLogRecords()).toHaveLength(0);
    expect(phone.receipts()).toHaveLength(0);
    expect(layer.proposals()).toHaveLength(0); // the layer never saw it — the phone downgraded it
  });

  it("a forged device-auto timer with a fabricated citation never executes", () => {
    const { phone, layer } = harness();
    const payload = { kind: "timerStart" as const, label: "invented", minutes: 30 };
    const forged = craft({
      id: "forged-2",
      tool: "proposeTimerStart",
      payload,
      payloadHash: payloadHash(payload),
      snapshotRevision: phone.revision(),
      createdAt: Math.floor(phone.pantrySnapshot().capturedAt),
      expiresAt: Math.floor(phone.pantrySnapshot().capturedAt) + PROPOSAL_TTL_SECONDS,
      requiredApproval: "device-auto",
      userInitiated: true,
      userInitiation: { eventId: "cmd-0001" } // no such device event was ever recorded
    });
    phone.submitProposal(forged);
    expect(phone.proposalState("forged-2")).toBe("proposed"); // explicit: waits for the user
    expect(phone.activeTimers()).toHaveLength(0);
  });

  it("an honest citation still runs: the phone validates the device event itself", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a two minute timer" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "eggs", minutes: 2, userInitiation: { eventId: cmd.id } });
    expect(out.state).toBe("executed"); // defense in depth, not a regression
    expect(phone.activeTimers()).toHaveLength(1);
  });

  it("one device command initiates one action — a consumed event cannot run a second proposal", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    const first = layer.proposeTimerStart({ callId: "c1", label: "eggs", minutes: 2, userInitiation: { eventId: cmd.id } });
    expect(first.state).toBe("executed");
    const second = layer.proposeTimerStart({ callId: "c2", label: "more eggs", minutes: 5, userInitiation: { eventId: cmd.id } });
    expect(second.state).toBe("proposed"); // the citation is spent
    expect(phone.activeTimers()).toHaveLength(1);
  });

  it("an approval for an altered payload is refused: the hash binding holds", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "less salt", scope: "cook" });
    const proposal = out.proposal!;
    // Tamper in place after filing — the pending record must no longer match its hash.
    (proposal.payload as { text: string }).text = "BUY LOTTERY TICKETS";
    phone.userApproves(proposal.id);
    const receipt = phone.receiptFor(proposal.id)!;
    expect(receipt.state).toBe("rejected");
    expect(receipt.reason).toMatch(/hash/i);
    expect(phone.noteRecords()).toHaveLength(0); // the altered text never landed
  });

  it("an approval for a superseded revision is refused: the revision binding holds", () => {
    const { phone, layer } = harness();
    const a = layer.proposeSaveNote({ callId: "c1", text: "first", scope: "cook" }).proposal!;
    const b = layer.proposeSaveNote({ callId: "c2", text: "second", scope: "cook" }).proposal!;
    phone.userApproves(a.id); // executes, bumping the snapshot revision
    expect(phone.noteRecords()[0].text).toBe("first");
    phone.userApproves(b.id); // b was built at the old revision
    const receipt = phone.receiptFor(b.id)!;
    expect(receipt.state).toBe("rejected");
    expect(receipt.reason).toMatch(/revision|superseded/i);
    expect(phone.noteRecords()).toHaveLength(1); // the stale proposal never executed
    expect(phone.pendingProposalIds()).toHaveLength(0);
  });

  it("a delta adjustment on a nearly-done timer extends the true deadline, never restarts the clock (review fix 7)", () => {
    const { clock, phone, layer } = harness();
    const start = Math.floor(clock.nowMs() / 1000);
    const cmdStart = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    layer.proposeTimerStart({ callId: "c1", label: "rest", minutes: 10, userInitiation: { eventId: cmdStart.id } });
    clock.advanceMs(9 * 60 * 1000); // nine of ten minutes gone — one minute left
    const timerId = phone.activeTimers()[0].timerId;
    const cmdAdj = phone.recordUserCommand({ command: "proposeTimerAdjust", source: "touch" });
    const adj = layer.proposeTimerAdjust({ callId: "c2", timerId, deltaMinutes: 5, userInitiation: { eventId: cmdAdj.id } });
    expect(adj.state).toBe("executed");
    // "add five minutes" to a timer with one minute left leaves six minutes:
    // start + 10 + 5 — not now + 15 (which would gift nine uncooked minutes).
    expect(phone.timerRecords()[0].deadline).toBe(start + 15 * 60);
  });

  it("a replayed approval for a consumed proposal is refused with a receipt that says why", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" }).proposal!;
    phone.userApproves(out.id);
    expect(phone.receiptFor(out.id)!.state).toBe("executed");
    phone.userApproves(out.id); // replay
    const refusals = phone.receipts().filter((r) => r.proposalID === out.id && r.state === "rejected");
    expect(refusals).toHaveLength(1);
    expect(refusals[0].reason).toMatch(/consumed|replay/i);
    expect(phone.noteRecords()).toHaveLength(1); // executed exactly once
  });

  it("a resubmitted consumed proposal id is refused with a receipt that says why", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" }).proposal!;
    phone.userApproves(out.id);
    const again = craft({ ...out });
    phone.submitProposal(again);
    const refusals = phone.receipts().filter((r) => r.proposalID === out.id && r.state === "rejected");
    expect(refusals).toHaveLength(1);
    expect(refusals[0].reason).toMatch(/consumed|resubmission/i);
    expect(phone.pendingProposalIds()).toHaveLength(0);
    expect(phone.receiptFor(out.id)!.state).toBe("executed"); // the original receipt stands
  });
});
