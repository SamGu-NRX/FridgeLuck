/**
 * Review-packet test for the band-c ingredient-facts review
 * (src/lechef/canon/ingredient-facts/review/band-c.json).
 *
 * Asserts the review file is well-formed and pinned to the band's keys, that
 * every reviewed fact either still matches its recorded before_sha256 or is
 * EXACTLY the packet's pinned applied state (after_sha256) — so a fact that
 * drifted after the review in fields the review does not overwrite (components,
 * compositionComplete, notes) is rejected as stale even when the reviewed
 * allergen/diet fields still match — and — by applying the band to a temporary
 * copy of the real lookup (allergens.ts, its imports, and the canon) — that
 * anchors hold, every reviewed verdict shows in the live lookup, and the
 * band's per-restriction confirmation-ask counts match the pinned literals.
 */

import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const agentRoot = resolve(here, "../../..");
const canonDir = join(agentRoot, "src/lechef/canon/ingredient-facts");
const factsPath = join(canonDir, "facts.json");
const reviewPath = join(canonDir, "review/band-c.json");

const canon = JSON.parse(readFileSync(factsPath, "utf8")) as {
  facts: Record<string, Record<string, unknown>>;
};
const review = JSON.parse(readFileSync(reviewPath, "utf8")) as {
  schema: string;
  packet: string;
  base_commit: string;
  band: { first: string; last: string; count: number };
  reviews: ReviewEntry[];
};

interface Evidence {
  kind: string;
  ref: string;
  note: string;
}
interface ReviewEntry {
  key: string;
  before_sha256: string;
  /** sha256 of the fact with this review applied — the applied state the packet pins. */
  after_sha256?: string;
  allergens: Record<string, { state: string; evidence: Evidence }>;
  diets?: Record<string, { state: string; evidence: Evidence }>;
  changes?: { path: string; from: string; to: string; reason: string; evidence: string }[];
}

const TOKENS = ["milk", "egg", "fish", "crustaceanShellfish", "molluscanShellfish", "treeNuts", "peanuts", "wheat", "soy", "sesame"];
const DIETS = ["vegan", "vegetarian", "pescatarian", "dairyFree", "glutenFree"];
const RESTRICTIONS = ["milk", "wheat", "egg", "peanuts", "treeNuts", "soy", "fish", "shellfish", "sesame"];

/** The band rule: facts.json keys from gnocchi to mustard inclusive, default string sort. */
const bandKeys = Object.keys(canon.facts).sort().filter((k) => k >= "gnocchi" && k <= "mustard");

const sha256 = (fact: unknown): string =>
  createHash("sha256").update(JSON.stringify(fact), "utf8").digest("hex");

/** Apply a review entry the way burst14-fridgeluck-facts-apply does: replace allergens, overwrite listed diets. */
function applyReview(fact: Record<string, unknown>, entry: ReviewEntry): Record<string, unknown> {
  // The apply contract shared with bands A/B/E (run/apply-facts-review.ts): the
  // reviewed allergens replace the fact's block, reviewed diets merge over the
  // fact's own. A fact with no diets of its own and no reviewed diets gains
  // nothing — the canon does not materialize empty diets blocks.
  const next: Record<string, unknown> = { ...fact, allergens: entry.allergens };
  if (entry.diets) next.diets = { ...((fact.diets as object) ?? {}), ...entry.diets };
  return next;
}

function expectSourced(evidence: Evidence): void {
  expect(["standard", "reference"]).toContain(evidence.kind);
  expect(evidence.ref.length).toBeGreaterThan(0);
  expect(evidence.note.length).toBeGreaterThan(0);
  if (evidence.kind === "reference") {
    expect(evidence.ref).toMatch(/https:\/\/\S+/);
    expect(`${evidence.ref} ${evidence.note}`).toMatch(/retrieved \d{4}-\d{2}-\d{2}/);
  }
}

/** The app restriction each reviewed allergen token screens for. */
const TOKEN_TO_RESTRICTION: Record<string, string> = {
  milk: "milk",
  egg: "egg",
  fish: "fish",
  crustaceanShellfish: "shellfish",
  molluscanShellfish: "shellfish",
  treeNuts: "treeNuts",
  peanuts: "peanuts",
  wheat: "wheat",
  soy: "soy",
  sesame: "sesame",
};

interface AllergensModule {
  allergenViolations: (ingredient: string, eaters: readonly { name?: string; restrictions: readonly string[] }[]) => readonly string[];
}

