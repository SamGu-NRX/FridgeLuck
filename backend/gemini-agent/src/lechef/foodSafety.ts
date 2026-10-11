/**
 * Food safety — doneness as a checkable thermometer test (SPEC 3.1).
 *
 * BINDING: doneness for meat, poultry, fish, eggs and leftovers is stated as
 * a checkable test with a thermometer temperature from a reviewed source —
 * here, the USDA FSIS Safe Minimum Internal Temperature chart — with the
 * source NAMED on every answer. Uncovered products return an explicit
 * unknown: never a colour, never a time, never a guess.
 *
 * data/food-safety is ABSENT on alpha. The FSIS table below is EMBEDDED as
 * the reviewed source until the corpus task (fl-recipe-platform-f1) drops a
 * reviewed rulebook in at data/food-safety — a rulebook loaded through
 * loadFoodSafetyRulebook / setFoodSafetyRulebook SUPersedes this table.
 * Guidance is advisory and sourced; shelf-life never certifies safety.
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

export const FSIS_SOURCE = "USDA FSIS Safe Minimum Internal Temperature chart (fsis.usda.gov)";

// Embedded reviewed table — the interim source of truth until a
// data/food-safety rulebook supersedes it (SPEC 3.1; see module doc).
export const FSIS_EMBEDDED_RULEBOOK: FoodSafetyRulebook = {
  source: FSIS_SOURCE,
  entries: [
    {
      category: "poultry",
      keywords: ["chicken", "turkey", "duck", "goose", "poultry", "cornish hen", "game hen"],
      temperatureC: 74,
      temperatureF: 165,
      test: "Check with a thermometer in the thickest piece, avoiding bone: it must read 74 °C (165 °F) or hotter."
    },
    {
      category: "ground-meat",
      keywords: ["ground beef", "ground pork", "ground lamb", "ground chicken", "ground turkey", "minced beef", "minced pork", "minced lamb", "minced chicken", "hamburger", "meatball", "meatloaf", "burger"],
      temperatureC: 71,
      temperatureF: 160,
      test: "Check with a thermometer at the thickest point: it must read 71 °C (160 °F) or hotter."
    },
    {
      category: "whole-cut",
      keywords: ["steak", "roast", "chop", "tenderloin", "pork loin", "beef", "pork", "lamb", "veal", "ham"],
      temperatureC: 63,
      temperatureF: 145,
      restMinutes: 3,
      test: "Check with a thermometer in the thickest part: it must read 63 °C (145 °F) or hotter, then rest 3 minutes."
    },
    {
      category: "fish",
      keywords: ["fish", "salmon", "tuna", "cod", "trout", "tilapia", "sea bass", "halibut", "mackerel", "sardine"],
      temperatureC: 63,
      temperatureF: 145,
      test: "Check with a thermometer at the thickest part of the fillet: it must read 63 °C (145 °F) or hotter."
    },
    {
      category: "eggs",
      keywords: ["egg", "eggs", "omelette", "omelet", "frittata", "quiche", "custard", "scrambled eggs", "fried egg", "boiled egg"],
      temperatureC: 71,
      temperatureF: 160,
      test: "Cook until the yolk and white are firm, or a thermometer reads 71 °C (160 °F) for egg dishes."
    },
    {
      category: "leftovers",
      keywords: ["leftover", "leftovers", "reheat", "reheating", "re-warm", "rewarm"],
      temperatureC: 74,
      temperatureF: 165,
      test: "Reheat with a thermometer check: the centre must read 74 °C (165 °F) or hotter."
    }
  ]
};

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/**
 * Category matchers are order-sensitive: the most specific rule wins
 * ("ground chicken" is ground meat, not whole-cut poultry; "leftover
 * chicken" is a reheat question first).
 */
function matchEntry(
  product: string,
  question: string,
  rulebook: FoodSafetyRulebook
): { entryIndex: number; matched: string } | null {
  const haystack = normalize(`${product} ${question}`);
  const productOnly = normalize(product);
  const ordered = rulebook.entries
    .map((entry, index) => ({ entry, index, priority: ENTRY_PRIORITY.get(entry.category) ?? 99 }))
    .sort((a, b) => a.priority - b.priority);
  for (const { entry, index } of ordered) {
    const hit = entry.keywords.find(
      (k) => productOnly.includes(k) || (k.includes(" ") && haystack.includes(k))
    );
    if (hit) return { entryIndex: index, matched: hit };
  }
  return null;
}

const ENTRY_PRIORITY: ReadonlyMap<string, number> = new Map([
  ["leftovers", 0],
  ["ground-meat", 1],
  ["poultry", 2],
  ["eggs", 2],
  ["fish", 3],
  ["whole-cut", 4]
]);

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

export function createFoodSafetyTool(initial?: FoodSafetyRulebook): FoodSafetyTool {
  let active: FoodSafetyRulebook = initial ?? FSIS_EMBEDDED_RULEBOOK;

  return {
    checkFoodSafety({ product, question }) {
      const match = matchEntry(product, question ?? "", active);
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
      const entry = active.entries[match.entryIndex];
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
 * JSON file and install it. The file's shape is the embedded table's shape;
 * parse errors throw rather than falling back silently.
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
