/**
 * Coach design policy tests — what the toolPolicy denies proactively, what
 * it lets through, and the approval classes prompted proposals get. All
 * assertions run the design's own fixture scripts through the pinned
 * gate-and-replay pipeline.
 */

import { describe, it, expect } from "bun:test";
import { runDesignSession } from "../../../../lechef/run/designRunner.js";
import { parseSessionScript } from "../../../../lechef/fakeModel.js";
import type { SessionScript } from "../../../../lechef/fakeModel.js";
import { coachDesign, COACH_DENY_REASONS } from "../../../../lechef/designs/coach/design.js";
import { COACH_SCRIPTS } from "../../../../lechef/designs/coach/scripts/index.js";
import type { CoachCase } from "../../../../lechef/designs/coach/scripts/types.js";

function findCase(name: string): CoachCase {
  const found = COACH_SCRIPTS.find((c) => c.name === name);
  if (!found) throw new Error(`coach script fixture not found: ${name}`);
  return found;
}

function replay(c: CoachCase): ReturnType<typeof runDesignSession> {
  return runDesignSession(parseSessionScript(c.script) as SessionScript, coachDesign);
}

describe("coach design policy gating", () => {
  it("denies every proactive proposal with the design's typed reason while the pantry read passes", () => {
    const record = replay(findCase("coach-003-proactive-proposals-denied"));
    const byId = new Map(record.toolCalls.map((c) => [c.id, c]));

    expect(byId.get("c-adv")?.result).toEqual({
      error: "policy-denied",
      deniedBy: "coach",
      reason: COACH_DENY_REASONS.proactiveProposal
    });
    expect(byId.get("c-tmr")?.result).toEqual({
      error: "policy-denied",
      deniedBy: "coach",
      reason: COACH_DENY_REASONS.proactiveProposal
    });
    expect(byId.get("c-ml")?.result).toEqual({
      error: "policy-denied",
      deniedBy: "coach",
      reason: COACH_DENY_REASONS.mealLog
    });
    expect(byId.get("c-pantry")?.status).toBe("ok");
    // Nothing reached the phone: denials are not proposals.
    expect(record.proposals).toEqual([]);
  });

  it("lets proactive food-safety and pantry reads through, grounded and sourced", () => {
    const safety = replay(findCase("coach-001-proactive-safety-read"));
    expect(safety.toolCalls.filter((c) => c.status === "ok").map((c) => c.name)).toEqual([
      "checkFoodSafety",
      "getStepContext"
    ]);
    const doneness = safety.answers.filter((a) => a.type === "doneness" && a.sourcedCheck !== null);
    expect(doneness.map((a) => a.sourcedCheck?.temperatureC)).toEqual([74]);

    const pantry = replay(findCase("coach-002-proactive-pantry-use-soon"));
    expect(pantry.toolCalls.map((c) => c.name)).toEqual(["getPantrySummary"]);
    expect(pantry.toolCalls.every((c) => c.status === "ok")).toBe(true);
  });

  it("denies proactive camera looks but serves user-requested looks, never as a verdict", () => {
    const record = replay(findCase("coach-005-camera-push-to-look"));
    const byId = new Map(record.toolCalls.map((c) => [c.id, c]));
    expect(byId.get("c-cam0")?.result).toEqual({
      error: "policy-denied",
      deniedBy: "coach",
      reason: COACH_DENY_REASONS.proactiveCamera
    });
    expect(byId.get("c-cam1")?.status).toBe("ok");
    expect(record.camera).toHaveLength(1);
    // Structurally verdict-free: the look records frames and observations, never a safety verdict.
    expect(record.camera[0]).toMatchObject({
      look: true,
      framesSent: 2,
      safetyVerdict: null,
      observed: ["browning on the chicken", "steam rising"],
      cannotAssess: ["internal temperature"]
    });
  });

  it("executes prompted proposals with the layer's approval classes: explicit step advance after approval, device-auto timer", () => {
    const record = replay(findCase("coach-004-prompted-proposals-approved"));
    expect(record.proposals.map((p) => ({ tool: p.tool, requiredApproval: p.requiredApproval, state: p.state }))).toEqual([
      { tool: "proposeStepAdvance", requiredApproval: "explicit", state: "executed" },
      { tool: "proposeTimerStart", requiredApproval: "device-auto", state: "executed" }
    ]);
    expect(record.receipts.map((r) => r.state)).toEqual(["executed", "executed"]);
    expect(record.timers.map((t) => t.label)).toEqual(["spinach wilt"]);
  });
});
