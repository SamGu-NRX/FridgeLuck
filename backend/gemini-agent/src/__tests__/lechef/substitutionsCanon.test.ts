/**
 * Canon-table sync tests: the LeChef canon copy must stay byte-identical to
 * the repository's reviewed table data/substitutions/pairs.json, and the
 * reviewed conditional failures must refuse matching eaters with the
 * recorded reason (never offered, never reduced to note text).
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createSubstitutionTool, substitutionsCanonLoader } from "../../lechef/substitutions.js";

const REPO_ROOT = resolve(import.meta.dir, "../../../../..");
const REVIEWED = resolve(REPO_ROOT, "data/substitutions/pairs.json");
const CANON = resolve(import.meta.dir, "../../lechef/canon/substitutions/pairs.json");

const reviewedBytes = () => readFileSync(REVIEWED);
const canonBytes = () => readFileSync(CANON);

describe("LeChef canon copy sync", () => {
  test("canon copy is byte-identical to data/substitutions/pairs.json", () => {
    expect(canonBytes().equals(reviewedBytes())).toBe(true);
  });

  test("canon copy parses as the reviewed schema with all pairs present", () => {
    const canon = JSON.parse(canonBytes().toString("utf8")) as { schema_version: string; pairs: unknown[] };
    const reviewed = JSON.parse(reviewedBytes().toString("utf8")) as { schema_version: string; pairs: unknown[] };
    expect(canon.schema_version).toBe(reviewed.schema_version);
    expect(canon.pairs.length).toBe(reviewed.pairs.length);
    expect(canon.schema_version).toBe("1.1.0");
  });

  test("the default loader reports the reviewed source and pair count", () => {
    const table = substitutionsCanonLoader();
    expect(table).not.toBeNull();
    expect(table!.source).toContain("data/substitutions/pairs.json");
    expect(table!.rows.length).toBe(286);
  });
});

describe("reviewed conditional refusals", () => {
  const tool = createSubstitutionTool();

  test("five reviewed pairs carry conditional restrictions", () => {
    const rows = substitutionsCanonLoader()!.rows.filter((r) => (r.conditionalFor?.length ?? 0) > 0);
    expect(rows.length).toBe(5);
  });

  test("almonds -> walnuts is refused for a tree-nut-free eater with the recorded reason", () => {
    const result = tool.lookupSubstitution({
      ingredient: "almonds",
      eaters: [{ restrictions: ["tree-nut-free"] }]
    });
    expect(result.swaps.length).toBe(0);
    const refusal = result.violations.find((v) => v.includes("almonds") && v.includes("walnuts") && v.includes("refused for tree-nut-free"));
    expect(refusal).toBeDefined();
    expect(refusal).toContain("every nut swap is refused");
    // the conditional reason never leaks into an offered note
    expect(result.swaps.every((s) => !(s.note ?? "").includes("every nut swap is refused"))).toBe(true);
  });

  test("the same row is offered when no eater holds the restriction", () => {
    const result = tool.lookupSubstitution({ ingredient: "almonds", eaters: [] });
    expect(result.swaps.some((s) => s.from === "almonds" && s.to === "walnuts")).toBe(true);
  });

  test("restriction matching folds identity (case, hyphen, underscore)", () => {
    const result = tool.lookupSubstitution({
      ingredient: "almonds",
      eaters: [{ restrictions: ["Tree_Nut-Free"] }]
    });
    expect(result.swaps.length).toBe(0);
    expect(result.violations.some((v) => v.includes("refused"))).toBe(true);
  });
});
