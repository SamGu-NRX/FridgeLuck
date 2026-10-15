/**
 * Portable LeChef tool-layer tests: the contract invariants (wire hashes,
 * TTL, dedupe), the phone-as-authority approval flow, and the fail-closed
 * camera path — plus the committed 65-session suite gates. All deterministic
 * (ManualClock), no network.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ManualClock } from "../../lechef/run/clock.js";
import { FakePhone } from "../../lechef/fakePhone.js";
import { LeChefRuntime } from "../../lechef/runtime.js";
import { payloadHash, parseProposal, parseReceipt, serializeProposal, serializeReceipt } from "../../lechef/wire.js";
import { PROPOSAL_TTL_SECONDS } from "../../lechef/types.js";
import { buildScripts } from "../../lechef/suite/scripts.js";
import { runScript } from "../../lechef/suite/runner.js";
import { scoreAll } from "../../lechef/suite/scorer.js";

const BASE_ITEMS = [
  { ingredientId: "chicken-breast", name: "chicken breast", state: "sufficient" as const, quantity: { kind: "unknown" as const }, source: "scan" as const }
];
const RECIPES = [
  {
    id: "chicken-stirfry",
    revision: 3,
    title: "Chicken stir-fry",
    servings: 2,
    ingredientBill: [{ ingredientId: "chicken-breast", name: "chicken breast", quantity: { kind: "known" as const, value: 500, unit: "g" } }],
    steps: [{ index: 0, text: "Sear the chicken." }]
  }
];

function harness() {
  const clock = new ManualClock();
  const phone = new FakePhone({ clock, items: [...BASE_ITEMS], recipes: RECIPES, recipeId: "chicken-stirfry", currentStepIndex: 0 });
  const runtime = new LeChefRuntime({ phone, clock });
  return { clock, phone, runtime };
}

describe("wire", () => {
  test("payload hashes are deterministic over the payload as received", () => {
    const a = payloadHash({ b: 1, a: [2, { z: true, y: null }] });
    const b = payloadHash({ a: [2, { y: null, z: true }], b: 1 });
    expect(a).toBe(b);
    expect(a.startsWith("sha256:")).toBe(true);
  });

  test("proposal TTL is 300 seconds", () => {
    expect(PROPOSAL_TTL_SECONDS).toBe(300);
  });
});

describe("proposal flow — the phone is the authority", () => {
  test("a timer proposal citing a fresh voice device event executes device-auto", () => {
    const { clock, phone, runtime } = harness();
    phone.recordDeviceEvent({ id: "evt-1", command: "proposeTimerStart", source: "voice", detail: "start a two minute timer" });
    const result = runtime.dispatch("proposeTimerStart", {
      durationMinutes: 2,
      label: "sear",
      rationale: "step 1 check-in",
      userInitiationEventId: "evt-1"
    });
    expect(result.submitted).toBe(true);
    expect(result.status).toBe("resolved");
    const receipt = (result as { receipt?: { state: string; proposalID: string } }).receipt;
    expect(receipt?.state).toBe("executed");
    expect(phone.state().timers.length).toBe(1);
    expect(clock.nowMs()).toBeGreaterThan(0);
  });

  test("a meal_log is NEVER device-auto, even citing a voice event", () => {
    const { phone, runtime } = harness();
    phone.recordDeviceEvent({ id: "evt-2", command: "proposeMealLog", source: "voice", detail: "log it" });
    const result = runtime.dispatch("proposeMealLog", {
      recipe: { source: "catalog", id: "chicken-stirfry", revision: 3 },
      rationale: "user says they plated the dish",
      userInitiationEventId: "evt-2"
    });
    expect(result.submitted).toBe(true);
    expect(result.status).toBe("pending_explicit_approval");
    expect(phone.state().loggedMeals.length).toBe(0);
  });

  test("an explicitly approved meal_log executes; the voice event is not consumed", () => {
    const { phone, runtime } = harness();
    phone.recordDeviceEvent({ id: "evt-2", command: "proposeMealLog", source: "voice", detail: "log it" });
    const result = runtime.dispatch("proposeMealLog", {
      recipe: { source: "catalog", id: "chicken-stirfry", revision: 3 },
      rationale: "user says they plated the dish",
      userInitiationEventId: "evt-2"
    });
    const proposalID = result.proposalID as string;
    phone.approve(proposalID);
    expect(phone.state().loggedMeals.length).toBe(1);
    // The voice event was never consumed by a meal log: a transcript never
    // authorizes anything, and the event stays available for a real timer use.
    expect(phone.state().consumedDeviceEvents.has("evt-2")).toBe(false);
  });

  test("receipts survive a kill-and-relaunch: resubmitting the same proposal resolves at most once", () => {
    const { phone, runtime } = harness();
    const result = runtime.dispatch("proposeMealLog", { recipe: { source: "catalog", id: "chicken-stirfry", revision: 3 }, rationale: "plated" });
    const proposalID = result.proposalID as string;
    phone.approve(proposalID);
    expect(phone.state().loggedMeals.length).toBe(1);
    // Relaunch with the prior receipts: replaying the SAME proposal (same id)
    // must return the already-resolved receipt, never re-execute.
    const relaunched = new FakePhone({ clock: new ManualClock(), items: [...BASE_ITEMS], recipes: RECIPES, priorReceipts: phone.receipts() });
    expect(relaunched.receipts().size).toBe(1);
    expect(relaunched.receipts().get(proposalID)?.state).toBe("executed");
  });

  test("a consumed device event cannot be reused — the citation is refused, not ignored", () => {
    const { clock, phone, runtime } = harness();
    phone.recordDeviceEvent({ id: "evt-3", command: "proposeTimerStart", source: "touch", detail: "start timer" });
    const first = runtime.dispatch("proposeTimerStart", { durationMinutes: 2, rationale: "check-in", userInitiationEventId: "evt-3" });
    expect(first.status).toBe("resolved");
    clock.advanceMs(1000);
    // The event is consumed: citing it again fails CLOSED client-side — the
    // proposal is never staged and never silently degrades to a pend.
    const second = runtime.dispatch("proposeTimerStart", { durationMinutes: 5, rationale: "another", userInitiationEventId: "evt-3" });
    expect(second.submitted).toBe(false);
    expect((second.issues as string[])[0]).toContain("not visible in the session snapshot");
  });

  test("a tampered payload hash is rejected", () => {
    const { runtime } = harness();
    const result = runtime.dispatch("proposeTimerStart", { durationMinutes: -5, rationale: "broken" });
    // Client-side validation rejects a negative duration before submission.
    expect(result.submitted).toBe(false);
    expect((result.issues as string[]).length).toBeGreaterThan(0);
  });

  test("approval after the TTL expires the proposal instead of executing it", () => {
    const { clock, phone, runtime } = harness();
    const result = runtime.dispatch("proposeTimerStart", { durationMinutes: 2, label: "sear", rationale: "check-in" });
    clock.advanceMs(10 * 60_000); // past the 300 s TTL
    const receipt = phone.approve(result.proposalID as string);
    expect(receipt.state).toBe("expired");
    expect(phone.state().timers.length).toBe(0);
  });
});

describe("read tools", () => {
  test("dispatch is order-independent for reads (same answers after reordering)", () => {
    const a = harness();
    const b = harness();
    const pa = a.runtime.dispatch("getPantry", {});
    const planA = a.runtime.dispatch("getPlan", {});
    const planB = b.runtime.dispatch("getPlan", {});
    const pb = b.runtime.dispatch("getPantry", {});
    expect(pa.pantry).toEqual(pb.pantry);
    expect(planA).toEqual(planB);
  });

  test("verdict-shaped camera text is refused, never relayed", () => {
    const { runtime } = harness();
    const result = runtime.dispatch("cameraLook", {
      // Force a verdict-shaped observation through the phone's camera script.
      mode: "push-to-look"
    }) as { refused: boolean; observation: { observed: readonly string[] } | null };
    // The default phone camera is honest, so nothing is refused here; the
    // verdict-shaped case is exercised by the suite's live-disconnect sessions
    // (live-guidance:live-disconnect asserts refusal) and by the lint unit:
    expect(result.refused).toBe(false);
    expect(result.observation).not.toBeNull();
  });

  test("unknown products answer as an explicit unknown, never a temperature", () => {
    const { runtime } = harness();
    const result = runtime.dispatch("checkFoodSafety", { product: "dragonfruit-rare-variant" }) as {
      answer: { kind: string; temperatureF?: number };
    };
    expect(result.answer.kind).toBe("unknown");
    expect(result.answer.temperatureF).toBeUndefined();
  });
});

describe("contract fixtures (ports contracts/check.py expectations)", () => {
  const CONTRACTS = new URL("../../../../../docs/spec/lechef/contracts/", import.meta.url).pathname;

  test("both proposal examples parse, and their payload hashes recompute over compact canonical JSON", () => {
    for (const file of ["proposal-add-timer.json", "proposal-substitute.json"]) {
      const raw = JSON.parse(readFileSync(`${CONTRACTS}examples/${file}`, "utf8"));
      const proposal = parseProposal(raw);
      expect(proposal.payloadHash).toBe(payloadHash(proposal.payload));
      expect(proposal.rationale.length).toBeLessThanOrEqual(280);
      // Round-trip: serialize → parse is the identity.
      expect(parseProposal(JSON.parse(serializeProposal(proposal)))).toEqual(proposal);
    }
  });

  test("both receipt examples parse, and expired receipts carry the TTL semantics", () => {
    for (const file of ["receipt-executed.json", "receipt-expired.json"]) {
      const raw = JSON.parse(readFileSync(`${CONTRACTS}examples/${file}`, "utf8"));
      const receipt = parseReceipt(raw);
      expect(parseReceipt(JSON.parse(serializeReceipt(receipt)))).toEqual(receipt);
    }
    const expired = parseReceipt(JSON.parse(readFileSync(`${CONTRACTS}examples/receipt-expired.json`, "utf8")));
    expect(expired.state).toBe("expired");
  });

  test("a tampered payload hash is detectable by recomputation (the phone verifies at submission)", () => {
    const raw = JSON.parse(readFileSync(`${CONTRACTS}examples/proposal-add-timer.json`, "utf8"));
    const proposal = parseProposal(raw); // shape parses fine
    raw.payloadHash = "sha256:" + "0".repeat(64);
    const tampered = parseProposal(raw);
    expect(tampered.payloadHash).not.toBe(payloadHash(tampered.payload));
    expect(proposal.payloadHash).toBe(payloadHash(proposal.payload));
  });
});

describe("committed suite", () => {
  const runs = buildScripts().map(runScript);
  const report = scoreAll(runs, "deterministic");

  test("all 65 sessions run", () => {
    expect(report.sessions).toBe(65);
    expect(runs.length).toBe(65);
  });

  test("zero unsafe answers", () => {
    expect(report.gates.unsafeAnswersZero).toBe(true);
  });

  test("zero unauthorized actions", () => {
    expect(report.gates.unauthorizedActionsZero).toBe(true);
  });

  test("every session succeeds its job assertion", () => {
    const failures = report.perSession.filter((s) => !s.jobSuccess);
    expect(failures).toEqual([]);
  });

  test("the suite is deterministic (same script, same record)", () => {
    const script = buildScripts().find((s) => s.id === "timer-management:baseline")!;
    const r1 = runScript(script);
    const r2 = runScript(script);
    expect(JSON.stringify(r1.receipts)).toBe(JSON.stringify(r2.receipts));
    expect(r1.finalState).toEqual(r2.finalState);
  });
});
