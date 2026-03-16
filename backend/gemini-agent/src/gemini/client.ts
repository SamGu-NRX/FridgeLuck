import { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";

export function createGenAIClient(config: AppConfig): GoogleGenAI {
  if (config.useVertexAi) {
    return new GoogleGenAI({
      vertexai: true,
      project: config.projectId,
      location: config.location
    });
  }

  return new GoogleGenAI({ apiKey: config.apiKey });
}
