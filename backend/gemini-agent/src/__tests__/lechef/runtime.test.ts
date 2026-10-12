import { describe, it, expect } from "bun:test";
import { createLeChefRuntime, type LeChefRuntime } from "../../lechef/runtime.js";
import { FakePhone } from "../../lechef/fakePhone.js";
import { ManualClock } from "../../lechef/run/clock.js";
import type { PantryLine, RecipeContext } from "../../lechef/types.js";

const RECIPE: RecipeContext = {
  id: "eggs-on-toast",
  revision: 1,
  servings: 2,
  ingredientBill: [
    { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" } },
    { ingredientId: "bread", name: "Bread", quantity: { kind: "known", value: 2, unit: "piece" } }
  ],
  steps: [
    { index: 0, text: "Boil the eggs" },
    { index: 1, text: "Toast the bread", timerMinutes: 3 },
    { index: 2, text: "Assemble and season" }
  ]
};

const PANTRY: PantryLine[] = [
  { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 6, unit: "piece" }, state: "sufficient", source: "scan" },
  { ingredientId: "bread", name: "Bread", quantity: { kind: "known", value: 4, unit: "piece" }, state: "sufficient", source: "scan" }
];

function harness() {
  const clock = new ManualClock(Date.UTC(2026, 0, 1, 18, 0, 0));
  const phone = new FakePhone({
    clock,
    pantry: PANTRY.map((l) => ({ ...l })),
    session: { state: "cooking", currentStepIndex: 0, recipeId: "eggs-on-toast" }
  });
  const camera = {
    mode: "push-to-look" as const,
    capture({ maxClipSeconds }: { maxClipSeconds: number }) {
      return {
        observed: ["pan on the stove"],
        cannotAssess: ["doneness of the eggs"],
        framesSent: 2,
        clipSeconds: Math.min(2, maxClipSeconds)
      };
    }
  };
  const runtime = createLeChefRuntime({
    clock,
    phone,
    catalog: () => [RECIPE],
    camera
  });
  return { clock, phone, runtime };
}

describe("runtime: dispatch statuses", () => {
  it("unknown tool names return status error, never throw", () => {
    const { runtime } = harness();
    const r = runtime.dispatch({ id: "c1", name: "destroyKitchen", args: {} });
    expect(r.status).toBe("error");
  });

  it("read tools return results plus explicit evidence and unknowns", () => {
    const { runtime } = harness();
    const r = runtime.dispatch({ id: "c1", name: "getRecipeCandidates", args: { goal: "eggs on toast" } });
    expect(r.status).toBe("ok");
    const result = r.result as { candidates: { id: string; fit: { fitLine: string } }[]; evidence: unknown[]; unknowns: unknown[] };
    expect(result.candidates).toHaveLength(1);
    expect(result.unknowns).toEqual([]);
  });

  it("malformed arguments are status error and never touch the phone", () => {
    const { runtime, phone } = harness();
    for (const args of [{ label: "no minutes" }, { minutes: "soon" }, {}]) {
      const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args });
      expect(r.status).toBe("error");
    }
    expect(phone.pendingProposalIds()).toHaveLength(0);
    expect(phone.activeTimers()).toHaveLength(0);
  });

  it("cancelled dispatches produce status cancelled and nothing on the phone", () => {
    const { runtime, phone } = harness();
    const r = runtime.dispatch(
      { id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 5 } },
      { aborted: () => true }
    );
    expect(r.status).toBe("cancelled");
    expect(phone.pendingProposalIds()).toHaveLength(0);
    expect(phone.activeTimers()).toHaveLength(0);
  });
});