/** Copy the real lookup — allergens.ts, every module it imports, and the canon — into a temp tree. */
async function makeTempLookup(patchedFacts: object): Promise<AllergensModule> {
  const tmp = mkdtempSync(join(tmpdir(), "fridgeluck-band-c-"));
  const lechef = join(tmp, "src/lechef");
  mkdirSync(join(lechef, "canon"), { recursive: true });
  cpSync(join(agentRoot, "src/lechef/allergens.ts"), join(lechef, "allergens.ts"));
  const typesTs = join(agentRoot, "src/lechef/types.ts");
  if (existsSync(typesTs)) cpSync(typesTs, join(lechef, "types.ts"));
  cpSync(canonDir, join(lechef, "canon/ingredient-facts"), { recursive: true });
  if (patchedFacts) {
    writeFileSync(join(lechef, "canon/ingredient-facts/facts.json"), JSON.stringify(patchedFacts));
  }
  const mod = (await import(join(lechef, "allergens.ts"))) as unknown as AllergensModule;
  return mod;
}

const eater = (restrictions: string[]) => [{ name: "cook", restrictions }];
const asks = (mod: AllergensModule, keys: readonly string[]): Record<string, number> => {
  const per: Record<string, number> = {};
  let total = 0;
  for (const restriction of RESTRICTIONS) {
    per[restriction] = keys.filter((key) =>
      mod.allergenViolations(key, eater([restriction])).some((m) => m.includes("confirmation required"))
    ).length;
    total += per[restriction];
  }
  per.total = total;
  return per;
};

/**
 * The pinned post-review confirmation-ask counts, per restriction, for the
 * band's facts on the APPLIED canon (the live one). Regenerate from the
 * console.log lines of the applied-band test when a deliberate verdict change
 * lands, and say so in the packet or PR that changes them.
 */
const EXPECTED_ASKS: Record<string, number> = {
  milk: 11,
  wheat: 10,
  egg: 10,
  peanuts: 11,
  treeNuts: 12,
  soy: 10,
  fish: 11,
  shellfish: 11,
  sesame: 10,
  total: 96,
};

