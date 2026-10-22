/**
 * Band B of the ingredient-facts review (burst14-fridgeluck-facts-review-b).
 *
 * Asserts the review file at canon/ingredient-facts/review/band-b.json covers
 * exactly the facts.json keys from chili-powder to glutinous-rice inclusive
 * (JavaScript default string sort), each once; that every review carries all
 * ten allergen tokens (and all five diet states when the fact has no
 * components) in valid states with reference evidence that names an https
 * URL and a retrieval date; and that each fact either still hashes to its
 * before_sha256 or already equals the review applied — so this test stays
 * green after the apply packet rewrites facts.json.
 *
 * It then applies the band to a TEMPORARY copy of src/lechef (the recheck
 * module, everything it imports, and canon/ingredient-facts/, with the patched
 * facts.json written there) and asserts safety anchors against that copy —
 * never a re-implemented lookup — plus prints the band's ask count per
 * restriction before and after.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync, mkdtempSync, cpSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { allergenViolations } from "../../lechef/allergens.js";

interface Evidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}
interface ReviewState {
  readonly state: string;
  readonly evidence: Evidence;
}
interface Review {
  readonly key: string;
  readonly before_sha256: string;
  readonly allergens: Readonly<Record<string, ReviewState>>;
  readonly diets?: Readonly<Record<string, ReviewState>>;
}
interface ReviewFile {
  readonly schema: string;
  readonly packet: string;
  readonly base_commit: string;
  readonly band: { readonly first: string; readonly last: string; readonly count: number };
  readonly reviews: readonly Review[];
}
interface Fact {
  readonly key: string;
  readonly allergens?: Readonly<Record<string, ReviewState>>;
  readonly diets?: Readonly<Record<string, ReviewState>>;
  readonly components?: readonly unknown[];
  [k: string]: unknown;
}

const canonDir = "../../lechef/canon/ingredient-facts";
const canon = JSON.parse(
  readFileSync(new URL(`${canonDir}/facts.json`, import.meta.url), "utf8")
) as { facts: Readonly<Record<string, Fact>> };
const facts = canon.facts;
const review = JSON.parse(
  readFileSync(new URL(`${canonDir}/review/band-b.json`, import.meta.url), "utf8")
) as ReviewFile;

const ALLERGEN_TOKENS = [
  "milk",
  "egg",
  "fish",
  "crustaceanShellfish",
  "molluscanShellfish",
  "treeNuts",
  "peanuts",
  "wheat",
  "soy",
  "sesame",
] as const;
const DIET_TOKENS = ["vegan", "vegetarian", "pescatarian", "dairyFree", "glutenFree"] as const;
const ALLERGEN_STATES = new Set(["contains", "free", "unknown"]);
const DIET_STATES = new Set(["allowed", "violated", "unknown"]);

/** The band: facts.json keys from first to last inclusive, JavaScript default sort. */
const bandKeys = Object.keys(facts).sort().filter((k) => k >= "chili-powder" && k <= "glutinous-rice");

const sha256 = (s: string): string => createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