describe("runtime: reorder tolerance", () => {
  it("the same calls in a different order land in the same kitchen state", () => {
    const a = harness();
    const b = harness();
    // Step advances are explicit-approval proposals: approve them as a scripted user would.
    const advanceA = a.runtime.dispatch({ id: "a1", name: "proposeStepAdvance", args: { stepIndex: 2 } });
    a.phone.userApproves((advanceA.result as { proposalId: string }).proposalId);
    // User initiation is a device event the phone recorded (SPEC 4), cited by the proposal.
    const cmdA = a.phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a nine minute egg timer" });
    a.runtime.dispatch({ id: "a2", name: "proposeTimerStart", args: { label: "eggs", minutes: 9, deviceEventId: cmdA.id } });
    // Session B: timer first, then advance.
    const cmdB = b.phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a nine minute egg timer" });
    b.runtime.dispatch({ id: "b1", name: "proposeTimerStart", args: { label: "eggs", minutes: 9, deviceEventId: cmdB.id } });
    const advanceB = b.runtime.dispatch({ id: "b2", name: "proposeStepAdvance", args: { stepIndex: 2 } });
    b.phone.userApproves((advanceB.result as { proposalId: string }).proposalId);

    for (const { phone } of [a, b]) {
      expect(phone.sessionSnapshot().currentStepIndex).toBe(2);
      expect(phone.activeTimers()).toHaveLength(1);
      expect(phone.activeTimers()[0].label).toBe("eggs");
      expect(phone.activeTimers()[0].minutes).toBe(9);
    }
  });

  it("reads interleaved with writes stay coherent (read-your-latest-snapshot)", () => {
    const { runtime, phone } = harness();
    runtime.dispatch({ id: "r1", name: "getRecipeCandidates", args: { goal: "dinner" } });
    const w1 = runtime.dispatch({ id: "w1", name: "proposeStepAdvance", args: { stepIndex: 2 } });
    phone.userApproves((w1.result as { proposalId: string }).proposalId);
    const before = (runtime.dispatch({ id: "r2", name: "getStepContext", args: {} }).result as { currentStepIndex: number }).currentStepIndex;
    expect(before).toBe(2);
    const w2 = runtime.dispatch({ id: "r3", name: "proposeStepAdvance", args: { stepIndex: 0 } });
    phone.userApproves((w2.result as { proposalId: string }).proposalId);
    const after = (runtime.dispatch({ id: "r4", name: "getStepContext", args: {} }).result as { currentStepIndex: number }).currentStepIndex;
    expect(after).toBe(0);
    expect(phone.sessionSnapshot().stepHistory.length).toBe(2);
  });
});

describe("runtime: duplicates and cancellations never double-propose", () => {
  it("a replayed call id is status duplicate with dupOf, one proposal on the phone", () => {
    const { runtime, phone } = harness();
    const first = runtime.dispatch({ id: "c1", name: "proposeSaveNote", args: { text: "garlic", scope: "cook" } });
    expect(first.status).toBe("ok");
    const second = runtime.dispatch({ id: "c1", name: "proposeSaveNote", args: { text: "garlic", scope: "cook" } });
    expect(second.status).toBe("duplicate");
    expect(second.dupOf).toBe((first.result as { proposalId: string }).proposalId);
    expect(phone.pendingProposalIds()).toHaveLength(1);
  });

  it("same payload under a fresh call id dedupes too", () => {
    const { runtime, phone } = harness();
    runtime.dispatch({ id: "c1", name: "proposeSaveNote", args: { text: "garlic", scope: "cook" } });
    const second = runtime.dispatch({ id: "c2", name: "proposeSaveNote", args: { scope: "cook", text: "garlic" } });
    expect(second.status).toBe("duplicate"); // key order differs, payload hash does not
    expect(phone.pendingProposalIds()).toHaveLength(1);
  });

  it("a cancelled call leaves no proposal that a later duplicate could hit", () => {
    const { runtime } = harness();
    const cancelled = runtime.dispatch(
      { id: "c1", name: "proposeSaveNote", args: { text: "ghost", scope: "cook" } },
      { aborted: () => true }
    );
    expect(cancelled.status).toBe("cancelled");
    const retry = runtime.dispatch({ id: "c2", name: "proposeSaveNote", args: { text: "ghost", scope: "cook" } });
    expect(retry.status).toBe("ok"); // nothing was filed, so the retry is real
  });
});

describe("runtime: camera and safety surfaces", () => {
  it("camera looks are hard-capped at 3 seconds and carry no verdict", () => {
    const { runtime } = harness();
    const r = runtime.dispatch({ id: "c1", name: "requestCameraLook", args: { maxClipSeconds: 30 } });
    expect(r.status).toBe("ok");
    const result = r.result as { look: { clipSeconds: number }; safetyVerdict: unknown };
    expect(result.look.clipSeconds).toBeLessThanOrEqual(3);
    expect(result.safetyVerdict).toBeNull();
  });

  it("doneness questions dispatch to a sourced check", () => {
    const { runtime } = harness();
    const r = runtime.dispatch({ id: "c1", name: "checkFoodSafety", args: { product: "chicken breast" } });
    expect(r.status).toBe("ok");
    const result = r.result as { answer: { kind: string; check?: { temperatureC: number; source: string } } };
    expect(result.answer.kind).toBe("sourced-check");
    expect(result.answer.check!.temperatureC).toBe(74);
    expect(result.answer.check!.source).toMatch(/USDA FSIS/);
  });

  it("camera mode is irrelevant to the no-verdict rule (continuous too)", () => {
    const clock = new ManualClock(Date.UTC(2026, 0, 1, 18, 0, 0));
    const phone = new FakePhone({
      clock,
      pantry: PANTRY.map((l) => ({ ...l })),
      session: { state: "cooking", currentStepIndex: 0, cameraMode: "continuous" }
    });
    const runtime: LeChefRuntime = createLeChefRuntime({
      clock,
      phone,
      catalog: () => [RECIPE],
      camera: {
        mode: "continuous",
        capture() {
          return { observed: ["pot boiling"], cannotAssess: ["internal temperature"], framesSent: 4, clipSeconds: 3 };
        }
      }
    });
    const r = runtime.dispatch({ id: "c1", name: "requestCameraLook", args: {} });
    const result = r.result as { safetyVerdict: unknown };
    expect(result.safetyVerdict).toBeNull();
  });
});

