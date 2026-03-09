import { describe, it, expect } from "bun:test";
import { formatTrace, startTrace } from "../observability/tracing.js";
import type { ToolCallTrace } from "../types/contracts.js";

describe("formatTrace", () => {
  it("returns valid JSON string", () => {
    const trace: ToolCallTrace = {
      traceId: "abc-123",
      toolName: "scan_fridge",
      durationMs: 120,
      success: true,
      timestamp: "2026-03-08T06:00:00.000Z"
    };
    const formatted = formatTrace(trace);
    expect(() => JSON.parse(formatted)).not.toThrow();
  });

  it("sets severity to INFO for successful traces", () => {
    const trace: ToolCallTrace = {
      traceId: "t1",
      toolName: "generate_recipe",
      durationMs: 300,
      success: true,
      timestamp: new Date().toISOString()
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.severity).toBe("INFO");
  });

  it("sets severity to ERROR for failed traces", () => {
    const trace: ToolCallTrace = {
      traceId: "t2",
      toolName: "mutate_inventory",
      durationMs: 10,
      success: false,
      errorMessage: "idempotencyKey is required",
      timestamp: new Date().toISOString()
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.severity).toBe("ERROR");
    expect(parsed.errorMessage).toBe("idempotencyKey is required");
  });

  it("includes required fields: traceId, toolName, durationMs, success, timestamp", () => {
    const trace: ToolCallTrace = {
      traceId: "t3",
      toolName: "get_restock_plan",
      durationMs: 5,
      success: true,
      timestamp: "2026-03-08T00:00:00.000Z"
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.traceId).toBe("t3");
    expect(parsed.toolName).toBe("get_restock_plan");
    expect(parsed.durationMs).toBe(5);
    expect(parsed.success).toBe(true);
    expect(parsed.timestamp).toBe("2026-03-08T00:00:00.000Z");
  });

  it("includes optional confidenceMode and confidenceScore when provided", () => {
    const trace: ToolCallTrace = {
      traceId: "t4",
      toolName: "reverse_scan_meal",
      durationMs: 250,
      success: true,
      timestamp: new Date().toISOString(),
      confidenceMode: "review_required",
      confidenceScore: 0.72
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.confidenceMode).toBe("review_required");
    expect(parsed.confidenceScore).toBe(0.72);
  });

  it("includes message field containing the tool name", () => {
    const trace: ToolCallTrace = {
      traceId: "t5",
      toolName: "scan_fridge",
      durationMs: 80,
      success: true,
      timestamp: new Date().toISOString()
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.message).toContain("scan_fridge");
  });

  it("includes sessionId when provided", () => {
    const trace: ToolCallTrace = {
      traceId: "t6",
      toolName: "mutate_inventory",
      sessionId: "session-abc",
      durationMs: 15,
      success: true,
      timestamp: new Date().toISOString()
    };
    const parsed = JSON.parse(formatTrace(trace));
    expect(parsed.sessionId).toBe("session-abc");
  });
});

describe("startTrace", () => {
  it("returns a traceId that is a non-empty string", () => {
    const { traceId } = startTrace("scan_fridge");
    expect(typeof traceId).toBe("string");
    expect(traceId.length).toBeGreaterThan(0);
  });

  it("build() returns a ToolCallTrace with the correct toolName", () => {
    const helper = startTrace("generate_recipe", "sess-01");
    const trace = helper.build(true);
    expect(trace.toolName).toBe("generate_recipe");
    expect(trace.sessionId).toBe("sess-01");
    expect(trace.success).toBe(true);
  });

  it("build() produces a timestamp that is a valid ISO 8601 string", () => {
    const helper = startTrace("get_restock_plan");
    const trace = helper.build(false);
    const date = new Date(trace.timestamp);
    expect(isNaN(date.getTime())).toBe(false);
  });

  it("build() durationMs is >= 0", () => {
    const helper = startTrace("mutate_inventory");
    const trace = helper.build(true);
    expect(trace.durationMs).toBeGreaterThanOrEqual(0);
  });

  it("build() merges extra fields into the trace", () => {
    const helper = startTrace("reverse_scan_meal");
    const trace = helper.build(false, {
      errorMessage: "Gemini timed out",
      confidenceMode: "estimate_only"
    });
    expect(trace.errorMessage).toBe("Gemini timed out");
    expect(trace.confidenceMode).toBe("estimate_only");
  });

  it("two separate startTrace calls produce different traceIds", () => {
    const a = startTrace("scan_fridge");
    const b = startTrace("scan_fridge");
    expect(a.traceId).not.toBe(b.traceId);
  });
});
