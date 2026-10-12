/**
 * Food safety — doneness as a checkable thermometer test (SPEC 3.1).
 *
 * BINDING: doneness for meat, poultry, fish, eggs and leftovers is stated as
 * a checkable test with a thermometer temperature from a reviewed source —
 * the USDA FSIS Safe Minimum Internal Temperature chart — with the source
 * NAMED on every answer. Uncovered products return an explicit unknown:
 * never a colour, never a time, never a guess.
 *
 * The reviewed source is the PINNED food-safety canon at ./canon/food-safety/
 * (verbatim from overhaul/food-safety-canon; see canon/PROVENANCE.md). There
 * is no embedded table here to drift from the canon. The rulebook is built
 * from the canon's explicit product classes; when several classes apply to a
 * question ("salmon casserole", a reheat question about a pork roast), the
 * STRICTEST applicable temperature wins — FSIS requires 165 °F for casseroles
 * and reheating regardless of the species minimum, so a lower species
 * minimum never undercuts them. Guidance is advisory and sourced; shelf-life
 * never certifies safety.
 *
 * Fail closed: if the pinned canon is missing, malformed, or fails
 * validation (it no longer covers the required classes and minimums), the
 * tool answers unknown for every product rather than guessing from a
 * partial table. A rulebook loaded through loadFoodSafetyRulebook /
 * setRulebook (the corpus task's data/food-safety drop-in) still supersedes
 * the canon.
 */

import { readFileSync } from "node:fs";
import type { FoodSafetyAnswer, SourcedCheck } from "./types.js";
import { celsius } from "./types.js";

/** A reviewed food-safety rulebook: named source + thermometer entries. */
export interface FoodSafetyRulebook {
  readonly source: string;
  readonly entries: readonly {
    readonly category: string;
    readonly keywords: readonly string[];
    readonly temperatureC: number;
    readonly temperatureF: number;
    readonly restMinutes?: number;
    readonly test: string;
  }[];
}

/** The pinned food-safety canon file, read once per load. */
function readCanonRulesJson(): string {
  return readFileSync(new URL("./canon/food-safety/rules.json", import.meta.url), "utf8");
}

interface CanonCheck {
  readonly kind: string;
  readonly temp_f: number;
  readonly temp_c: number;
  readonly rest_minutes?: number;
  readonly placement?: string;
  readonly alternative_temp_f?: number;
}

interface CanonRule {
  readonly id: string;
  readonly topic: string;
  readonly food_class?: string;
  readonly summary?: string;
  readonly check?: CanonCheck;
  readonly match_keywords?: readonly string[];
  readonly citation_ids?: readonly string[];
}

interface CanonCitation {
  readonly id: string;
  readonly org?: string;
  readonly title?: string;
  readonly url?: string;
  readonly retrieved?: string;
}

interface CanonRulebookRaw {
  readonly schema_version?: number;
  readonly citations?: readonly CanonCitation[];
  readonly rules?: readonly CanonRule[];
}

export interface CanonRulebookBuild {
  readonly ok: true;
  readonly rulebook: FoodSafetyRulebook;
}

export interface CanonRulebookRejection {
  readonly ok: false;
  readonly errors: readonly string[];
}

/** FSIS chart citation the temperature classes must reference (SPEC 3.1 source). */
const FSIS_CITATION_ID = "fsis-safe-temperature-chart";

function citationSource(citation: CanonCitation): string {
  let host = "fsis.usda.gov";
  if (citation.url) {
    try {
      host = new URL(citation.url).host;
    } catch {
      // keep the default host when the URL does not parse
    }
  }
  // The canon names the organisation ("USDA Food Safety and Inspection Service
  // (FSIS)") separately from the chart title; the named-source surface uses
  // the org's short form ("USDA FSIS") + title, as every consumer matches on.
  const org = citation.org ?? "USDA Food Safety and Inspection Service (FSIS)";
  const short = org.includes("(") ? `${org.split(" ")[0]} ${org.slice(org.indexOf("(") + 1, org.indexOf(")"))}` : org;
  return `${short} ${citation.title ?? "Safe Minimum Internal Temperature Chart"} (${host}), retrieved ${citation.retrieved ?? "unspecified"} — pinned food-safety canon`;
}

