// Boundary and parity tests for the restock automation (restockJob).
//
// Every test drives the REAL production functions (src/automation/restockJob.ts)
// with the clock pinned via Bun's setSystemTime. Expectations come from the
// hand-checked fixtures in ../fixtures/matrix.ts. The reference model in
// ../reference/model.ts is proven equal to production here (parity tests) and
// by the seeded pipeline's parity check, so the pipeline can use it to record
// where the elapsed-day interpretation and the UTC reference-date
// interpretation disagree. No test resolves that product-policy divergence.

import { describe, expect, it, setSystemTime } from "bun:test";
import {
  buildRestockPlan,
  computeRestockList,
  computeUseSoon,
} from "../../../../src/automation/restockJob.js";
import {
  cutoffRows,
  divergenceRows,
  expiredInvalidMissing,
  item,
  longExpiredRow,
  midnightRows,
  T_2026_10_10,
  thresholdEqualityRows,
} from "../fixtures/matrix.js";
import {
  classifyA,
  classifyB,
  referenceComputeRestockList,
  referenceComputeUseSoon,
} from "../reference/model.js";

function withClock<T>(pinMs: number, run: () => T): T {
  setSystemTime(pinMs);
  try {
    return run();
  } finally {
    setSystemTime();
  }
}

describe("UTC midnight and instant boundaries around a date-only expiry", () => {
  for (const row of midnightRows) {
    it(row.label, () => {
      const result = withClock(row.pinMs, () =>
        computeUseSoon([item("Probe", row.grams, row.expiry)], row.thresholdDays)
      );
      if (row.expectIncluded) {
        expect(result).toEqual([
          {
            ingredientName: "Probe",
            expiresAt: row.expiry,
            daysRemaining: row.expectDisplayDays,
          },
        ]);
      } else {
        expect(result).toEqual([]);
      }
    });
  }
});

describe("threshold equality is inclusive", () => {
  for (const row of thresholdEqualityRows) {
    it(row.label, () => {
      const result = withClock(row.pinMs, () =>
        computeUseSoon([item("Probe", row.grams, row.expiry)], row.thresholdDays)
      );
      expect(result.map((a) => a.daysRemaining)).toEqual(
        row.expectIncluded ? [row.expectDisplayDays] : []
      );
    });
  }
});

describe("missing, invalid, and expired dates", () => {
  for (const row of expiredInvalidMissing) {
    it(row.label, () => {
      const alerts = withClock(row.pinMs, () =>
        computeUseSoon(row.items, row.thresholdDays)
      );
      expect(alerts.map((a) => a.ingredientName)).toEqual(row.expectAlertNames);
    });
  }

  it("an expired, depleted item appears in both lists", () => {
    const row = expiredInvalidMissing.find((r) => r.expectAlertNames.length > 0)!;
    const outputs = withClock(row.pinMs, () => ({
      alerts: computeUseSoon(row.items, row.thresholdDays),
      restock: computeRestockList(row.items, 50),
    }));
    expect(outputs.alerts.map((a) => a.ingredientName)).toEqual(["OldYogurt"]);
    expect(outputs.restock).toEqual(["OldYogurt"]);
  });

  it("the long-expired row keeps alerting with a clamped display of 0", () => {
    const row = longExpiredRow;
    const alerts = withClock(row.pinMs, () =>
      computeUseSoon([item("Probe", row.grams, row.expiry)], row.thresholdDays)
    );
    expect(alerts).toEqual([
      { ingredientName: "Probe", expiresAt: row.expiry, daysRemaining: 0 },
    ]);
  });
});

describe("exact quantity cutoff uses strict less-than", () => {
  for (const row of cutoffRows) {
    it(row.label, () => {
      const list = withClock(T_2026_10_10, () =>
        computeRestockList([item("Probe", row.grams)], row.cutoff)
      );
      expect(list).toEqual(row.expectInRestockList ? ["Probe"] : []);
    });
  }

  it("the default cutoff is 50 grams", () => {
    const outputs = withClock(T_2026_10_10, () => ({
      at: computeRestockList([item("X", 50)]),
      below: computeRestockList([item("X", 49)]),
    }));
    expect(outputs.at).toEqual([]);
    expect(outputs.below).toEqual(["X"]);
  });
});

