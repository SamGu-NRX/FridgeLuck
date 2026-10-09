import type { ToolCallTrace, ConfidenceAssessResponse } from "../types/contracts.js";

// Trace-log redaction.
//
// Traces used to embed the RAW tool args (`args: Record<string, unknown>`).
// For most tools those args are small and safe, but the registry receives
// model-controlled payloads and client-influenced fields: a mutation call
// carries item arrays, and a future tool could carry photo/base64 fields.
// Logging them verbatim would put provider- and user-derived payloads into
// container logs (the same class of leak the HTTP log discipline in
// src/http/logger.ts prevents).
//
// Redaction policy: a strict ALLOWLIST of scalar fields worth tracing, plus
// structural placeholders for anything else. Denylist alone would be whack-
// a-mole; allowlist plus deny is conservative by construction.

/** Fields that may be logged as-is when they are safe scalars (capped). */
const TRACE_ARG_ALLOWLIST = new Set([
  "question",
  "userQuestion",
  "operation",
  "thresholdDays",
  "restockBelowGrams",
  "itemCount"
]);

/** Never logged, even if they appear as scalars. */
const TRACE_ARG_DENY_PATTERN =
  /key|token|secret|password|auth|photo|image|frame|inline|data|base64/i;

const TRACE_ARG_STRING_MAX_CHARS = 300;

export function redactArgs(
  args?: Record<string, unknown>
): Record<string, unknown> | undefined {
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    return undefined;
  }

  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (TRACE_ARG_DENY_PATTERN.test(key)) {
      continue;
    }
    if (!TRACE_ARG_ALLOWLIST.has(key)) {
      continue;
    }
    if (typeof value === "number" || typeof value === "boolean") {
      out[key] = value;
      continue;
    }
    if (typeof value === "string") {
      out[key] =
        value.length <= TRACE_ARG_STRING_MAX_CHARS
          ? value
          : `${value.slice(0, TRACE_ARG_STRING_MAX_CHARS)}…`;
      continue;
    }
    // Non-scalar value under an allowlisted key: structure only.
    out[key] = "[omitted]";
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

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
  const redacted = redactArgs(args);

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
        ...(redacted !== undefined ? { args: redacted } : {}),
        ...extra
      };
    }
  };
}
