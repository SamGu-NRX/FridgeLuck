import { describe, it, expect } from "bun:test";
import { createProposalLayer } from "../../lechef/proposals.js";
import { FakePhone } from "../../lechef/fakePhone.js";
import { ManualClock } from "../../lechef/run/clock.js";
import { payloadHash } from "../../lechef/wire.js";
import { PROPOSAL_TTL_SECONDS } from "../../lechef/types.js";
import type { PantryLine } from "../../lechef/types.js";

function harness() {
  const clock = new ManualClock(Date.UTC(2026, 0, 1, 18, 0, 0));
  const pantry: PantryLine[] = [
    { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 6, unit: "piece" }, state: "sufficient", source: "scan" }
  ];
  const phone = new FakePhone({ clock, pantry, session: { state: "cooking", currentStepIndex: 1 } });
  const layer = createProposalLayer({ clock, phone, idPrefix: "p" });
  return { clock, phone, layer };
}

describe("proposal layer: proposing never executes", () => {
  it("explicit proposals stay pending until a scripted user action approves them", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "less salt next time", scope: "recipe" });
    // Created, hashed, submitted — and nothing more.
    expect(out.proposal).not.toBeNull();
    expect(out.state).toBe("proposed");
    expect(phone.pendingProposalIds()).toContain(out.proposal!.id);
    expect(phone.receipts()).toHaveLength(0); // no receipt: nothing executed
    expect(phone.noteRecords()).toHaveLength(0); // the note does not exist yet
  });

  it("no proposal from any propose* call self-executes a pantry or session change", () => {
    const { phone, layer } = harness();
    const before = phone.pantrySnapshot();
    const stepBefore = phone.sessionSnapshot().currentStepIndex;
    layer.proposeStepAdvance({ callId: "c1", stepIndex: 2 });
    layer.proposeInventoryCorrection({ callId: "c2", ingredientId: "egg", name: "Eggs", observedState: "short", reason: "used two" });
    layer.proposeSaveNote({ callId: "c3", text: "x", scope: "cook" });
    // The revision is untouched — a revision bump means SOMETHING executed.
    expect(phone.pantrySnapshot().revision).toBe(before.revision);
    expect(phone.sessionSnapshot().currentStepIndex).toBe(stepBefore);
  });

  it("device-auto applies to device-initiated timers only; the phone executes them by its own rule", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a nine minute egg timer" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "boil eggs", minutes: 9, userInitiation: { eventId: cmd.id } });
    expect(out.proposal!.requiredApproval).toBe("device-auto");
    expect(out.proposal!.userInitiated).toBe(true);
    expect(out.proposal!.userInitiation?.eventId).toBe(cmd.id);
    // The PHONE's timer rule approved and executed it — the layer never did.
    expect(out.state).toBe("executed");
    expect(phone.receiptFor(out.proposal!.id)?.state).toBe("executed");
    expect(phone.activeTimers()).toHaveLength(1);
  });

  it("a timer the model invented on its own is explicit, not device-auto", () => {
    const { phone, layer } = harness();
    // No device event cited — a bare flag in the input would be an untrusted claim.
    const out = layer.proposeTimerStart({ callId: "c1", label: "rest the steak", minutes: 5 });
    expect(out.proposal!.requiredApproval).toBe("explicit");
    expect(out.proposal!.userInitiated).toBe(false);
    expect(out.proposal!.userInitiation).toBeUndefined();
    expect(phone.activeTimers()).toHaveLength(0); // nothing ran
  });

  it("meal logs always require explicit approval, even for a direct voice command", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeMealLog", source: "voice", detail: "log this meal" });
    const out = layer.proposeMealLog({
      callId: "c1",
      userInitiation: { eventId: cmd.id }, // "log this meal" — the device recorded the user saying it
      recipeId: "carbonara",
      revision: 1,
      servings: 2,
      sourcedFrom: "voice"
    });
    // SPEC 4: a voice transcript alone never authorizes a meal log.
    expect(out.proposal!.requiredApproval).toBe("explicit");
    expect(out.proposal!.userInitiated).toBe(true);
    expect(phone.proposalState(out.proposal!.id)).toBe("proposed");
    expect(phone.mealLogRecords()).toHaveLength(0);
    // The scripted user must approve.
    phone.userApproves(out.proposal!.id);
    expect(phone.mealLogRecords()).toHaveLength(1);
    expect(phone.mealLogRecords()[0].sourcedFrom).toBe("voice");
  });
});

