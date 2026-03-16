import { describe, expect, it } from "bun:test";
import { assertSupportedLiveModel } from "../config.js";

describe("assertSupportedLiveModel", () => {
  it("accepts supported live models", () => {
    expect(assertSupportedLiveModel("gemini-2.5-flash-native-audio-preview-12-2025")).toBe(
      "gemini-2.5-flash-native-audio-preview-12-2025"
    );
  });

  it("rejects deprecated live models", () => {
    expect(() => assertSupportedLiveModel("gemini-live-2.5-flash-preview")).toThrow(
      "deprecated"
    );
  });
});
