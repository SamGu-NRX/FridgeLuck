import { describe, expect, it } from "bun:test";
import { guardLiveResponse } from "../observability/responseGuard.js";

describe("guardLiveResponse", () => {
  it("rewrites exact nutrition claims when confidence is not deterministic", () => {
    const guarded = guardLiveResponse(
      {
        serverContent: {
          modelTurn: {
            parts: [{ text: "These exact macros are 420 calories and 32 grams of protein." }]
          }
        }
      },
      {
        mode: "estimate_only",
        overallScore: 0.42,
        deterministicReady: false,
        reasons: ["Need review."],
        signals: []
      }
    );

    const text = (guarded.serverContent as any).modelTurn.parts[0].text;
    expect(text).toContain("estimated");
    expect(text).toContain("420 calories");
    expect(text).toContain("Confidence note:");
  });

  it("leaves exact responses alone when confidence is deterministic", () => {
    const original = {
      serverContent: {
        modelTurn: {
          parts: [{ text: "Exact macros are confirmed." }]
        }
      }
    };
    const guarded = guardLiveResponse(original, {
      mode: "exact",
      overallScore: 0.97,
      deterministicReady: true,
      reasons: [],
      signals: []
    });

    expect((guarded.serverContent as any).modelTurn.parts[0].text).toBe(
      "Exact macros are confirmed."
    );
  });
});
