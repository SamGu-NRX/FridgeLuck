import { expect, it } from "bun:test";
import { formatTrace } from "../observability/tracing.js";
import type { ToolCallTrace } from "../types/contracts.js";

  it("logs argument keys without argument values", () => {
    const trace: ToolCallTrace = {
      traceId: "private",
      toolName: "ground_food_safety",
      durationMs: 1,
      success: true,
      timestamp: new Date().toISOString(),
      args: { question: "private user question", unrelated: "private value" }
    };
    const formatted = formatTrace(trace);
    expect(formatted).toContain("question");
    expect(formatted).not.toContain("private user question");
    expect(formatted).not.toContain("private value");
  });

