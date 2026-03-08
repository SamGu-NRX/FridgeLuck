import type { ToolCallTrace } from "../types/contracts.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";

/**
 * Format a ToolCallTrace into a structured JSON string suitable for Cloud Logging.
 * Exported separately so unit tests can assert on the output without triggering console.log.
 */
export function formatTrace(trace: ToolCallTrace): string {
  return JSON.stringify({
    severity: trace.success ? "INFO" : "ERROR",
    message: `tool_call: ${trace.toolName}`,
    ...trace
  });
}

/**
 * Emit a structured tool-call trace to stdout (Cloud Run → Cloud Logging).
 */
export function traceToolCall(trace: ToolCallTrace): void {
  console.log(formatTrace(trace));
}

/**
 * Emit a structured confidence-decision trace to stdout.
 */
export function traceConfidenceDecision(
  assessment: ConfidenceAssessResponse,
  context: string,
  sessionId?: string
): void {
  const entry = {
    severity: "INFO",
    message: "confidence_decision",
    context,
    sessionId,
    mode: assessment.mode,
    overallScore: assessment.overallScore,
    deterministicReady: assessment.deterministicReady,
    reasons: assessment.reasons,
    timestamp: new Date().toISOString()
  };
  console.log(JSON.stringify(entry));
}

/**
 * Create a trace-building helper. Uses globalThis.crypto.randomUUID() (Node 18+ / Bun).
 * Callers fill in success and optional fields via build() before emitting.
 */
export function startTrace(
  toolName: string,
  sessionId?: string,
  args?: Record<string, unknown>
): {
  traceId: string;
  startMs: number;
  build: (success: boolean, extra?: Partial<ToolCallTrace>) => ToolCallTrace;
} {
  const traceId = globalThis.crypto.randomUUID();
  const startMs = Date.now();

  return {
    traceId,
    startMs,
    build(success, extra = {}) {
      return {
        traceId,
        toolName,
        sessionId,
        durationMs: Date.now() - startMs,
        success,
        timestamp: new Date().toISOString(),
        args,
        ...extra
      };
    }
  };
}
