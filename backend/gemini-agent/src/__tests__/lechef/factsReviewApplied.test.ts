/**
 * Planted-input contract tests for run/apply-facts-review.ts: idempotence and
 * every refusal rule, exercised on small planted canons in temp directories so
 * the real canon and review bands are never touched.
 *
 * The planted canon uses the canon's format (JSON, two-space indent, no
 * trailing newline); `before_sha256` is computed the way the apply script
 * computes it — sha256 over JSON.stringify of the parsed fact.
 */

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { applied, applyFactsReview, type ApplyPaths, type ReviewEntry } from "../../run/apply-facts-review.js";

const REVIEW_SCHEMA = "fridgeluck/facts-review/v1";

interface PlantedFact {
  readonly label: string;
  readonly allergens: Readonly<Record<string, { readonly state: string }>>;
  readonly components?: readonly { readonly key: string; readonly certainty?: string }[];
}

function sha256(fact: unknown): string {
  return createHash("sha256").update(JSON.stringify(fact), "utf8").digest("hex");
}

function state(value: string): { state: string } {
  return { state: value };
}

function plantFacts(): Record<string, PlantedFact> {
  return {
    "a-thing": { label: "A thing", allergens: { milk: state("unknown"), wheat: state("unknown") } },
    "b-thing": { label: "B thing", allergens: { milk: state("contains"), wheat: state("unknown") } },
    "c-thing": { label: "C thing", allergens: { milk: state("unknown"), wheat: state("free") } },
    "d-thing": { label: "D thing", allergens: { milk: state("free"), wheat: state("free") } },
  };
}

function writeCanon(dir: string, facts: Record<string, PlantedFact>): ApplyPaths {
  writeFileSync(join(dir, "facts.json"), JSON.stringify({ version: 1, facts }, null, 2));
  return { factsPath: join(dir, "facts.json"), reviewDir: join(dir, "review") };
}

interface BandSpec {
  readonly name: string;
  readonly first: string;
  readonly last: string;
  readonly reviews: readonly ReviewEntry[];
}

function writeBand(paths: ApplyPaths, band: BandSpec): void {
  rmSync(paths.reviewDir, { recursive: true, force: true });
  mkdirSync(paths.reviewDir, { recursive: true });
  writeFileSync(
    join(paths.reviewDir, band.name),
    JSON.stringify(
      {
        schema: REVIEW_SCHEMA,
        packet: band.name,
        base_commit: "0000000000000000000000000000000000000000",
        band: { first: band.first, last: band.last, count: band.reviews.length },
        reviews: band.reviews,
      },
      null,
      2
    )
  );
}

/** A review entry carrying a full allergens block for the fact as planted. */
function reviewFor(fact: PlantedFact, key: string, overrides: Partial<ReviewEntry> = {}): ReviewEntry {
  return {
    key,
    before_sha256: sha256(fact),
    allergens: {
      milk: { state: "free", evidence: { kind: "reference", ref: "https://example.test/a", note: "x (retrieved 2026-10-16)" } },
      wheat: { state: "free", evidence: { kind: "reference", ref: "https://example.test/b", note: "x (retrieved 2026-10-16)" } },
    },
    ...overrides,
  };
}