describe("proposal layer: idempotency", () => {
  it("a duplicate call id never produces a second live proposal", () => {
    const { phone, layer } = harness();
    const first = layer.proposeSaveNote({ callId: "c1", text: "watch the garlic", scope: "cook" });
    const again = layer.proposeSaveNote({ callId: "c1", text: "watch the garlic", scope: "cook" });
    expect(again.duplicateOf).toBe(first.proposal!.id);
    expect(again.proposal!.id).toBe(first.proposal!.id); // the original stands
    expect(again.proposal!.id).not.toBe("p-0002"); // nothing new was minted
    expect(layer.proposals()).toHaveLength(1);
    expect(phone.pendingProposalIds()).toHaveLength(1);
  });

  it("identical payloads under different call ids dedupe onto the first", () => {
    const { layer } = harness();
    const first = layer.proposeSaveNote({ callId: "c1", text: "same", scope: "cook" });
    const second = layer.proposeSaveNote({ callId: "different-call", text: "same", scope: "cook" });
    expect(second.duplicateOf).toBe(first.proposal!.id);
    expect(second.proposal!.id).toBe(first.proposal!.id);
    expect(layer.proposals()).toHaveLength(1);
  });

  it("different payloads are genuinely different proposals", () => {
    const { layer } = harness();
    layer.proposeSaveNote({ callId: "c1", text: "one", scope: "cook" });
    const second = layer.proposeSaveNote({ callId: "c2", text: "two", scope: "cook" });
    expect(second.proposal).not.toBeNull();
    expect(layer.proposals()).toHaveLength(2);
  });
});

describe("proposal layer: cancellation", () => {
  it("a cancelled call never files a proposal with the phone", () => {
    const { phone, layer } = harness();
    const out = layer.proposeSaveNote({
      callId: "c1",
      text: "never lands",
      scope: "cook",
      abort: { aborted: () => true }
    });
    expect(out.proposal).toBeNull();
    expect(out.state).toBe("cancelled");
    expect(phone.pendingProposalIds()).toHaveLength(0);
    expect(layer.proposals()).toHaveLength(0);
  });

  it("a call cancelled mid-flight (after hashing, before submit) is stopped too", () => {
    // Abort is polled at entry and again at the point of no return, after the
    // payload is built and hashed but before the phone sees anything.
    const { phone, layer } = harness();
    let polls = 0;
    const out = layer.proposeSaveNote({
      callId: "c1",
      text: "nope",
      scope: "cook",
      abort: { aborted: () => ++polls >= 2 }
    });
    expect(out.proposal).toBeNull();
    expect(out.state).toBe("cancelled");
    expect(polls).toBe(2); // entry passed, pre-submit tripped
    expect(phone.pendingProposalIds()).toHaveLength(0);
  });

  it("a cancelled call leaves no dedupe trace — a retry may propose fresh", () => {
    const { phone, layer } = harness();
    layer.proposeSaveNote({ callId: "c1", text: "dropped", scope: "cook", abort: { aborted: () => true } });
    const retry = layer.proposeSaveNote({ callId: "c1", text: "dropped", scope: "cook" });
    expect(retry.state).toBe("proposed");
    expect(retry.proposal).not.toBeNull();
    expect(phone.pendingProposalIds()).toHaveLength(1);
  });
});

describe("proposal layer: receipts, hashing, expiry", () => {
  it("carries a canonical payloadHash and matches the wire hash helper", () => {
    const { layer } = harness();
    const out = layer.proposeTimerStart({ callId: "c1", label: "eggs", minutes: 6 });
    expect(out.proposal!.payloadHash).toBe(payloadHash({ kind: "timerStart", label: "eggs", minutes: 6 }));
  });

  it("stamps snapshotRevision from the phone and a TTL of 300s", () => {
    const { layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "n", scope: "cook" });
    expect(out.proposal!.snapshotRevision).toBe(1);
    expect(out.proposal!.expiresAt - out.proposal!.createdAt).toBe(PROPOSAL_TTL_SECONDS);
  });

  it("executed receipts record the post-execution revision", () => {
    const { phone, layer } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    const out = layer.proposeTimerStart({ callId: "c1", label: "eggs", minutes: 6, userInitiation: { eventId: cmd.id } });
    const receipt = phone.receiptFor(out.proposal!.id)!;
    expect(receipt.state).toBe("executed");
    expect(receipt.snapshotRevision).toBe(2); // bumped by the timer creation
  });

  it("approval after expiry records expired, not executed", () => {
    const { clock, phone, layer } = harness();
    const out = layer.proposeSaveNote({ callId: "c1", text: "late", scope: "cook" });
    clock.advanceMs((PROPOSAL_TTL_SECONDS + 10) * 1000);
    phone.userApproves(out.proposal!.id);
    expect(phone.receiptFor(out.proposal!.id)?.state).toBe("expired");
    expect(phone.noteRecords()).toHaveLength(0);
  });
});