describe("runtime: user initiation is derived from device events only (SPEC 4)", () => {
  it("an honest device-event citation makes a timer user-initiated (device-auto)", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a two minute timer" });
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, deviceEventId: cmd.id } });
    expect(r.status).toBe("ok");
    const result = r.result as { userInitiated?: boolean; requiredApproval?: string; state: string };
    expect(result.userInitiated).toBe(true);
    expect(result.requiredApproval).toBe("device-auto");
    expect(result.state).toBe("executed"); // the phone's timer rule ran it
    expect(phone.activeTimers()).toHaveLength(1);
  });

  it("a bare userInitiated flag in tool arguments is never trusted", () => {
    const { runtime, phone } = harness();
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, userInitiated: true } });
    expect(r.status).toBe("ok");
    const result = r.result as { userInitiated?: boolean; state: string };
    expect(result.userInitiated).toBe(false); // no device event was cited — the flag is not evidence
    expect(result.state).toBe("proposed"); // explicit: waits for a scripted user action
    expect(phone.activeTimers()).toHaveLength(0); // nothing executed
    expect(phone.receipts()).toHaveLength(0);
  });

  it("an unknown device event id is not user initiation", () => {
    const { runtime, phone } = harness();
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, deviceEventId: "cmd-9999" } });
    const result = r.result as { userInitiated?: boolean; state: string };
    expect(result.userInitiated).toBe(false);
    expect(result.state).toBe("proposed");
    expect(phone.activeTimers()).toHaveLength(0);
  });

  it("a device event recorded before the current revision is stale and is not user initiation", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    // The world moves: one executed proposal bumps the snapshot revision.
    const adv = runtime.dispatch({ id: "c0", name: "proposeStepAdvance", args: { stepIndex: 1 } });
    phone.userApproves((adv.result as { proposalId: string }).proposalId);
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, deviceEventId: cmd.id } });
    const result = r.result as { userInitiated?: boolean; state: string };
    expect(result.userInitiated).toBe(false); // the citation is stale
    expect(result.state).toBe("proposed");
    expect(phone.activeTimers()).toHaveLength(0);
  });

  it("a device event for another tool is mismatched and is not user initiation", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeMealLog", source: "voice", detail: "log this meal" });
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, deviceEventId: cmd.id } });
    const result = r.result as { userInitiated?: boolean; state: string };
    expect(result.userInitiated).toBe(false);
    expect(result.state).toBe("proposed");
    expect(phone.activeTimers()).toHaveLength(0);
  });

  it("a meal log with a genuine log-the-meal command is recorded as initiated yet stays explicit", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeMealLog", source: "voice", detail: "log this meal" });
    const r = runtime.dispatch({
      id: "c1",
      name: "proposeMealLog",
      args: { recipeId: "eggs-on-toast", revision: 1, servings: 2, sourcedFrom: "voice", deviceEventId: cmd.id }
    });
    const result = r.result as { userInitiated?: boolean; requiredApproval?: string; state: string };
    expect(result.userInitiated).toBe(true); // recorded fact: the user said it
    expect(result.requiredApproval).toBe("explicit"); // SPEC 4: a voice transcript never authorizes a meal log
    expect(result.state).toBe("proposed");
    expect(phone.mealLogRecords()).toHaveLength(0);
  });

  it("one device command initiates one action end-to-end — a spent citation is explicit", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "voice" });
    const first = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, deviceEventId: cmd.id } });
    expect((first.result as { state: string }).state).toBe("executed");
    const second = runtime.dispatch({ id: "c2", name: "proposeTimerStart", args: { label: "more", minutes: 5, deviceEventId: cmd.id } });
    const result = second.result as { userInitiated?: boolean; state: string };
    expect(result.userInitiated).toBe(false); // the event is consumed — gone from the snapshot
    expect(result.state).toBe("proposed");
    expect(phone.activeTimers()).toHaveLength(1);
  });

  it("an explicit userInitiated:false does not veto a valid device-event citation", () => {
    const { runtime, phone } = harness();
    const cmd = phone.recordUserCommand({ command: "proposeTimerStart", source: "touch" });
    const r = runtime.dispatch({ id: "c1", name: "proposeTimerStart", args: { label: "eggs", minutes: 2, userInitiated: false, deviceEventId: cmd.id } });
    const result = r.result as { userInitiated?: boolean; requiredApproval?: string };
    expect(result.userInitiated).toBe(true); // the citation decides, not the flag
    expect(result.requiredApproval).toBe("device-auto");
  });
});
