import type { ToolCallTrace, ConfidenceAssessResponse } from "../types/contracts.js";

export function formatTrace(trace: ToolCallTrace): string {
  return JSON.stringify({
    severity: trace.success ? "INFO" : "ERROR",
    message: `tool_call: ${trace.toolName}`,
    ...trace
  });
}

export function traceToolCall(trace: ToolCallTrace): void {
  console.log(formatTrace(trace));
}

export function traceConfidenceDecision(
  assessment: ConfidenceAssessResponse,
  context: string,
  sessionId?: string
): void {
  console.log(
    JSON.stringify({
      severity: "INFO",
      message: "confidence_decision",
      context,
      sessionId,
      mode: assessment.mode,
      overallScore: assessment.overallScore,
      deterministicReady: assessment.deterministicReady,
      reasons: assessment.reasons,
      timestamp: new Date().toISOString()
    })
  );
}

export function startTrace(
  toolName: string,
  sessionId?: string,
  args?: Record<string, unknown>
): {
  traceId: string;
  build: (success: boolean, extra?: Partial<ToolCallTrace>) => ToolCallTrace;
} {
  const traceId = globalThis.crypto.randomUUID();
  const startMs = Date.now();

  return {
    traceId,
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