/** Deep equality on parsed JSON, insensitive to property insertion order. */
function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  const ka = Object.keys(a as object).sort();
  const kb = Object.keys(b as object).sort();
  if (ka.length !== kb.length || !ka.every((k, i) => k === kb[i])) return false;
  return ka.every((k) => deepEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

/** What the apply packet should produce for `fact` given its review. */
function applied(fact: Fact, rev: Review): Fact {
  const next: Record<string, unknown> = { ...fact, allergens: rev.allergens };
  if (rev.diets) next.diets = { ...(fact.diets ?? {}), ...rev.diets };
  return next as Fact;
}

const hasHttpsAndDate = (e: Evidence): boolean =>
  (e.ref + " " + e.note).includes("https://") && /retrieved \d{4}-\d{2}-\d{2}/.test(e.ref + " " + e.note);

describe("facts review band B (chili-powder..glutinous-rice)", () => {
  test("the review covers exactly the band keys, each once", () => {
    expect(review.schema).toBe("fridgeluck/facts-review/v1");
    expect(review.packet).toBe("burst14-fridgeluck-facts-review-b");
    expect(review.band.count).toBe(bandKeys.length);
    const reviewed = review.reviews.map((r) => r.key).sort();
    expect(reviewed.length).toBe(new Set(reviewed).size); // each once
    expect(reviewed).toEqual(bandKeys); // exactly the band
  });

  test("every review has the ten allergen tokens in valid states with sourced evidence", () => {
    for (const rev of review.reviews) {
      expect(Object.keys(rev.allergens).sort(), rev.key).toEqual([...ALLERGEN_TOKENS].sort());
      for (const [token, st] of Object.entries(rev.allergens)) {
        expect(ALLERGEN_STATES.has(st.state), `${rev.key}.${token}`).toBe(true);
        if (st.evidence.kind === "reference") {
          expect(hasHttpsAndDate(st.evidence), `${rev.key}.${token} reference evidence`).toBe(true);
        }
      }
    }
  });

  test("component-less facts review all five diets in valid states", () => {
    for (const rev of review.reviews) {
      const fact = facts[rev.key];
      const hasComponents = Boolean(fact.components && fact.components.length > 0);
      if (hasComponents) {
        // compounds keep their own diets; any diet listed is a correction — validity only
        for (const [diet, st] of Object.entries(rev.diets ?? {})) {
          expect(DIET_STATES.has(st.state), `${rev.key}.${diet}`).toBe(true);
        }
        continue;
      }
      expect(Object.keys(rev.diets ?? {}).sort(), rev.key).toEqual([...DIET_TOKENS].sort());
      for (const [diet, st] of Object.entries(rev.diets ?? {})) {
        expect(DIET_STATES.has(st.state), `${rev.key}.${diet}`).toBe(true);
      }
    }
  });

  test("each fact still hashes to before_sha256, or already equals the review applied", () => {
    for (const rev of review.reviews) {
      const fact = facts[rev.key];
      const current = JSON.stringify(fact);
      const stillBase = sha256(current) === rev.before_sha256;
      const alreadyApplied = deepEqual(applied(fact, rev), fact);
      expect(stillBase || alreadyApplied, rev.key).toBe(true);
    }
  });
});

describe("band B applied to a temporary canon copy", () => {
  // The recheck runs against a patched copy of the real module tree, so the
  // lookup under test is the production allergens.ts, never a re-implementation.
  let patched: typeof import("../../lechef/allergens.js");

  const ask = (mod: typeof patched, key: string, restriction: string): boolean =>
    mod
      .allergenViolations(key, [{ name: "probe", restrictions: [restriction] }])
      .some((v) => v.includes("confirmation required"));

  const countAsks = (mod: typeof patched): Record<string, number> => {
    const restrictions = ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"];
    const counts: Record<string, number> = {};
    for (const r of restrictions) counts[r] = 0;
    for (const key of bandKeys) {
      for (const r of restrictions) if (ask(mod, key, r)) counts[r] += 1;
    }
    return counts;
  };

  test("set up the patched temporary copy", async () => {
    const tmp = mkdtempSync(path.join(tmpdir(), "fridgeluck-band-b-"));
    cpSync(fileURLToPath(new URL("../../lechef", import.meta.url)), path.join(tmp, "lechef"), { recursive: true });
    // apply the band into the copied facts.json
    const next = JSON.parse(JSON.stringify(canon)) as { facts: Record<string, Fact> };
    for (const rev of review.reviews) {
      next.facts[rev.key] = applied(next.facts[rev.key], rev);
    }
    writeFileSync(
      path.join(tmp, "lechef", "canon", "ingredient-facts", "facts.json"),
      JSON.stringify(next, null, 2)
    );
    patched = (await import(pathToFileURL(path.join(tmp, "lechef", "allergens.ts")).href)) as typeof patched;
  });

  test("a reviewed contains state still flags a hard violation", () => {
    // crab is a crustacean; couscous is durum wheat; cod is finfish;
    // chocolate's variable milk component still resolves to a hard carry
    for (const [key, restriction] of [
      ["crab", "shellfish"],
      ["couscous", "wheat"],
      ["cod", "fish"],
      ["chocolate", "milk"],
    ] as const) {
      const violations = patched.allergenViolations(key, [{ name: "probe", restrictions: [restriction] }]);
      expect(violations.length, `${key} × ${restriction}`).toBe(1);
      expect(violations[0]).toMatch(/carries/);
      expect(violations[0]).not.toMatch(/confirmation required/);
    }
  });

  test("a reviewed free state clears without asking", () => {
    for (const key of ["garlic", "cucumber", "cumin", "dill", "daikon", "ginger", "cranberries"]) {
      for (const restriction of ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"]) {
        const violations = patched.allergenViolations(key, [{ name: "probe", restrictions: [restriction] }]);
        expect(violations, `${key} × ${restriction}`).toEqual([]);
      }
    }
  });

  test("a reviewed unknown state still asks", () => {
    // chocolate: tree nuts, peanuts, wheat, soy and sesame are unknown
    for (const restriction of ["treeNuts", "peanuts", "wheat", "soy", "sesame"]) {
      expect(ask(patched, "chocolate", restriction), `chocolate × ${restriction}`).toBe(true);
    }
    // dashi: formulation-variable wheat and soy
    expect(ask(patched, "dashi", "wheat"), "dashi × wheat").toBe(true);
    expect(ask(patched, "dashi", "soy"), "dashi × soy").toBe(true);
    // flatbread: category-level unknowns
    expect(ask(patched, "flatbread", "sesame"), "flatbread × sesame").toBe(true);
  });

  test("formulation-variable placeholder facts keep asking", () => {
    for (const key of ["fat-source-varies", "flavourings-unknown"]) {
      for (const restriction of ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"]) {
        expect(ask(patched, key, restriction), `${key} × ${restriction}`).toBe(true);
      }
    }
  });

  test("coconut facts no longer ask tree-nut-free eaters", () => {
    for (const key of ["coconut", "coconut-oil"]) {
      expect(ask(patched, key, "treeNuts"), `${key} × treeNuts`).toBe(false);
    }
  });

  test("band ask count per restriction, before and after", () => {
    const before = countAsks({ allergenViolations } as typeof patched);
    const after = countAsks(patched);
    const lines = ["restriction, before, after"];
    for (const r of Object.keys(after)) lines.push(`${r}, ${before[r]}, ${after[r]}`);
    const total = (c: Record<string, number>) => Object.values(c).reduce((a, b) => a + b, 0);
    lines.push(`total, ${total(before)}, ${total(after)}`);
    console.log(`band B asks (82 facts × 9 restrictions):\n${lines.join("\n")}`);
    expect(Object.keys(after).length).toBe(9);
  });
});