describe("facts review band c (gnocchi..mustard)", () => {
  test("review header is pinned to this packet and band", () => {
    expect(review.schema).toBe("fridgeluck/facts-review/v1");
    expect(review.packet).toBe("burst14-fridgeluck-facts-review-c");
    expect(review.band.first).toBe("gnocchi");
    expect(review.band.last).toBe("mustard");
    expect(review.band.count).toBe(bandKeys.length);
  });

  test("reviewed keys are exactly the band's keys, each once", () => {
    const seen = new Set<string>();
    for (const entry of review.reviews) {
      expect(seen.has(entry.key)).toBe(false);
      seen.add(entry.key);
    }
    expect([...seen].sort()).toEqual(bandKeys);
  });

  test("every review has all ten allergen states in vocabulary, sourced; singles have all five diets", () => {
    for (const entry of review.reviews) {
      for (const token of TOKENS) {
        const state = entry.allergens[token];
        expect(state).toBeDefined();
        expect(["contains", "free", "unknown"]).toContain(state.state);
        expectSourced(state.evidence);
      }
      const fact = canon.facts[entry.key];
      if (!fact.components) {
        for (const diet of DIETS) {
          const state = entry.diets?.[diet];
          expect(state).toBeDefined();
          expect(["allowed", "violated", "unknown"]).toContain(state!.state);
          expectSourced(state!.evidence);
        }
      }
      // Every change record names its path, the state it moved from, and the
      // state it moved to — and the recorded target is the state this review
      // actually carries for that path, so the packet's own change list can
      // never point somewhere the review does not go.
      for (const change of entry.changes ?? []) {
        const [block, token] = change.path.split(".");
        expect(["allergens", "diets"]).toContain(block);
        const reviewed =
          block === "allergens"
            ? entry.allergens[token]?.state
            : entry.diets?.[token]?.state;
        expect(reviewed).toBeDefined();
        expect(change.from).toBeDefined();
        expect(change.to).toBe(reviewed);
        expect(change.reason.length).toBeGreaterThan(0);
        expect(change.evidence.length).toBeGreaterThan(0);
      }
    }
  });

  test("each fact either still hashes to before_sha256 or is exactly the review's pinned applied state", () => {
    for (const entry of review.reviews) {
      const fact = canon.facts[entry.key];
      expect(fact).toBeDefined();
      // The packet pins the state its application produces. Accepting any fact
      // whose reviewed fields match would let a fact that drifted AFTER the
      // review (components, compositionComplete, notes) pose as already
      // applied — a stale fact surviving with old verdicts — so the applied
      // branch requires the whole fact to hash to the pinned applied state.
      expect(entry.after_sha256).toBeDefined();
      const hash = sha256(fact);
      if (hash === entry.before_sha256) {
        // not yet applied: applying the review must produce exactly the pinned state
        expect(sha256(applyReview(fact, entry))).toBe(entry.after_sha256);
        continue;
      }
      expect(hash).toBe(entry.after_sha256);
    }
  });

  test("every reviewed verdict shows in the live lookup", async () => {
    const live = (await import(join(agentRoot, "src/lechef/allergens.ts"))) as unknown as AllergensModule;
    for (const entry of review.reviews) {
      const fact = canon.facts[entry.key];
      const single = !fact.components;
      for (const token of TOKENS) {
        const state = entry.allergens[token].state;
        const restriction = TOKEN_TO_RESTRICTION[token];
        const lines = live.allergenViolations(entry.key, eater([restriction]));
        if (state === "contains") {
          // a reviewed contains always carries, never merely asks
          expect(lines.some((m) => m.includes("carries"))).toBe(true);
        } else if (state === "unknown") {
          // a reviewed unknown never clears: it asks or carries through composition
          expect(lines.length).toBeGreaterThan(0);
        } else if (single) {
          // a reviewed free on a component-less fact clears its restriction
          // outright — except the shellfish pair, which one restriction
          // screens together (the other half may still be unresolved)
          const shellfishHalf = token === "crustaceanShellfish" || token === "molluscanShellfish";
          const otherHalfFree = entry.allergens.crustaceanShellfish.state === "free" && entry.allergens.molluscanShellfish.state === "free";
          if (!shellfishHalf || otherHalfFree) {
            expect(lines).toEqual([]);
          }
        }
      }
    }
  });

  test("applied band: anchors hold and confirmation asks match the pinned per-restriction counts", async () => {
    const before = (await import(join(agentRoot, "src/lechef/allergens.ts"))) as unknown as AllergensModule;
    const patched = { ...canon, facts: { ...canon.facts } };
    for (const entry of review.reviews) {
      patched.facts[entry.key] = applyReview(patched.facts[entry.key], entry);
    }
    const after = await makeTempLookup(patched);

    // contains: a mollusc fact hard-violates the app's shellfish restriction.
    expect(after.allergenViolations("mussel", eater(["shellfish"])).some((m) => m.includes("carries"))).toBe(true);
    // contains through composition: gnocchi's wheat still flows from its wheat-flour component
    // even though the compound's own state is now unknown.
    expect(after.allergenViolations("gnocchi", eater(["wheat"])).some((m) => m.includes("carries"))).toBe(true);
    // free: grapes asked about shellfish on the pre-apply canon (no
    // molluscanShellfish state); the applied canon clears it — reviewed free
    // with reference evidence — in the live lookup and in the staged band copy.
    expect(before.allergenViolations("grapes", eater(["shellfish"]))).toEqual([]);
    expect(after.allergenViolations("grapes", eater(["shellfish"]))).toEqual([]);
    // unknown: the hydrolysed-plant-protein source plant varies by brand, so it still asks.
    expect(
      after.allergenViolations("hydrolysed-plant-protein", eater(["soy"])).some((m) => m.includes("confirmation required"))
    ).toBe(true);

    const beforeCounts = asks(before, bandKeys);
    const afterCounts = asks(after, bandKeys);
    console.log("[facts-review band c] asks before:", JSON.stringify(beforeCounts));
    console.log("[facts-review band c] asks after:", JSON.stringify(afterCounts));
    // On the applied canon the band is already inside `before` (the live
    // lookup), so re-applying it in `after` cannot move any verdict: both
    // sides must equal the pinned per-restriction counts exactly. An
    // accidental contains→free change in any unanchored fact would shift its
    // restriction's count and fail here, instead of hiding behind the old
    // aggregate never-increases check.
    expect(afterCounts).toEqual(EXPECTED_ASKS);
    expect(beforeCounts).toEqual(EXPECTED_ASKS);
  });
});
