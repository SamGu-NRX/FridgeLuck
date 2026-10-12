/**
 * Gemini transport adapter — the ONLY file that knows how to reach a real
 * provider. Constructed exclusively by the explicit live command
 * (`--mode=live`, run/live.ts) after `readLiveConfig` has resolved the key
 * from the environment; the test suite never constructs it.
 *
 * Protocol: with `responseMimeType: "application/json"` and a response
 * schema of {text, toolCalls[]}, the model returns one structured JSON
 * object per round — the same shape the offline scripts carry as
 * `ScriptTurn.toolCalls`. Tool results are fed back as a user message
 * carrying their JSON, so the model sees the world state it asked for.
 *
 * The SDK call path (`send`) is exercised only by a live run. The request
 * and response MAPPINGS are pure and unit-tested against recorded shapes.
 */

import { Type, GoogleGenAI } from "@google/genai";
import type { LiveTransport, LiveTransportRequest, LiveTransportResponse } from "./types.js";

/** Strip a trailing version path — the SDK appends its own API version. */
export function stripVersionPath(endpoint: string): string {
  return endpoint.replace(/\/v1(beta)?\/?$/, "");
}

/** The structured response contract every live model round must return. */
const LIVE_RESPONSE_SCHEMA = {
  type: Type.OBJECT,
  properties: {
    text: { type: Type.STRING },
    toolCalls: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        properties: {
          id: { type: Type.STRING },
          name: { type: Type.STRING },
          // Free-form tool arguments travel as a JSON string — Gemini's
          // schema validation requires declared properties for OBJECT, and
          // the LeChef tool args are tool-specific.
          args: { type: Type.STRING }
        },
        required: ["id", "name"]
      }
    }
  },
  required: ["text"]
} as const;

interface GeminiContent {
  readonly role: "user" | "model";
  readonly parts: readonly { readonly text: string }[];
}

/** Map the neutral transport request onto Gemini `contents` (pure). */
export function toGenerateContents(request: LiveTransportRequest): {
  readonly system: string;
  readonly contents: { role: "user" | "model"; parts: { text: string }[] }[];
} {
  const contents: { role: "user" | "model"; parts: { text: string }[] }[] = request.messages.map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: m.text }]
  }));
  if (request.toolResults.length > 0) {
    const results = request.toolResults
      .map((t) => `  {"callId": ${JSON.stringify(t.callId)}, "name": ${JSON.stringify(t.name)}, "result": ${t.resultJson}}`)
      .join("\n");
    contents.push({
      role: "user",
      parts: [{ text: `TOOL RESULTS (the results of the tool calls you made):\n[\n${results}\n]` }]
    });
  }
  return { system: request.system, contents };
}

interface GeminiUsageMetadata {
  readonly promptTokenCount?: number;
  readonly candidatesTokenCount?: number;
}

/** Map the structured Gemini JSON onto the neutral transport response (pure). */
export function fromGenerateContentJson(
  raw: string,
  usage: GeminiUsageMetadata | undefined
): LiveTransportResponse {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new Error(`gemini response was not the required JSON object: ${raw.slice(0, 200)}`);
  }
  if (typeof parsed !== "object" || parsed === null) {
    throw new Error(`gemini response was not the required JSON object: ${raw.slice(0, 200)}`);
  }
  const rec = parsed as { text?: unknown; toolCalls?: unknown };
  if (typeof rec.text !== "string") {
    throw new Error("gemini response JSON is missing a string 'text' field");
  }
  const toolCalls: { id: string; name: string; args?: Record<string, unknown> }[] = [];
  if (rec.toolCalls !== undefined) {
    if (!Array.isArray(rec.toolCalls)) {
      throw new Error("gemini response JSON has a non-array 'toolCalls' field");
    }
    for (const call of rec.toolCalls) {
      if (typeof call !== "object" || call === null) {
        throw new Error("gemini tool call is not an object");
      }
      const c = call as { id?: unknown; name?: unknown; args?: unknown };
      if (typeof c.id !== "string" || typeof c.name !== "string") {
        throw new Error("gemini tool call is missing string 'id' or 'name'");
      }
      let args: Record<string, unknown> | undefined;
      if (c.args !== undefined) {
        if (typeof c.args !== "string") {
          throw new Error(`gemini tool call ${c.id}: 'args' must be a JSON string`);
        }
        try {
          const parsedArgs: unknown = JSON.parse(c.args);
          if (typeof parsedArgs !== "object" || parsedArgs === null) {
            throw new Error("not an object");
          }
          args = parsedArgs as Record<string, unknown>;
        } catch {
          throw new Error(`gemini tool call ${c.id}: 'args' is not valid JSON`);
        }
      }
      toolCalls.push(args === undefined ? { id: c.id, name: c.name } : { id: c.id, name: c.name, args });
    }
  }
  const mappedUsage =
    usage !== undefined &&
    typeof usage.promptTokenCount === "number" &&
    typeof usage.candidatesTokenCount === "number"
      ? { inputTokens: usage.promptTokenCount, outputTokens: usage.candidatesTokenCount }
      : undefined;
  return { text: rec.text, toolCalls, usage: mappedUsage };
}

export interface GeminiAdapterOptions {
  readonly apiKey: string;
  readonly model: string;
  /** Base URL override; a trailing /v1beta or /v1 version path is stripped. */
  readonly endpoint?: string;
  readonly maxOutputTokens: number;
}

export class GeminiLiveTransport implements LiveTransport {
  readonly name = "gemini";
  readonly model: string;
  private readonly client: GoogleGenAI;
  private readonly maxOutputTokens: number;

  constructor(options: GeminiAdapterOptions) {
    this.model = options.model;
    this.maxOutputTokens = options.maxOutputTokens;
    // Constructed only after readLiveConfig resolved the env key. The key is
    // passed to the SDK in memory — never logged, never written to disk.
    this.client = new GoogleGenAI({
      apiKey: options.apiKey,
      ...(options.endpoint !== undefined ? { httpOptions: { baseUrl: stripVersionPath(options.endpoint) } } : {})
    });
  }

  async send(request: LiveTransportRequest): Promise<LiveTransportResponse> {
    const { system, contents } = toGenerateContents(request);
    const response = await this.client.models.generateContent({
      model: this.model,
      contents,
      config: {
        systemInstruction: system,
        responseMimeType: "application/json",
        responseSchema: LIVE_RESPONSE_SCHEMA,
        maxOutputTokens: this.maxOutputTokens
      }
    });
    return fromGenerateContentJson(response.text ?? "", response.usageMetadata);
  }
}
