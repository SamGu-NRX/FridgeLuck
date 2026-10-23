import { afterEach, describe, expect, it } from "bun:test";
import { startAgentHttp } from "./fixtures/agentHttp.js";

let close: (() => Promise<void>) | undefined;
afterEach(async () => {
  await close?.();
  close = undefined;
});

describe("confidence outcome HTTP validation", () => {
  it("rejects unknown signal keys and invalid scores before recording", async () => {
    const app = await startAgentHttp();
    close = app.close;
    const response = await app.post("/v1/confidence/outcome", {
      assessment: {
        mode: "review_required",
        overallScore: 0.7,
        deterministicReady: false,
        reasons: ["test"],
        signals: [{
          key: "attacker.signal",
          rawScore: 1.4,
          adjustedScore: 0.7,
          trustMean: 0.5,
          trustUncertainty: 0.1,
          weight: 1,
          reason: "test",
        }],
      },
      outcomeReward: 0.5,
    });
    expect(response.status).toBe(400);
    expect(app.confidenceService.calibrationSnapshots()).toEqual([]);
  });
});

// Exercise retained diagnostic history without relying on private service fields.
it("keeps only the most recent 1,000 outcome events", async () => {
  const app = await startAgentHttp();
  close = app.close;
  for (let i = 0; i < 1_001; i++) {
    const assessment = app.confidenceService.assess({ signals: [{ key: "live.camera_frame", rawScore: 0.7 }] });
    app.confidenceService.recordOutcome({ assessment, outcomeReward: 0.5 });
  }
  expect(app.confidenceService.calibrationSnapshots()[0]!.eventCount).toBe(1_000);
});
