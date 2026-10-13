// Allowlisted HTTP request logging.
//
// The ONLY fields ever written are the request id, the route pattern, the
// response status, and (for non-2xx) the stable error code — plus the log
// envelope (severity, message). Errors, causes, provider messages, headers,
// and request bodies are never serialized here, so nothing sensitive can leak
// through this path. See src/__tests__/httpLogs.test.ts, which asserts the
// allowlist and sentinel absence end to end.

export interface HttpRequestLogEntry {
  requestId: string;
  route: string;
  status: number;
  errorCode?: string;
}

export function logHttpRequest(entry: HttpRequestLogEntry): void {
  const line: Record<string, unknown> = {
    severity: entry.status < 500 ? "INFO" : "ERROR",
    message: "http_request",
    requestId: entry.requestId,
    route: entry.route,
    status: entry.status
  };

  if (entry.errorCode !== undefined) {
    line.errorCode = entry.errorCode;
  }

  console.log(JSON.stringify(line));
}
