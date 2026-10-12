import { describe, it, expect } from "bun:test";
import { FakePhone, PhoneOfflineError } from "../../lechef/fakePhone.js";
import { createProposalLayer } from "../../lechef/proposals.js";
import { ManualClock } from "../../lechef/run/clock.js";
import type { PantryLine } from "../../lechef/types.js";

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

  it("adjusts a live timer by delta and by set", () => {
    const { clock, phone, layer } = harness();
    const start = Math.floor(clock.nowMs() / 1000);
    const cmdStart = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "sauce", minutes: 10, userInitiation: { eventId: cmdStart.id } });
    const timerId = phone.activeTimers()[0].timerId;
    const cmdDelta = phone.recordUserCommand({ command: "proposeTimerAdjust", source: "voice", detail: "add five minutes" });
    const adj = layer.proposeTimerAdjust({ callId: "c2", timerId, deltaMinutes: 5, userInitiation: { eventId: cmdDelta.id } });
    expect(adj.state).toBe("executed");
    expect(phone.timerRecords()[0].deadline).toBe(start + 15 * 60);
    const cmdSet = phone.recordUserCommand({ command: "proposeTimerAdjust", source: "touch" });
    const set = layer.proposeTimerAdjust({ callId: "c3", timerId, newMinutes: 2, userInitiation: { eventId: cmdSet.id } });
    expect(set.state).toBe("executed");
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
