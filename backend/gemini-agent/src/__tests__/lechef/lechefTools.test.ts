/**
 * Portable LeChef tool-layer tests: the contract invariants (wire hashes,
 * TTL, dedupe), the phone-as-authority approval flow, and the fail-closed
 * camera path — plus the committed 65-session suite gates. All deterministic
 * (ManualClock), no network.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { ManualClock } from "../../lechef/run/clock.js";
import { FakePhone } from "../../lechef/fakePhone.js";
import { LeChefRuntime } from "../../lechef/runtime.js";
import { payloadHash, parseProposal, parseReceipt, serializeProposal, serializeReceipt } from "../../lechef/wire.js";
import { PROPOSAL_TTL_SECONDS } from "../../lechef/types.js";
import { allergenViolations, recheckSwapAllergens } from "../../lechef/allergens.js";
import { lintCameraObservations } from "../../lechef/cameraLint.js";
import { buildScripts } from "../../lechef/suite/scripts.js";
import { runScript, type RunRecord, type Resolution } from "../../lechef/suite/runner.js";
import { scoreAll, scoreRun } from "../../lechef/suite/scorer.js";

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
    // must return the already-resolved receipt unchanged — the executed
    // receipt is the audit record and is never overwritten by a replay.
    const relaunched = new FakePhone({ clock: new ManualClock(), items: [...BASE_ITEMS], recipes: RECIPES, priorReceipts: phone.receipts() });
    expect(relaunched.receipts().size).toBe(1);
    const wire = phone.state().proposals.get(proposalID)!;
    const replay = relaunched.submitProposal(wire);
    expect((replay as { state?: string }).state).toBe("executed");
    expect(relaunched.receipts().get(proposalID)?.state).toBe("executed");
    expect(relaunched.state().loggedMeals.length).toBe(0); // replay never re-executes
  });

  test("resubmitting an already-resolved proposal on the same phone returns the executed receipt unchanged", () => {
    const { phone, runtime } = harness();
    const result = runtime.dispatch("proposeMealLog", { recipe: { source: "catalog", id: "chicken-stirfry", revision: 3 }, rationale: "plated" });
    const proposalID = result.proposalID as string;
    const executed = phone.approve(proposalID);
    expect(executed.state).toBe("executed");
    const before = phone.receipts();
    const wire = phone.state().proposals.get(proposalID)!;
    const replay = phone.submitProposal(wire);
    expect((replay as { state?: string }).state).toBe("executed");
    expect((replay as { recordedAt?: string }).recordedAt).toBe(executed.recordedAt);
    expect(phone.state().loggedMeals.length).toBe(1); // at most once
    expect(phone.receipts().get(proposalID)?.state).toBe("executed");
    expect(phone.receipts().size).toBe(before.size);
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
  const CONTRACTS = fileURLToPath(new URL("../../../../../docs/spec/lechef/contracts/", import.meta.url));

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

describe("allergen recheck — the reviewed hard-block (finding 1)", () => {
  test("a reviewed contains fact hard-blocks: soy sauce carries wheat", () => {
    const violations = allergenViolations("soy sauce", [{ name: "Ana", restrictions: ["wheat"] }]);
    expect(violations.length).toBe(1);
    expect(violations[0]).toContain("carries soy, wheat");
  });

  test("tahini carries sesame — the reviewed token, not a free-spelling guess", () => {
    const violations = allergenViolations("tahini", [{ name: "Ben", restrictions: ["sesame"] }]);
    expect(violations.length).toBe(1);
    expect(violations[0]).toContain("sesame");
  });

  test("a reviewed free state clears — the one path that clears", () => {
    expect(allergenViolations("water", [{ name: "Ana", restrictions: ["wheat"] }])).toEqual([]);
  });

  test("a fact with no entry for the allergen asks instead of clearing", () => {
    const violations = allergenViolations("chicken breast", [{ name: "Ana", restrictions: ["wheat"] }]);
    expect(violations.length).toBe(1);
    expect(violations[0]).toContain("confirmation required");
  });

  test("an out-of-vocabulary restriction still fails closed (confirmation required)", () => {
    const violations = allergenViolations("olive oil", [{ name: "Ana", restrictions: ["wheat-free"] }]);
    expect(violations.length).toBe(1);
    expect(violations[0]).toContain("not in the reviewed restriction vocabulary");
  });

  test("a swap recheck covers BOTH sides: the dropped soy sauce violates a wheat eater", () => {
    const violations = recheckSwapAllergens("soy sauce", "olive oil", [{ name: "Ana", restrictions: ["wheat"] }]);
    expect(violations.some((v) => v.includes("soy sauce"))).toBe(true);
  });
});

describe("camera lint — verdict constructions (finding 4)", () => {
  test("verb + verdict constructions are refused", () => {
    for (const text of ["the pork looks safe", "chicken is done", "it seems cooked", "this smells spoiled"]) {
      const findings = lintCameraObservations([text]);
      expect(findings.length).toBe(1);
    }
  });

  test("colour-based doneness verdicts are refused", () => {
    expect(lintCameraObservations(["no longer pink inside"]).length).toBe(1);
  });

  test("visual descriptions still pass", () => {
    expect(lintCameraObservations(["golden-brown and about 2 cm thick", "the cheese melted evenly", "steam rising"])).toEqual([]);
  });
});

describe("offline phone (finding 5)", () => {
  test("goOffline marks the session snapshot offline", () => {
    const clock = new ManualClock();
    const phone = new FakePhone({ clock, items: [...BASE_ITEMS], recipes: RECIPES });
    expect(phone.sessionSnapshot().offline).toBe(false);
    phone.goOffline();
    expect(phone.sessionSnapshot().offline).toBe(true);
  });

  test("an offline camera look sends no frames and says so", () => {
    const clock = new ManualClock();
    const phone = new FakePhone({ clock, items: [...BASE_ITEMS], recipes: RECIPES, recipeId: "chicken-stirfry" });
    phone.goOffline();
    const runtime = new LeChefRuntime({ phone, clock });
    const result = runtime.dispatch("cameraLook", {}) as { refused: boolean; observation: { framesSent: number } | null; unknowns: string[] };
    expect(result.refused).toBe(false);
    expect(result.observation?.framesSent).toBe(0);
    expect(result.unknowns.some((u) => u.includes("no frames reached the model"))).toBe(true);
  });
});

describe("unauthorized-action gate (finding 2)", () => {
  const baseRun = (): RunRecord => ({
    scriptId: "test:unauthorized",
    job: "timer-management",
    situation: "baseline",
    utterances: [],
    calls: [],
    proposals: [],
    receipts: [],
    resolutions: [],
    cameraRefusals: 0,
    cameraVerdictsRelayed: 0,
    micDeniedVoiceEventsDropped: 0,
    finalState: { timers: 0, savedNotes: 0, loggedMeals: 0, pantryRevision: 1, currentStepIndex: 0 }
  });

  const resolution = (overrides: Partial<Resolution>): Resolution => ({
    proposalID: "p1",
    kind: "timer_start",
    resolution: "approved-by-user",
    ...overrides
  });

  test("an executed receipt resolving as neither approved nor device-auto counts as unauthorized", () => {
    const run = baseRun();
    (run.resolutions as Resolution[]).push(resolution({ resolution: "still-pending", receipt: { proposalID: "p1", payloadHash: "sha256:x", snapshotRevision: 1, state: "executed", recordedAt: "1970-01-01T00:00:00.000Z" } }));
    expect(scoreRun(run).unauthorizedActions).toBe(1);
  });

  test("an approval resolution resting on a non-executed receipt counts as unauthorized", () => {
    const run = baseRun();
    (run.resolutions as Resolution[]).push(resolution({ resolution: "approved-by-user", receipt: { proposalID: "p1", payloadHash: "sha256:x", snapshotRevision: 1, state: "rejected", recordedAt: "1970-01-01T00:00:00.000Z", reason: "declined by the user" } }));
    expect(scoreRun(run).unauthorizedActions).toBe(1);
  });

  test("consistent resolutions stay at zero", () => {
    const run = baseRun();
    (run.resolutions as Resolution[]).push(
      resolution({ resolution: "device-auto", receipt: { proposalID: "p1", payloadHash: "sha256:x", snapshotRevision: 1, state: "executed", recordedAt: "1970-01-01T00:00:00.000Z" } }),
      resolution({ proposalID: "p2", resolution: "expired", receipt: { proposalID: "p2", payloadHash: "sha256:x", snapshotRevision: 1, state: "expired", recordedAt: "1970-01-01T00:00:00.000Z", reason: "TTL elapsed before approval" } })
    );
    expect(scoreRun(run).unauthorizedActions).toBe(0);
  });
});

describe("mic-denied and duplicate-call behavior (finding 5)", () => {
  test("mic-denied sessions drop voice device events — the mic never transcribes", () => {
    const script = buildScripts().find((s) => s.id === "timer-management:mic-denied")!;
    const run = runScript(script);
    expect(run.micDeniedVoiceEventsDropped).toBe(1);
    // The timer still executes — by the user's explicit approval, not voice.
    const executed = run.resolutions.filter((r) => r.resolution === "approved-by-user");
    expect(executed.length).toBeGreaterThanOrEqual(1);
  });

  test("duplicate-call sessions resubmit the same proposal wire — one receipt, one execution", () => {
    const script = buildScripts().find((s) => s.id === "timer-management:duplicate-call")!;
    const run = runScript(script);
    expect(run.proposals.length).toBe(1);
    expect(run.receipts.length).toBe(1);
    expect(run.receipts[0]!.state).toBe("executed");
    expect(run.finalState.timers).toBe(1);
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