describe("duplicates and ordering", () => {
  it("the restock list keeps one entry per below-cutoff item (no dedup)", () => {
    const list = withClock(T_2026_10_10, () =>
      computeRestockList([
        item("Milk", 30),
        item("Milk", 45),
        item("Milk", 80),
        item("Eggs", 10),
      ])
    );
    expect(list).toEqual(["Eggs", "Milk", "Milk"]);
  });

  it("partial duplicates: one under and one over the cutoff yields a single entry", () => {
    const list = withClock(T_2026_10_10, () =>
      computeRestockList([item("Milk", 30), item("Milk", 80)])
    );
    expect(list).toEqual(["Milk"]);
  });

  it("equal daysRemaining keep input order (stable sort over ties)", () => {
    const a = item("Alpha", 500, "2026-10-11");
    const b = item("Beta", 500, "2026-10-11");
    const forward = withClock(T_2026_10_10, () => computeUseSoon([a, b], 1));
    const backward = withClock(T_2026_10_10, () => computeUseSoon([b, a], 1));
    expect(forward.map((x) => x.ingredientName)).toEqual(["Alpha", "Beta"]);
    expect(backward.map((x) => x.ingredientName)).toEqual(["Beta", "Alpha"]);
  });

  it("alerts are sorted ascending by daysRemaining", () => {
    const alerts = withClock(T_2026_10_10, () =>
      computeUseSoon(
        [
          item("Distant", 500, "2026-10-13"), // raw 3
          item("Expired", 500, "2026-10-08"), // raw -2 → display 0
          item("Near", 500, "2026-10-12"), // raw 2
        ],
        3
      )
    );
    expect(alerts.map((a) => a.ingredientName)).toEqual(["Expired", "Near", "Distant"]);
    expect(alerts.map((a) => a.daysRemaining)).toEqual([0, 2, 3]);
  });
});

describe("generatedAt reproducibility", () => {
  it("two plans in the same pinned instant share one generatedAt", () => {
    const plan = (threshold: number) =>
      withClock(T_2026_10_10, () =>
        buildRestockPlan({
          inventorySnapshot: [item("Milk", 30, "2026-10-11")],
          thresholdDays: threshold,
        })
      );
    expect(plan(1).generatedAt).toBe("2026-10-10T00:00:00.000Z");
    expect(plan(3).generatedAt).toBe("2026-10-10T00:00:00.000Z");
  });

  it("alerts follow the pinned clock while generatedAt is stamped from the same pin", () => {
    const sixHoursLater = T_2026_10_10 + 6 * 60 * 60 * 1000;
    const at = (pin: number) =>
      withClock(pin, () =>
        buildRestockPlan({
          inventorySnapshot: [item("Milk", 30, "2026-10-11")],
          thresholdDays: 1,
        })
      );
    const first = at(T_2026_10_10);
    const later = at(sixHoursLater);
    expect(later.useSoonAlerts).toEqual(first.useSoonAlerts); // still exactly 1 day out under elapsed arithmetic
    expect(first.generatedAt).toBe("2026-10-10T00:00:00.000Z");
    expect(later.generatedAt).toBe("2026-10-10T06:00:00.000Z");
  });

  it("on the real clock generatedAt is wall-clock time, so unpinned runs are not reproducible", () => {
    const before = Date.now();
    const plan = buildRestockPlan({
      inventorySnapshot: [item("Milk", 30, "2026-10-11")],
      thresholdDays: 1,
    });
    const after = Date.now();
    const at = new Date(plan.generatedAt).getTime();
    expect(at).toBeGreaterThanOrEqual(before);
    expect(at).toBeLessThanOrEqual(after);
  });
});

describe("reference model parity with production", () => {
  const allRows = [...midnightRows, ...thresholdEqualityRows, ...divergenceRows];

  it("the reference mirror reproduces computeUseSoon over every boundary row", () => {
    for (const row of allRows) {
      const probe = [item("Probe", row.grams, row.expiry)];
      const outputs = withClock(row.pinMs, () => ({
        real: computeUseSoon(probe, row.thresholdDays),
        ref: referenceComputeUseSoon(probe, row.pinMs, row.thresholdDays),
      }));
      expect(outputs.ref).toEqual(outputs.real);
    }
  });

  it("the reference mirror reproduces computeRestockList over every cutoff row", () => {
    for (const row of cutoffRows) {
      const probe = [item("Probe", row.grams)];
      const outputs = withClock(T_2026_10_10, () => ({
        real: computeRestockList(probe, row.cutoff),
        ref: referenceComputeRestockList(probe, row.cutoff),
      }));
      expect(outputs.ref).toEqual(outputs.real);
    }
  });

  it("records the elapsed vs reference-date divergence without resolving it", () => {
    const row = divergenceRows[0]!;
    const probe = [item("Probe", row.grams, row.expiry)];
    const realAlerts = withClock(row.pinMs, () =>
      computeUseSoon(probe, row.thresholdDays)
    );
    const viewA = classifyA(probe[0]!, row.pinMs, row.thresholdDays);
    const viewB = classifyB(probe[0]!, row.pinMs, row.thresholdDays);

    // Production (elapsed arithmetic): excluded at this instant.
    expect(realAlerts).toEqual([]);
    expect(viewA.alerted).toBe(false);
    // Reference-date interpretation: would alert at this instant.
    expect(viewB.alerted).toBe(true);
    expect(viewB.refDiff).toBe(row.refDateDiff);
  });
});