/**
 * Build the tool's rulebook from the pinned canon JSON. Validates the canon's
 * structure AND its coverage of the product classes this layer must never
 * misstate (SPEC 3.1): ground poultry at 165, ground meat at 160, casseroles
 * at 165, reheating at 165, whole cuts at 145 with a 3-minute rest, fish at
 * 145, eggs at 160. Any structural or coverage failure rejects the canon —
 * the tool then fails closed instead of answering from a partial table.
 */
export function buildCanonRulebook(raw: unknown): CanonRulebookBuild | CanonRulebookRejection {
  const errors: string[] = [];
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return { ok: false, errors: ["canon rules.json: expected an object"] };
  }
  const canon = raw as CanonRulebookRaw;
  if (canon.schema_version !== 1) errors.push(`schema_version ${JSON.stringify(canon.schema_version)} !== 1`);
  const citations = canon.citations ?? [];
  const citation = citations.find((c) => c.id === FSIS_CITATION_ID);
  if (!citation) errors.push(`citations: missing "${FSIS_CITATION_ID}"`);
  const rules = canon.rules ?? [];
  if (!rules.length) errors.push("rules: empty");

  const citationIds = new Set(citations.map((c) => c.id));
  const thermo = rules.filter((r) => r.check?.kind === "thermometer" && r.match_keywords?.length);
  if (!thermo.length) errors.push("no thermometer rules with match keywords");

  for (const rule of thermo) {
    const check = rule.check as CanonCheck;
    const id = rule.id ?? "(no id)";
    if (typeof check.temp_f !== "number" || check.temp_f <= 0) errors.push(`${id}: bad temp_f`);
    if (typeof check.temp_c !== "number" || check.temp_c <= 0) errors.push(`${id}: bad temp_c`);
    else if (Math.round((check.temp_f - 32) / 1.8) !== check.temp_c) {
      errors.push(`${id}: temp_c ${check.temp_c} disagrees with temp_f ${check.temp_f}`);
    }
    if (!rule.id) errors.push("thermometer rule without id");
    if (rule.topic !== "doneness" && rule.topic !== "reheating") {
      errors.push(`${id}: thermometer rule topic "${rule.topic}" is not doneness/reheating`);
    }
    if (typeof rule.summary !== "string" || rule.summary.length === 0) errors.push(`${id}: missing summary`);
    if (typeof check.placement !== "string" || check.placement.length === 0) errors.push(`${id}: missing placement`);
    for (const cid of rule.citation_ids ?? []) {
      if (!citationIds.has(cid)) errors.push(`${id}: unknown citation "${cid}"`);
    }
  }

  // Spec-floor coverage: the classes the review and SPEC 3.1 pin down.
  const hasRule = (pred: (r: CanonRule) => boolean, what: string): void => {
    if (!thermo.some(pred)) errors.push(`coverage: no reviewed thermometer rule for ${what}`);
  };
  hasRule(
    (r) => r.food_class === "meat_poultry" && (r.match_keywords ?? []).includes("ground poultry") && (r.check?.temp_f ?? 0) >= 165,
    "ground poultry at 165 F (ground chicken/turkey are POULTRY, not 160 F ground meat)"
  );
  hasRule(
    (r) => (r.match_keywords ?? []).some((k) => k === "ground beef") && (r.check?.temp_f ?? 0) >= 160,
    "ground beef at 160 F"
  );
  hasRule(
    (r) => (r.match_keywords ?? []).some((k) => k === "ground veal") && (r.check?.temp_f ?? 0) >= 160,
    "ground veal at 160 F (ground meat, not the 145 F whole-cut minimum)"
  );
  hasRule(
    (r) => (r.match_keywords ?? []).some((k) => k === "casserole") && (r.check?.temp_f ?? 0) >= 165,
    "casseroles at 165 F (strictest class wins over species minimums)"
  );
  hasRule(
    (r) => r.topic === "reheating" && (r.check?.temp_f ?? 0) >= 165 && (r.match_keywords ?? []).some((k) => k.startsWith("reheat")),
    "reheating at 165 F"
  );
  hasRule(
    (r) => (r.match_keywords ?? []).some((k) => k === "salmon") && (r.check?.temp_f ?? 0) >= 145,
    "fish at 145 F"
  );
  hasRule(
    (r) => r.food_class === "egg" && (r.check?.temp_f ?? 0) >= 160,
    "eggs at 160 F"
  );
  hasRule(
    (r) => (r.match_keywords ?? []).some((k) => k === "steak") && (r.check?.rest_minutes ?? 0) >= 3,
    "whole cuts at 145 F with a 3-minute rest"
  );

  if (errors.length || !citation) return { ok: false, errors };

  const source = citationSource(citation);
  const entries = thermo.map((rule) => {
    const check = rule.check as CanonCheck;
    const firstSentence = (rule.summary ?? "").split(/(?<=\.)\s/)[0] ?? rule.summary ?? "";
    const test = `${firstSentence} Check it with a food thermometer in ${check.placement}.`;
    return {
      category: rule.food_class ?? rule.topic,
      keywords: [...(rule.match_keywords ?? [])],
      temperatureC: check.temp_c,
      temperatureF: check.temp_f,
      ...(check.rest_minutes !== undefined && check.rest_minutes > 0 ? { restMinutes: check.rest_minutes } : {}),
      test
    };
  });
  return { ok: true, rulebook: { source, entries } };
}

