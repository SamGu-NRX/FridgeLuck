import { describe, it, expect } from "bun:test";
import { CameraLintError, lintCameraObservations } from "../../lechef/cameraLint.js";
import { requestCameraLook, type CameraDevice, type ReadDeps } from "../../lechef/reads.js";
import type { CookSessionSnapshot, PantrySnapshot, RecipeContext } from "../../lechef/types.js";

const deps: ReadDeps = {
  pantry: () => ({ revision: 1, capturedAt: 0 as never, items: [] }) as unknown as PantrySnapshot,
  session: () => ({}) as unknown as CookSessionSnapshot,
  catalog: () => [] as RecipeContext[],
  swapViolations: () => []
};

function device(observed: string[], cannotAssess: string[] = []): CameraDevice {
  return {
    mode: "continuous",
    capture: () => ({
      observed,
      cannotAssess,
      framesSent: 2,
      clipSeconds: 2
    })
  };
}

describe("cameraLint: lintCameraObservations", () => {
  it("passes visual descriptions through (browning, size, consistency)", () => {
    const clean = [
      "golden-brown crust on the chicken",
      "fillet about 2 cm thick, edges opaque",
      "cheese melted evenly, no browning yet",
      "sauce reduced by roughly half"
    ];
    expect(lintCameraObservations(clean)).toEqual([]);
  });

  it("refuses safe/unsafe-to-eat verdicts", () => {
    for (const observation of [
      "chicken is safe to eat",
      "the pork looks SAFE TO EAT",
      "salmon unsafe to eat raw",
      "this looks fit to eat",
      "ready to eat now"
    ]) {
      const findings = lintCameraObservations([observation]);
      expect(findings.length).toBe(1);
      expect(findings[0].observation).toBe(observation);
    }
  });

  it("refuses doneness verdicts", () => {
    for (const observation of ["the breast is cooked through", "fully cooked and juicy", "still undercooked in the middle", "it is done"]) {
      expect(lintCameraObservations([observation]).length).toBe(1);
    }
  });

  it("refuses spoilage verdicts", () => {
    for (const observation of ["not spoiled", "the milk is spoiled", "no signs of spoilage", "no signs of bacteria on the surface"]) {
      expect(lintCameraObservations([observation]).length).toBe(1);
    }
  });

  it("refuses a temperature reading paired with a safety predicate, but not the halves alone", () => {
    // verdict: temperature + safety
    expect(lintCameraObservations(["internal temperature is 74 C so it is safe"]).length).toBe(1);
    expect(lintCameraObservations(["core temperature 60 degrees C — bacteria are dead"]).length).toBe(1);
    // measurement alone is description, not a verdict
    expect(lintCameraObservations(["internal temperature reads about 60 C at the edge"]).length).toBe(0);
    // safety word without temperature is caught only by the closed list
    expect(lintCameraObservations(["looks safe enough to me — nice sear"]).length).toBe(0);
  });

  it("reports one finding per offending observation, in order", () => {
    const findings = lintCameraObservations(["golden crust", "cooked through", "safe to eat"]);
    expect(findings.length).toBe(2);
    expect(findings[0].observation).toBe("cooked through");
    expect(findings[1].observation).toBe("safe to eat");
  });
});

describe("cameraLint: requestCameraLook wiring (SPEC 3.1)", () => {
  it("relays benign observations and keeps cannotAssess intact", () => {
    const r = requestCameraLook(deps, device(["golden-brown crust", "about 2 cm thick"], ["doneness", "internal temperature"]));
    expect(r.safetyVerdict).toBeNull();
    expect(r.look.observed).toEqual(["golden-brown crust", "about 2 cm thick"]);
    expect(r.look.cannotAssess).toEqual(["doneness", "internal temperature"]);
    expect(r.unknowns.some((u) => u.includes("never establish doneness or safety"))).toBe(true);
  });

  it("refuses to relay verdict language supplied by the capture", () => {
    expect(() => requestCameraLook(deps, device(["chicken is safe to eat"]))).toThrow(CameraLintError);
    expect(() => requestCameraLook(deps, device(["browning ok", "cooked through"]))).toThrow(/cooked through/);
  });

  it("cannotAssess strings are statements of inability, not verdicts — they pass", () => {
    const r = requestCameraLook(deps, device(["surface browning visible"], ["cannot assess: safe to eat or not"]));
    expect(r.look.observed).toEqual(["surface browning visible"]);
  });

  it("refuses temperature-safety verdicts supplied by the capture", () => {
    expect(() => requestCameraLook(deps, device(["internal temperature is 74 C so it is safe"]))).toThrow(CameraLintError);
  });
});
