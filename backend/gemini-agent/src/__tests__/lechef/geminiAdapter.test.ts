/**
 * Gemini adapter mapper tests — PURE functions only. No network, no key,
 * no SDK client construction: the transport class's send path is exercised
 * exclusively by an operator-authorized live run.
 */

import { describe, test, expect } from "bun:test";
import { stripVersionPath, toGenerateContents, fromGenerateContentJson } from "../../lechef/live/geminiTransport.js";
import type { LiveTransportRequest } from "../../lechef/live/types.js";

describe("gemini adapter: stripVersionPath", () => {
  test("strips the /v1beta version path", () => {
    expect(stripVersionPath("https://generativelanguage.googleapis.com/v1beta")).toBe(
      "https://generativelanguage.googleapis.com"
    );
  });
  test("strips /v1 too", () => {
    expect(stripVersionPath("https://proxy.internal/v1")).toBe("https://proxy.internal");
  });
  test("keeps a base URL without a version path untouched", () => {
    expect(stripVersionPath("https://proxy.internal")).toBe("https://proxy.internal");
  });
});

function request(overrides: Partial<LiveTransportRequest> = {}): LiveTransportRequest {
  return {
    system: "SYS",
    messages: [
      { role: "user", text: "hi" },
      { role: "assistant", text: "hello" }
    ],
    toolResults: [],
    ...overrides
  };
}

describe("gemini adapter: toGenerateContents", () => {
  test("maps user→user and assistant→model, passing the system prompt through", () => {
    const mapped = toGenerateContents(request());
    expect(mapped.system).toBe("SYS");
    expect(mapped.contents).toEqual([
      { role: "user", parts: [{ text: "hi" }] },
      { role: "model", parts: [{ text: "hello" }] }
    ]);
  });
  test("appends tool results as one user message carrying their JSON", () => {
    const mapped = toGenerateContents(
      request({
        toolResults: [{ callId: "c1", name: "toolA", resultJson: '{"ok":true}' }]
      })
    );
    expect(mapped.contents).toHaveLength(3);
    expect(mapped.contents[2].role).toBe("user");
    expect(mapped.contents[2].parts[0].text).toContain('"callId": "c1"');
    expect(mapped.contents[2].parts[0].text).toContain('"name": "toolA"');
    expect(mapped.contents[2].parts[0].text).toContain('{"ok":true}');
  });
  test("adds no message when there are no tool results", () => {
    expect(toGenerateContents(request()).contents).toHaveLength(2);
  });
});

describe("gemini adapter: fromGenerateContentJson", () => {
  test("parses a valid structured response without tool calls", () => {
    const out = fromGenerateContentJson(JSON.stringify({ text: "Hello!", toolCalls: [] }), undefined);
    expect(out.text).toBe("Hello!");
    expect(out.toolCalls).toEqual([]);
    expect(out.usage).toBeUndefined();
  });
  test("parses a tool call whose args arrive as a JSON string", () => {
    const out = fromGenerateContentJson(
      JSON.stringify({
        text: "",
        toolCalls: [{ id: "c9", name: "proposeTimerStart", args: '{"minutes":10}' }]
      }),
      undefined
    );
    expect(out.toolCalls).toEqual([{ id: "c9", name: "proposeTimerStart", args: { minutes: 10 } }]);
  });
  test("keeps a tool call without args as exactly id+name", () => {
    const out = fromGenerateContentJson(
      JSON.stringify({ text: "", toolCalls: [{ id: "c1", name: "readPantry" }] }),
      undefined
    );
    expect(out.toolCalls).toEqual([{ id: "c1", name: "readPantry" }]);
  });
  test("rejects args that are not valid JSON", () => {
    expect(() =>
      fromGenerateContentJson(JSON.stringify({ text: "", toolCalls: [{ id: "c", name: "t", args: "{oops" }] }), undefined)
    ).toThrow(/not valid JSON/);
  });
  test("rejects a missing text field", () => {
    expect(() => fromGenerateContentJson(JSON.stringify({ toolCalls: [] }), undefined)).toThrow(/missing a string 'text'/);
  });
  test("rejects non-JSON and non-object responses", () => {
    expect(() => fromGenerateContentJson("not json", undefined)).toThrow(/required JSON object/);
    expect(() => fromGenerateContentJson("42", undefined)).toThrow(/required JSON object/);
  });
  test("rejects a non-array toolCalls field and a malformed tool call", () => {
    expect(() => fromGenerateContentJson(JSON.stringify({ text: "", toolCalls: "x" }), undefined)).toThrow(/non-array 'toolCalls'/);
    expect(() =>
      fromGenerateContentJson(JSON.stringify({ text: "", toolCalls: [{ id: "c" }] }), undefined)
    ).toThrow(/missing string 'id' or 'name'/);
  });
  test("maps usage when both token counts are present, undefined otherwise", () => {
    const mapped = fromGenerateContentJson(JSON.stringify({ text: "t" }), {
      promptTokenCount: 10,
      candidatesTokenCount: 4
    });
    expect(mapped.usage).toEqual({ inputTokens: 10, outputTokens: 4 });
    expect(fromGenerateContentJson(JSON.stringify({ text: "t" }), { promptTokenCount: 10 }).usage).toBeUndefined();
  });
});