/** The canon rulebook, or null when the pinned canon fails validation (fail closed). */
function canonRulebookOrNull(): FoodSafetyRulebook | null {
  let raw: unknown;
  try {
    raw = JSON.parse(readCanonRulesJson());
  } catch {
    return null;
  }
  const built = buildCanonRulebook(raw);
  return built.ok ? built.rulebook : null;
}

export const FSIS_SOURCE =
  canonRulebookOrNull()?.source ??
  "USDA FSIS Safe Minimum Internal Temperature Chart (fsis.usda.gov) — pinned food-safety canon (VALIDATION FAILED)";

function normalize(text: string): string {
  return text.trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function keywordRegExp(keyword: string): RegExp | null {
  const kw = normalize(keyword);
  if (!kw) return null;
  return new RegExp(`\\b${kw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`);
}

interface MatchEntry {
  readonly category: string;
  readonly keywords: readonly string[];
  readonly temperatureC: number;
  readonly temperatureF: number;
  readonly restMinutes?: number;
  readonly test: string;
}

/**
 * Strictest-wins matching: collect EVERY entry whose keyword matches the
 * product or question text (word-boundary, so "hen" never matches "when"),
 * then answer with the highest applicable temperature — reheating or a
 * casserole class always outruns a lower species minimum. Ties prefer the
 * reheating/leftovers class, then the earlier entry.
 */
function matchStrictest(
  product: string,
  question: string,
  rulebook: FoodSafetyRulebook
): { entry: MatchEntry; matched: string } | null {
  const haystack = normalize(`${product} ${question}`);
  if (!haystack) return null;
  const ordered = rulebook.entries.map((entry, index) => ({ entry, index }));
  const hits: { entry: MatchEntry; matched: string; index: number }[] = [];
  for (const { entry, index } of ordered) {
    for (const keyword of entry.keywords) {
      const re = keywordRegExp(keyword);
      if (re && re.test(haystack)) {
        hits.push({ entry, matched: keyword, index });
        break;
      }
    }
  }
  if (!hits.length) return null;
  hits.sort((a, b) => {
    if (b.entry.temperatureF !== a.entry.temperatureF) return b.entry.temperatureF - a.entry.temperatureF;
    const aLeft = a.entry.category === "leftovers" ? 0 : 1;
    const bLeft = b.entry.category === "leftovers" ? 0 : 1;
    if (aLeft !== bLeft) return aLeft - bLeft;
    return a.index - b.index;
  });
  return { entry: hits[0].entry, matched: hits[0].matched };
}

// ---------------------------------------------------------------------------
// Tool
// ---------------------------------------------------------------------------

export interface FoodSafetyTool {
  /** Doneness question → sourced check or explicit unknown. */
  checkFoodSafety(input: { product: string; question?: string }): {
    answer: FoodSafetyAnswer;
    unknowns: readonly string[];
    sourceName: string | null;
  };
  /** Replace the rulebook (the corpus task's data/food-safety drop-in). */
  setRulebook(rulebook: FoodSafetyRulebook): void;
  /** The rulebook currently in force. */
  rulebook(): FoodSafetyRulebook;
}

const FAIL_CLOSED_SOURCE = "pinned food-safety canon (VALIDATION FAILED)";

function failClosedTool(errors: readonly string[]): FoodSafetyTool {
  const reason = `the pinned food-safety canon failed validation (${errors.slice(0, 3).join("; ")}); this layer refuses to answer doneness rather than guess — re-pin a reviewed canon`;
  return {
    checkFoodSafety({ product }) {
      return {
        answer: { kind: "unknown", reason: `no reviewed thermometer-based safe minimum for "${product}": ${reason}` },
        unknowns: [`food safety: canon validation failed — no checkable test for "${product}"`],
        sourceName: null
      };
    },
    setRulebook() {
      // A fail-closed tool accepts no override: the canon must be repaired first.
    },
    rulebook() {
      return { source: FAIL_CLOSED_SOURCE, entries: [] };
    }
  };
}

export function createFoodSafetyTool(initial?: FoodSafetyRulebook): FoodSafetyTool {
  if (!initial) {
    const canon = canonRulebookOrNull();
    if (!canon) {
      // Fail closed: no valid canon, no answers. (Never fall back to a guess.)
      const probe = (() => {
        try {
          return buildCanonRulebook(JSON.parse(readCanonRulesJson()));
        } catch (error) {
          return { ok: false as const, errors: [`canon unreadable: ${(error as Error).message}`] };
        }
      })();
      return failClosedTool(probe.ok ? ["unreachable"] : probe.errors);
    }
    return createToolFor(canon);
  }
  return createToolFor(initial);
}

function createToolFor(active: FoodSafetyRulebook): FoodSafetyTool {
  return {
    checkFoodSafety({ product, question }) {
      const match = matchStrictest(product, question ?? "", active);
      if (!match) {
        return {
          answer: {
            kind: "unknown",
            reason: `no reviewed thermometer-based safe minimum for "${product}" in ${
              active.source
            }; this layer never answers doneness by colour or time`
          },
          unknowns: [
            `food safety: no reviewed entry for "${product}" — cannot give a checkable test`,
            "a camera look or cooking time cannot establish doneness (SPEC 3.1)"
          ],
          sourceName: null
        };
      }
      const entry = match.entry;
      const check: SourcedCheck = {
        tool: "checkFoodSafety",
        product,
        test: entry.test,
        temperatureC: celsius(entry.temperatureC),
        temperatureF: entry.temperatureF,
        ...(entry.restMinutes !== undefined ? { restMinutes: entry.restMinutes } : {}),
        source: active.source
      };
      return { answer: { kind: "sourced-check", check }, unknowns: [], sourceName: active.source };
    },
    setRulebook(rulebook) {
      active = rulebook;
    },
    rulebook() {
      return active;
    }
  };
}

/**
 * Loader override for the corpus task: parse a data/food-safety rulebook
 * JSON file and install it. The file's shape is the rulebook's shape; parse
 * errors throw rather than falling back silently.
 */
export function loadFoodSafetyRulebook(path: string): FoodSafetyRulebook {
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error(`food-safety rulebook ${path}: expected an object`);
  }
  const record = raw as Record<string, unknown>;
  if (typeof record["source"] !== "string" || !Array.isArray(record["entries"])) {
    throw new Error(`food-safety rulebook ${path}: expected { source, entries }`);
  }
  return record as unknown as FoodSafetyRulebook;
}
