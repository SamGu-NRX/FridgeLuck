import { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";

/**
 * Creates the model client, or returns null when the deployment has no
 * usable model credentials.
 *
 * Fail-safe choice: loadConfig used to THROW when no GEMINI_API_KEY / Vertex
 * project was present, which took the whole service down — health checks,
 * webhook contract, and all. Now a credential-less deployment boots into a
 * degraded mode: free routes and webhooks work; paid-model routes return
 * 503 model_unavailable; the live gateway closes connections with a stable
 * code. A configured-but-public deployment is a different risk and is
 * addressed by rate limiting + payload bounds, not by pretending routes are
 * closed. See HARDENING.md.
 */
export function createGenAIClient(config: AppConfig): GoogleGenAI | null {
  if (!config.genaiConfigured) {
    return null;
  }

  if (config.useVertexAi) {
    return new GoogleGenAI({
      vertexai: true,
      project: config.projectId,
      location: config.location,
      apiVersion: "v1"
    });
  }

  return new GoogleGenAI({ apiKey: config.apiKey });
}
