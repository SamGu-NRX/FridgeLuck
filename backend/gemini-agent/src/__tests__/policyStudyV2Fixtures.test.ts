import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

/**
 * Strict schema/group/hash tests for the frozen policy-study-v2 request
 * family (spec: evaluation-fixtures/policy-study-v2/policy-study-spec-v2.md).
 *
 * These tests treat the committed files as frozen bytes: if any file changes
 * without regenerating build-manifest.json, the hash tests fail.
 */

const FIXTURES = join(import.meta.dir, "../../evaluation-fixtures/policy-study-v2");

function readLines(name: string): Record<string, unknown>[] {
  return readFileSync(join(FIXTURES, name), "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l) as Record<string, unknown>);
}

function sha256(name: string): string {
  return createHash("sha256").update(readFileSync(join(FIXTURES, name))).digest("hex");
}

const manifest = JSON.parse(readFileSync(join(FIXTURES, "build-manifest.json"), "utf8")) as {
  version: string;
  counts: Record<string, number>;
  eligible_counts: Record<string, number>;
  unknown_counts: Record<string, number>;
  information_collisions: Record<string, unknown>;
  pr41_source: { branch: string; file: string; sha256: string; consumption: string };
  file_sha256: Record<string, string>;
  constants: Record<string, number>;
};

const sourceHashes = JSON.parse(readFileSync(join(FIXTURES, "source-hashes.json"), "utf8")) as {
  "pr41-nutrition5k-portion-frozen-references": { files: Record<string, { sha256: string }> };
};

const cases = readLines("cases.jsonl");
const requests = readLines("requests.jsonl");
const labels = readLines("labels.jsonl");
const replay = JSON.parse(readFileSync(join(FIXTURES, "replay.json"), "utf8")) as {
  version: string;
  episodes: { case_id: string; action: string; reward: number }[];
};

function detectionsOf(row: Record<string, unknown>): [number, number][] {
  return row.detections as [number, number][];
}

describe("policy-study-v2 build manifest", () => {
  test("manifest version and frozen constants", () => {
    expect(manifest.version).toBe("policy-study-v2");
    // Pre-registered constants (spec v1 §4, unchanged).
    expect(manifest.constants.P_PRESENT_N5K).toBe(0.85);
    expect(manifest.constants.P_PRESENT_F101_REQUIRED).toBe(0.9);
    expect(manifest.constants.P_PRESENT_F101_OPTIONAL).toBe(0.65);
    expect(manifest.constants.CONF_BASE).toBe(0.45);
    expect(manifest.constants.CONF_SPAN).toBe(0.5);
    expect(manifest.constants.CONF_A).toBe(8.2);
    expect(manifest.constants.CONF_B).toBe(2.2);
    expect(manifest.constants.FP_COUNTS).toEqual([0, 1, 2]);
    expect(manifest.constants.FP_PROBS).toEqual([0.53, 0.35, 0.12]);
    expect(manifest.constants.FP_CONF_BASE).toBe(0.45);
    expect(manifest.constants.FP_CONF_SPAN).toBe(0.35);
    expect(manifest.constants.AMOUNT_FLOOR_G).toBe(10);
    expect(manifest.constants.N5K_DEV_N).toBe(200);
    expect(manifest.constants.N5K_EVAL_N).toBe(600);
    expect(manifest.constants.F101_PER_CLASS).toBe(34);
  });

  test("every listed file hash matches the committed bytes", () => {
    expect(Object.keys(manifest.file_sha256).length).toBeGreaterThan(5);
    for (const [name, want] of Object.entries(manifest.file_sha256)) {
      expect(existsSync(join(FIXTURES, name))).toBe(true);
      expect(sha256(name)).toBe(want);
    }
  });

  test("slice counts match the frozen families", () => {
    expect(manifest.counts["n5k-plate/dev"]).toBe(200);
    expect(manifest.counts["n5k-plate/eval"]).toBe(600);
    expect(manifest.counts["food101-photo/eval"]).toBe(408);
    expect(Object.keys(manifest.counts).length).toBe(3);
    expect(manifest.eligible_counts["n5k-plate"]).toBeGreaterThanOrEqual(800);
    expect(manifest.eligible_counts["food101-photo"]).toBe(3000);
  });

  test("per-target unknown counts match the adjudicability matrix", () => {
    // spec §2: N5k plates have no recipe/category labels; Food-101 has no masses.
    expect(manifest.unknown_counts.native_recipe_identity_unknown).toBe(600);
    expect(manifest.unknown_counts.dish_category_unknown).toBe(600);
    expect(manifest.unknown_counts.weighed_mass_unknown).toBe(408);
  });

  test("information-collision counts are committed and consistent", () => {
    const col = manifest.information_collisions as {
      groups: number; cases: number; conflicting_groups: number; conflicting_cases: number;
    };
    expect(col.groups).toBeGreaterThan(0);
    expect(col.cases).toBeGreaterThan(col.groups);
    expect(col.conflicting_groups).toBeLessThanOrEqual(col.groups);
    expect(col.conflicting_cases).toBeLessThanOrEqual(col.cases);
  });

  test("PR 41 source is recorded as read-only with a pinned hash", () => {
    expect(manifest.pr41_source.branch).toBe("obv/fl-next-portion-estimates");
    expect(manifest.pr41_source.file).toBe("experiments/nutrition5k-portion/data/dish_targets.csv");
    expect(manifest.pr41_source.sha256).toBe(
      sourceHashes["pr41-nutrition5k-portion-frozen-references"].files[
        "experiments/nutrition5k-portion/data/dish_targets.csv"
      ].sha256,
    );
    expect(manifest.pr41_source.consumption).toContain("read-only");
  });
});

describe("policy-study-v2 request/label separation", () => {
  test("requests carry only case_id and detections — no truth leakage", () => {
    for (const row of requests) {
      expect(Object.keys(row).sort()).toEqual(["case_id", "detections"]);
    }
  });

  test("detections are sorted [id, confidence] pairs with unique ids and open-interval confidences", () => {
    for (const row of requests) {
      const dets = detectionsOf(row);
      expect(Array.isArray(dets)).toBe(true);
      const ids: number[] = [];
      for (const pair of dets) {
        expect(Array.isArray(pair)).toBe(true);
        expect((pair as unknown[]).length).toBe(2);
        const [id, conf] = pair as [number, number];
        expect(Number.isInteger(id)).toBe(true);
        expect(id).toBeGreaterThan(0);
        expect(conf).toBeGreaterThan(0);
        expect(conf).toBeLessThan(1);
        expect(Math.abs(conf * 1e6 - Math.round(conf * 1e6))).toBeLessThan(1e-6); // 6 dp
        ids.push(id);
      }
      expect([...ids].sort((a, b) => a - b)).toEqual(ids); // sorted
      expect(new Set(ids).size).toBe(ids.length); // unique
    }
  });
});

describe("policy-study-v2 registry and labels", () => {
  const requestsById = new Map(requests.map((r) => [r.case_id as string, r]));
  const labelsById = new Map(labels.map((l) => [l.case_id as string, l]));

  test("every case has exactly one request; eval cases have labels; dev cases do not", () => {
    expect(cases.length).toBe(requests.length);
    for (const c of cases) {
      expect(requestsById.has(c.case_id as string)).toBe(true);
      expect(Object.keys(c).sort()).toEqual(["case_id", "slice", "source_ref", "stratum"]);
      expect(["dev", "eval"]).toContain(c.slice);
      expect(["n5k-plate", "food101-photo"]).toContain(c.stratum);
      if (c.slice === "eval") {
        expect(labelsById.has(c.case_id as string)).toBe(true);
      } else {
        expect(labelsById.has(c.case_id as string)).toBe(false);
      }
    }
    expect(labels.length).toBe(600 + 408);
  });

  test("dev and eval slices are disjoint case-id sets", () => {
    const dev = cases.filter((c) => c.slice === "dev").map((c) => c.case_id as string);
    const ev = cases.filter((c) => c.slice === "eval").map((c) => c.case_id as string);
    expect(new Set(dev).size).toBe(dev.length);
    expect(new Set(ev).size).toBe(ev.length);
    for (const id of dev) expect(ev.includes(id)).toBe(false);
  });

  test("labels carry the three explicit targets with per-stratum adjudicability", () => {
    for (const l of labels) {
      const expectedKeys = ["case_id", "stratum", "targets", "truth_ingredient_ids"];
      if (l.stratum === "n5k-plate") expectedKeys.push("pr41_reference");
      else expectedKeys.push("optional_ingredient_ids");
      expect(Object.keys(l).sort()).toEqual(expectedKeys.sort());
      const targets = l.targets as Record<string, unknown>;
      expect(Object.keys(targets).sort()).toEqual([
        "dish_category", "native_recipe_identity", "weighed_mass",
      ]);
      const truthIds = l.truth_ingredient_ids as number[];
      expect(truthIds.length).toBeGreaterThanOrEqual(2);
      if (l.stratum === "n5k-plate") {
        // No native labels for N5k plates: recipe identity and category are null.
        expect(targets.native_recipe_identity).toBeNull();
        expect(targets.dish_category).toBeNull();
        const mass = targets.weighed_mass as {
          per_serving_basis: string; amount_tolerance: number; amount_floor_g: number;
          items: { catalog_ingredient_id: number; mass_g: number;
                   n5k_sources: { n5k_ingredient_id: string; n5k_name: string }[] }[];
        };
        expect(mass.amount_tolerance).toBe(0.35);
        expect(mass.amount_floor_g).toBe(10);
        expect(mass.per_serving_basis).toContain("recipe.servings");
        expect(mass.items.length).toBe(truthIds.length); // one truth row per catalog id
        for (const item of mass.items) {
          expect(truthIds).toContain(item.catalog_ingredient_id);
          expect(item.mass_g).toBeGreaterThan(0);
          expect(item.n5k_sources.length).toBeGreaterThan(0);
          for (const src of item.n5k_sources) {
            expect(src.n5k_ingredient_id.startsWith("ingr_")).toBe(true);
          }
        }
        // PR 41 provenance recorded on every N5k label.
        const ref = l.pr41_reference as { plate_cluster: string; official_rgb_split: string; total_mass_g: number };
        expect(typeof ref.plate_cluster).toBe("string");
        // Passthrough from PR 41; plates without RGB captures are "no_rgb_split".
        expect(typeof ref.official_rgb_split).toBe("string");
        expect(ref.official_rgb_split.length).toBeGreaterThan(0);
        expect(ref.total_mass_g).toBeGreaterThan(0);
      } else {
        // Food-101: adjudicable category + mapped recipe identity, no masses.
        expect(targets.weighed_mass).toBeNull();
        expect((targets.native_recipe_identity as { mapped_recipe_id: number }).mapped_recipe_id).toBeGreaterThan(0);
        expect(typeof (targets.dish_category as { food101_class: string }).food101_class).toBe("string");
        const optionalIds = l.optional_ingredient_ids as number[];
        for (const o of optionalIds) expect(truthIds.includes(o)).toBe(false);
      }
    }
  });

  test("truth ingredient ids are valid catalog ingredient ids", () => {
    const catalog = JSON.parse(
      readFileSync(join(import.meta.dir, "../../../../apps/ios/Resources/data.json"), "utf8"),
    ) as { ingredients: Record<string, unknown> };
    const valid = new Set(Object.keys(catalog.ingredients).map((k) => Number(k)));
    for (const l of labels) {
      for (const id of l.truth_ingredient_ids as number[]) {
        expect(valid.has(id)).toBe(true);
      }
    }
  });
});

describe("policy-study-v2 information-collision recomputation", () => {
  test("recomputed evidence-level collision counts match the manifest", () => {
    const groups = new Map<string, string[]>();
    for (const r of requests) {
      const canon = JSON.stringify(detectionsOf(r));
      const bucket = groups.get(canon) ?? [];
      bucket.push(r.case_id as string);
      groups.set(canon, bucket);
    }
    let collisionGroups = 0;
    let collisionCases = 0;
    for (const ids of groups.values()) {
      if (ids.length >= 2) {
        collisionGroups += 1;
        collisionCases += ids.length;
      }
    }
    const col = manifest.information_collisions as { groups: number; cases: number };
    expect(collisionGroups).toBe(col.groups);
    expect(collisionCases).toBe(col.cases);
  });
});

describe("policy-study-v2 dev replay", () => {
  test("200 episodes over dev cases only, sorted, declared reward domain", () => {
    expect(replay.version).toBe("policy-study-dev-v2");
    expect(replay.episodes.length).toBe(200);
    const devIds = new Set(cases.filter((c) => c.slice === "dev").map((c) => c.case_id as string));
    const seen: string[] = [];
    for (const e of replay.episodes) {
      expect(devIds.has(e.case_id)).toBe(true);
      expect(["top_pick", "non_top_pick", "manual_pick"]).toContain(e.action);
      expect([0.96, 0.78, 0.45]).toContain(e.reward);
      seen.push(e.case_id);
    }
    expect([...seen].sort()).toEqual(seen);
    expect(new Set(seen).size).toBe(200);
  });
});
