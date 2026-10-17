/**
 * Measures confirmation asks over the canon's (ingredient, allergen)
 * restrictions, before and after the five fact-review bands were applied.
 *
 * The apply script (apply-facts-review.ts) stays mechanical and thin; this is
 * where the packet report's numbers come from. An ingredient ASKS for
 * confirmation on an allergen when its own state for that allergen token is
 * missing or reviewed unknown — a reviewed `free` clears silently and a
 * reviewed `contains` is a hard violation, not a question. Own-state counting:
 * composition flows are the resolver's business (allergens.ts), which is what
 * makes the compound-ingredients measure a separate row — after the apply, the
 * canon's remaining asks sit almost entirely on compound facts' own states.
 *
 * The canon's allergen tokens are the ten the review format pins (shellfish is
 * split into crustaceanShellfish and molluscanShellfish; mustard has no canon
 * token and is pinned to ask-zero by allergens.ts ASKS_BY_DESIGN, so it is not
 * a measured restriction here).
 *
 * The "before" canon is the pre-apply snapshot committed beside this report
 * (evaluation/lechef-facts/before-facts.json, extracted from the apply
 * commit's parent); the "after" canon is the live facts.json. Collision and
 * refusal counts are recomputed by dry-running the apply script against the
 * before snapshot — the record of what the real apply run faced.
 *
 * Usage: bun run src/run/confirmation-rate.ts
 */

import { readFileSync } from "node:fs";
import { applyFactsReview, defaultPaths } from "./apply-facts-review.js";

/** The canon's ten allergen tokens — the review format's measured set. */
const ALLERGEN_TOKENS: readonly string[] = [
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
];

interface Fact {
  readonly allergens?: Readonly<Record<string, { readonly state?: string }>>;
  readonly components?: readonly unknown[];
}

interface Canon {
  readonly facts: Readonly<Record<string, Fact>>;
}

const beforePath = new URL("../../../../evaluation/lechef-facts/before-facts.json", import.meta.url).pathname;
const afterPath = defaultPaths().factsPath;
const reviewDir = defaultPaths().reviewDir;

function askCount(canon: Canon, compoundOnly = false): { asks: number; facts: number } {
  const keys = Object.keys(canon.facts).filter((k) => {
    if (!compoundOnly) return true;
    const fact = canon.facts[k];
    return Array.isArray(fact.components) && fact.components.length > 0;
  });
  let asks = 0;
  for (const key of keys) {
    const fact = canon.facts[key];
    for (const token of ALLERGEN_TOKENS) {
      const entry = fact.allergens?.[token];
      if (!entry || entry.state === "unknown") asks += 1;
    }
  }
  return { asks, facts: keys.length };
}

function canonFrom(path: string): Canon {
  return JSON.parse(readFileSync(path, "utf8")) as Canon;
}

const before = canonFrom(beforePath);
const after = canonFrom(afterPath);

const rows: { label: string; before: string; after: string }[] = [];

const pct = (asks: number, facts: number) => `${((asks / (facts * ALLERGEN_TOKENS.length)) * 100).toFixed(1)}%`;

const tBefore = askCount(before);
const tAfter = askCount(after);
const cBefore = askCount(before, true);
const cAfter = askCount(after, true);

rows.push({
  label: "confirmation asks, all (ingredient, allergen) restrictions",
  before: `${tBefore.asks} of ${tBefore.facts * ALLERGEN_TOKENS.length} (${pct(tBefore.asks, tBefore.facts)})`,
  after: `${tAfter.asks} of ${tAfter.facts * ALLERGEN_TOKENS.length} (${pct(tAfter.asks, tAfter.facts)})`,
});
rows.push({
  label: "confirmation asks, compound ingredients' own states",
  before: `${cBefore.asks} of ${cBefore.facts * ALLERGEN_TOKENS.length} (${pct(cBefore.asks, cBefore.facts)})`,
  after: `${cAfter.asks} of ${cAfter.facts * ALLERGEN_TOKENS.length} (${pct(cAfter.asks, cAfter.facts)})`,
});

// Collisions and refusals, recomputed as a dry run of the apply script against
// the before snapshot: the record of what the real apply run faced.
const dryRun = applyFactsReview({ factsPath: beforePath, reviewDir }, false);
const collisions = dryRun.refused.filter((r) => r.reason.startsWith("key reviewed in two files")).length;
const fileRefusals = dryRun.refused.filter((r) => r.key === null).length;
const hashRefusals = dryRun.refused.filter((r) => r.reason.startsWith("before_sha256 mismatch")).length;
const otherRefusals = dryRun.refused.length - collisions - fileRefusals - hashRefusals;

rows.push({
  label: "key-in-two-files collisions / refused band files / refused reviews",
  before: `${collisions} / ${fileRefusals} / ${hashRefusals + otherRefusals} across ${dryRun.files.length} band files`,
  after: `${collisions} / ${fileRefusals} / ${hashRefusals + otherRefusals} (refusals are apply-run facts, not before/after)`,
});

const width = Math.max(...rows.map((r) => r.label.length));
console.log("confirmation-rate: canon own-state confirmation asks, before -> after the five fact-review bands");
console.log("");
for (const row of rows) console.log(`  ${row.label.padEnd(width)}  before: ${row.before}  after: ${row.after}`);
console.log("");
console.log(
  `  apply dry run on the before snapshot: applied ${dryRun.applied.length}, unchanged ${dryRun.unchanged.length}, refused ${dryRun.refused.length} (nothing written)`
);
console.log(`  before snapshot: ${beforePath}`);
console.log(`  after canon:     ${afterPath}`);
