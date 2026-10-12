/**
 * Gemini transport HTTP-path test — LOCALHOST ONLY.
 *
 * The real adapter (SDK client + HTTP + structured-response parsing) is
 * pointed at an in-process Bun server on 127.0.0.1 via the endpoint
 * override — the same rehearsal channel README-live.md documents for
 * operators. No external traffic is possible: the transport cannot reach
 * anywhere except the test's own server.
 */

import { describe, test, expect, afterAll } from "bun:test";
import { GeminiLiveTransport } from "../../lechef/live/geminiTransport.js";

interface SeenRequest {
  path: string;
  body: {
    contents?: Array<{
      role?: string;
      parts?: Array<{ text?: string }>;
    }>;
  };
}

const seen: SeenRequest[] = [];

const server = Bun.serve({
  port: 0,
  fetch: async (req) => {
    const url = new URL(req.url);
    seen.push({ path: url.pathname, body: await req.json() });
    return Response.json({
      candidates: [
        { content: { parts: [{ text: JSON.stringify({ text: "Hello from localhost", toolCalls: [] }) }] } }
      ],
      usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 5 }
    });
  }
});

afterAll(() => server.stop(true));

describe("gemini transport: localhost HTTP path (no external traffic)", () => {
  test("sends the mapped request and parses the structured response over real HTTP", async () => {
    const transport = new GeminiLiveTransport({
      apiKey: "test-only-never-a-real-key",
      model: "gemini-2.0-flash",
      endpoint: `http://127.0.0.1:${server.port}`,
      maxOutputTokens: 512
    });
    const out = await transport.send({
      system: "SYS",
      messages: [{ role: "user", text: "hi" }],
      toolResults: []
    });
    expect(out.text).toBe("Hello from localhost");
    expect(out.toolCalls).toEqual([]);
    expect(out.usage).toEqual({ inputTokens: 12, outputTokens: 5 });

    expect(seen).toHaveLength(1);
    expect(seen[0].path).toContain(":generateContent");
    expect(seen[0].body.contents?.[0]?.role).toBe("user");
    expect(seen[0].body.contents?.[0]?.parts?.[0]?.text).toBe("hi");
  });
});