function withTempDir(run: (dir: string, paths: ApplyPaths) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "apply-facts-review-test-"));
  try {
    const paths = writeCanon(dir, plantFacts());
    run(dir, paths);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("apply facts review (planted inputs)", () => {
  test("applies hash-matching reviews, rewrites only reviewed facts, keeps the canon format", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      const band: BandSpec = {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      };
      writeBand(paths, band);

      const report = applyFactsReview(paths, true);
      expect(report.applied.map((r) => r.key)).toEqual(["a-thing", "b-thing", "c-thing"]);
      expect(report.unchanged).toEqual([]);
      expect(report.refused).toEqual([]);

      const raw = readFileSync(paths.factsPath, "utf8");
      // format: two-space indent, no trailing newline
      expect(raw.endsWith("}") && !raw.endsWith("\n")).toBe(true);
      const after = JSON.parse(raw);
      // key order kept, and the untouched fact is byte-identical
      expect(Object.keys(after.facts)).toEqual(["a-thing", "b-thing", "c-thing", "d-thing"]);
      expect(JSON.stringify(after.facts["d-thing"])).toEqual(JSON.stringify(canon.facts["d-thing"]));
      // reviewed states landed
      expect(after.facts["b-thing"].allergens.milk.state).toEqual("free");
    });
  });

  test("a second apply is a no-op byte for byte (already-applied is not a refusal)", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      });
      const first = applyFactsReview(paths, true);
      expect(first.applied.length).toEqual(3);
      const bytes = readFileSync(paths.factsPath, "utf8");

      // the pinned hashes no longer match (facts changed), yet nothing is refused:
      // each fact already equals its review applied.
      const second = applyFactsReview(paths, true);
      expect(second.applied).toEqual([]);
      expect(second.unchanged.map((r) => r.key).sort()).toEqual(["a-thing", "b-thing", "c-thing"]);
      expect(second.refused).toEqual([]);
      expect(second.wrote).toBe(false);
      expect(readFileSync(paths.factsPath, "utf8")).toEqual(bytes);
    });
  });

  test("applies a review that pins its applied state and is a no-op afterwards", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      const entry = reviewFor(canon.facts["a-thing"], "a-thing", {
        after_sha256: sha256(applied(canon.facts["a-thing"], reviewFor(canon.facts["a-thing"], "a-thing"))),
      });
      writeBand(paths, { name: "band-a.json", first: "a-thing", last: "a-thing", reviews: [entry] });

      const first = applyFactsReview(paths, true);
      expect(first.applied.map((r) => r.key)).toEqual(["a-thing"]);
      expect(first.refused).toEqual([]);
      const bytes = readFileSync(paths.factsPath, "utf8");

      const second = applyFactsReview(paths, true);
      expect(second.applied).toEqual([]);
      expect(second.unchanged.map((r) => r.key)).toEqual(["a-thing"]);
      expect(second.refused).toEqual([]);
      expect(second.wrote).toBe(false);
      expect(readFileSync(paths.factsPath, "utf8")).toEqual(bytes);
    });
  });

  test("refuses a stale fact whose reviewed fields match but which drifted elsewhere", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      const entry = reviewFor(canon.facts["a-thing"], "a-thing", {
        after_sha256: sha256(applied(canon.facts["a-thing"], reviewFor(canon.facts["a-thing"], "a-thing"))),
      });
      writeBand(paths, { name: "band-a.json", first: "a-thing", last: "a-thing", reviews: [entry] });
      // The fact drifts in a field the review does not overwrite AFTER the
      // review pinned it. Its allergens still equal the entry's, so an
      // "already applied" check that only compares the reviewed fields is
      // trivially true — the pinned applied state must reject it as stale.
      const drifted = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      drifted.facts["a-thing"].note = "composition changed since the review";
      writeFileSync(paths.factsPath, JSON.stringify(drifted, null, 2));

      const report = applyFactsReview(paths, true);
      expect(report.applied).toEqual([]);
      expect(report.unchanged).toEqual([]);
      expect(report.refused.length).toEqual(1);
      expect(report.refused[0].key).toEqual("a-thing");
      expect(report.refused[0].reason).toContain("does not match the review's pinned applied state either");
      const after = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      expect(JSON.stringify(after.facts["a-thing"])).toEqual(JSON.stringify(drifted.facts["a-thing"]));
    });
  });

  test("refuses a packet whose application would not produce its pinned applied state", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      const entry = reviewFor(canon.facts["a-thing"], "a-thing", { after_sha256: "f".repeat(64) });
      writeBand(paths, { name: "band-a.json", first: "a-thing", last: "a-thing", reviews: [entry] });

      const report = applyFactsReview(paths, true);
      expect(report.applied).toEqual([]);
      expect(report.refused.length).toEqual(1);
      expect(report.refused[0].key).toEqual("a-thing");
      expect(report.refused[0].reason).toContain("after_sha256 mismatch");
      const after = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      expect(JSON.stringify(after.facts["a-thing"])).toEqual(JSON.stringify(canon.facts["a-thing"]));
    });
  });

  test("refuses a before_sha256 mismatch and leaves the fact exactly as it was", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing", { before_sha256: "0".repeat(64) }),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      });

      const report = applyFactsReview(paths, true);
      expect(report.applied.map((r) => r.key)).toEqual(["a-thing", "c-thing"]);
      expect(report.refused.length).toEqual(1);
      expect(report.refused[0].key).toEqual("b-thing");
      expect(report.refused[0].reason).toContain("before_sha256 mismatch");

      const after = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      expect(JSON.stringify(after.facts["b-thing"])).toEqual(JSON.stringify(canon.facts["b-thing"]));
    });
  });

  test("refuses a key reviewed in two files, in every file that carries it, and still applies the rest", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      });
      // a second file whose band overlaps on b and c
      writeFileSync(
        join(paths.reviewDir, "band-b.json"),
        JSON.stringify(
          {
            schema: REVIEW_SCHEMA,
            packet: "band-b.json",
            base_commit: "0000000000000000000000000000000000000000",
            band: { first: "b-thing", last: "d-thing", count: 3 },
            reviews: [
              reviewFor(canon.facts["b-thing"], "b-thing"),
              reviewFor(canon.facts["c-thing"], "c-thing"),
              reviewFor(canon.facts["d-thing"], "d-thing"),
            ],
          },
          null,
          2
        )
      );

      const report = applyFactsReview(paths, true);
      const refusedKeys = report.refused.filter((r) => r.key !== null).map((r) => r.key).sort();
      expect(refusedKeys).toEqual(["b-thing", "b-thing", "c-thing", "c-thing"]);
      expect(report.refused.every((r) => r.key === null || r.reason.startsWith("key reviewed in two files"))).toBe(true);
      // the unambiguous keys still apply
      expect(report.applied.map((r) => r.key).sort()).toEqual(["a-thing", "d-thing"]);
    });
  });

  test("refuses a whole band file that misses a band key: nothing from it applies", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      const good: BandSpec = {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      };
      writeBand(paths, good);
      // band-b.json must cover b..d but skips c
      writeFileSync(
        join(paths.reviewDir, "band-b.json"),
        JSON.stringify(
          {
            schema: REVIEW_SCHEMA,
            packet: "band-b.json",
            base_commit: "0000000000000000000000000000000000000000",
            band: { first: "b-thing", last: "d-thing", count: 2 },
            reviews: [reviewFor(canon.facts["b-thing"], "b-thing"), reviewFor(canon.facts["d-thing"], "d-thing")],
          },
          null,
          2
        )
      );

      const report = applyFactsReview(paths, true);
      const fileRefusals = report.refused.filter((r) => r.key === null);
      expect(fileRefusals.length).toEqual(1);
      expect(fileRefusals[0].packet).toEqual("band-b.json");
      expect(fileRefusals[0].reason).toContain("does not cover its band");
      expect(fileRefusals[0].reason).toContain("missing: c-thing");
      // band-a still applied; band-b's keys (b, d) untouched by band-b
      expect(report.applied.map((r) => r.key)).toEqual(["a-thing", "b-thing", "c-thing"]);
    });
  });

  test("refuses keys outside the band — including a key with no fact in facts.json", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      // outside the band: e-thing sorts after band.last
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "d-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
          reviewFor(canon.facts["d-thing"], "d-thing"),
          reviewFor(canon.facts["a-thing"], "e-thing"),
        ],
      });
      const outside = applyFactsReview(paths, false);
      expect(outside.refused.length).toEqual(1);
      expect(outside.refused[0].reason).toContain("outside the band: e-thing");
      expect(outside.applied).toEqual([]);

      // a key inside the band range but absent from facts.json is refused the
      // same way: the band coverage check runs against the facts that exist, so
      // the file cannot smuggle in a key with no fact (the "no such fact"
      // refusal in the apply script is defense-in-depth behind this check).
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "e-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing"),
          reviewFor(canon.facts["c-thing"], "c-thing"),
          reviewFor(canon.facts["d-thing"], "d-thing"),
          reviewFor(canon.facts["a-thing"], "e-thing"),
        ],
      });
      const missing = applyFactsReview(paths, false);
      expect(missing.refused.length).toEqual(1);
      expect(missing.refused[0].key).toEqual(null);
      expect(missing.refused[0].reason).toContain("outside the band: e-thing");
      expect(missing.applied).toEqual([]);
    });
  });

  test("refuses a review that carries no allergens block", () => {
    withTempDir((dir, paths) => {
      const canon = JSON.parse(readFileSync(paths.factsPath, "utf8"));
      writeBand(paths, {
        name: "band-a.json",
        first: "a-thing",
        last: "c-thing",
        reviews: [
          reviewFor(canon.facts["a-thing"], "a-thing"),
          reviewFor(canon.facts["b-thing"], "b-thing", { allergens: undefined }),
          reviewFor(canon.facts["c-thing"], "c-thing"),
        ],
      });

      const report = applyFactsReview(paths, false);
      expect(report.refused.length).toEqual(1);
      expect(report.refused[0].key).toEqual("b-thing");
      expect(report.refused[0].reason).toEqual("review carries no allergens block");
      expect(report.applied.map((r) => r.key)).toEqual(["a-thing", "c-thing"]);
    });
  });
});
