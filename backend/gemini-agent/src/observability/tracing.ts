import type { ToolCallTrace, ConfidenceAssessResponse } from "../types/contracts.js";

export function formatTrace(trace: ToolCallTrace): string {
  return JSON.stringify({
    severity: trace.success ? "INFO" : "ERROR",
    message: `tool_call: ${trace.toolName}`,
    traceId: trace.traceId,
    toolName: trace.toolName,
    sessionId: trace.sessionId,
    durationMs: trace.durationMs,
    success: trace.success,
    errorMessage: trace.errorMessage,
    confidenceMode: trace.confidenceMode,
    confidenceScore: trace.confidenceScore,
    timestamp: trace.timestamp,
    argKeys: trace.args ? Object.keys(trace.args).sort() : []
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
      reasonCount: assessment.reasons.length,
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
