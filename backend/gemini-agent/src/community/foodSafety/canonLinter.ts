/**
 * TypeScript port of the FridgeLuck food-safety canon linter (PR #126,
 * branch overhaul/food-safety-canon, Swift package FLFoodSafety + the
 * fl-safety-lint CLI), vendored verbatim under ./canon/ with hash-verified
 * provenance.
 *
 * WHY A PORT: the backend runtime is Bun/TypeScript on Linux — the Swift
 * CLI cannot run there. The sanctioned alternative (Sam's rescope of the
 * food-safety gate) is to load the canon's rules.json and pass EVERY case
 * in its conformance kit from TypeScript tests. This file is therefore a
 * translation of the Swift linter semantics, not a re-invention: the rule
 * data (keywords, minimums, placements, rest times, citations, rewrites'
 * inputs) comes from the vendored rules.json, the copy patterns from the
 * vendored copy-lint-patterns.json, and the conformance runner replays the
 * vendored kit byte-for-byte. Linter-level detection vocabulary (the phrase
 * regexes below) is the canon's own, transcribed; the minimums and class
 * keywords that the old local heuristics hardcoded are DELETED — they are
 * data now.
 *
 * Semantics are pinned by the conformance kit, not by this file's prose:
 * `runConformanceKit` replays every vendored case and must pass. Anything
 * the kit leaves underspecified fails closed at the call site (the gate
 * refuses publication on ANY finding — including flagForReview and
 * failClosed — and on any undecodable or drifted canon data).
 */

// MARK: - Strict JSON decode helpers

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function checkKeys(dict: Record<string, unknown>, allowed: readonly string[], what: string, issues: string[]): void {
  const allowedSet = new Set(allowed);
  const unknown = Object.keys(dict)
    .filter((key) => !allowedSet.has(key))
    .sort();
  if (unknown.length > 0) {
    issues.push(`${what}: unknown key(s) ${unknown.join(", ")}`);
  }
}

function readString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function readNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function readStringArray(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    return null;
  }
  return value as string[];
}

// MARK: - Food classes and topics (Rulebook.swift)

export const FOOD_CLASSES = [
  "meat_poultry",
  "meat_ground",
  "meat_whole_cut_pork",
  "meat_whole_cut_red",
  "flesh_fish",
  "flesh_shellfish",
  "egg",
  "leftovers",
] as const;
export type FoodClass = (typeof FOOD_CLASSES)[number];

/** The FSIS safe minimum each class must reach (FoodClass.minimumTempF). Used only in flag rewrites; enforcement reads rules.json data. */
export const FOOD_CLASS_MINIMUM_TEMP_F: Record<FoodClass, number> = {
  meat_poultry: 165,
  meat_ground: 160,
  meat_whole_cut_pork: 145,
  meat_whole_cut_red: 145,
  flesh_fish: 145,
  flesh_shellfish: 145,
  egg: 160,
  leftovers: 165,
};

export const RULE_TOPICS = [
  "doneness",
  "reheating",
  "cooling_window",
  "danger_zone",
  "leftover_storage_window",
  "cooling_method",
  "thawing",
  "cross_contamination",
  "hygiene",
  "raw_egg",
  "rest_time",
  "thermometer",
  "appearance_not_sufficient",
  "high_risk_groups",
] as const;
export type RuleTopic = (typeof RULE_TOPICS)[number];

// MARK: - LintFinding (LintFinding.swift)

export const FINDING_KINDS = [
  // Legacy classes. Raw values mirror the corpus linter's flag kinds exactly.
  "appearanceDoneness",
  "timeOnlyCooking",
  "rawEggNoWarning",
  "ambientThawing",
  "leftoversHeldOut",
  "reheatingWithoutThermometer",
  // Strict canon classes (contract clauses 1–7).
  "belowMinimumTemperature",
  "missingThermometer",
  "missingInternalTemperature",
  "missingRestTime",
  "ovenTemperatureAsDoneness",
  "metadataNotInText",
  "flagForReview",
  "failClosed",
] as const;
export type FindingKind = (typeof FINDING_KINDS)[number];

/** Deterministic report order: the strict canon kinds first, then the legacy classes in their historical order. */
export const FINDING_REPORT_ORDER: readonly FindingKind[] = [
  "failClosed",
  "belowMinimumTemperature",
  "missingThermometer",
  "missingInternalTemperature",
  "missingRestTime",
  "ovenTemperatureAsDoneness",
  "metadataNotInText",
  "flagForReview",
  "appearanceDoneness",
  "timeOnlyCooking",
  "rawEggNoWarning",
  "ambientThawing",
  "leftoversHeldOut",
  "reheatingWithoutThermometer",
];

/**
 * One finding from the strict canon linter, in the canon finding format:
 * the unsafe text, the reviewed rule it violates (with its verbatim source
 * quote), and one exact rewrite that fixes it.
 */
export interface LintFinding {
  readonly kind: FindingKind;
  /** The rules.json rule id the finding enforces (empty for review flags and fail-closed findings). */
  readonly ruleID: string;
  /** The matched phrase (empty for context-level findings). */
  readonly phrase: string;
  /** "ORG — Title" of the primary source (empty when no rule applies). */
  readonly sourceAttribution: string;
  readonly sourceURL: string;
  /** A verbatim quote from the primary source supporting the finding. */
  readonly sourceQuote: string;
  /** The class minimum (°F) the rewrite points at, when the finding carries a temperature requirement. */
  readonly suggestedTempF: number | null;
  /** The full proposed replacement text for the step (the exact rewrite). */
  readonly suggestedRewrite: string;
  /** What is missing, what the reviewer must decide, or why the linter failed closed. */
  readonly detail: string;
  /** The verbatim step text the finding was raised against. */
  readonly currentText: string;
}

/** The finding as one canon-format line: file · record id · field · current text · required change (rewrite + rule id + citation). */
export function findingLine(finding: LintFinding, file: string | null, recordID: string | null, field: string | null): string {
  const anchor = [file, recordID, field]
    .filter((part) => part !== null && part !== "")
    .join(" · ");
  const parts: string[] = [];
  if (anchor.length > 0) {
    parts.push(anchor);
  }
  if (finding.currentText.length > 0) {
    parts.push(`current text: “${finding.currentText}”`);
  }
  if (finding.phrase.length > 0) {
    parts.push(`matched phrase: “${finding.phrase}”`);
  }
  if (finding.kind === "flagForReview") {
    parts.push(`FLAG FOR REVIEW — ${finding.detail}`);
  } else if (finding.kind === "failClosed") {
    parts.push(`FAIL CLOSED — ${finding.detail}`);
  } else {
    if (finding.detail.length > 0) {
      parts.push(finding.detail);
    }
    if (finding.suggestedRewrite.length > 0) {
      parts.push(`required change: ${finding.suggestedRewrite}`);
    }
    if (finding.ruleID.length > 0) {
      parts.push(`rule \`${finding.ruleID}\``);
    }
    if (finding.sourceAttribution.length > 0) {
      parts.push(`source: ${finding.sourceAttribution}, ${finding.sourceURL}: “${finding.sourceQuote}”`);
    }
  }
  return `[${finding.kind}] ` + parts.join(" · ");
}

// MARK: - Rulebook decode + validation (Rulebook.swift)

export interface CheckData {
  readonly kind: "thermometer" | "rest";
  readonly tempF: number;
  readonly tempC: number;
  readonly restMinutes: number;
  readonly placement: string | null;
  readonly alternativeTempF: number | null;
}

export interface CitationData {
  readonly id: string;
  readonly org: string;
  readonly title: string;
  readonly url: string;
  readonly retrieved: string;
  readonly pageLastUpdated: string | null;
  /** Every quote-family key (quote, second_quote … table_quote) in declared order. */
  readonly quotes: readonly string[];
}

export interface RuleData {
  readonly id: string;
  readonly topic: RuleTopic;
  readonly foodClass: FoodClass | null;
  readonly summary: string;
  readonly check: CheckData | null;
  readonly matchKeywords: readonly string[] | null;
  readonly visualCuesInsufficient: readonly string[] | null;
  readonly highRiskGroups: readonly string[] | null;
  readonly rsNote: string | null;
  readonly publishedAppearanceAlternativeNote: string | null;
  readonly citationIDs: readonly string[];
}

export interface RSAlignmentData {
  readonly consumer: string;
  readonly foodClassNames: string;
  readonly minimumsF: Record<string, number>;
  readonly corpusSafetyField: string;
  readonly forbiddenPhrases: string;
  readonly citationForSource: string;
}

export interface RulebookData {
  readonly schemaVersion: number;
  readonly retrieved: string;
  readonly name: string;
  readonly rsAlignment: RSAlignmentData;
  readonly descriptionText: string;
  readonly citations: readonly CitationData[];
  readonly rules: readonly RuleData[];
}

export class RulebookDecodeError extends Error {
  readonly issues: readonly string[];
  constructor(issues: readonly string[]) {
    super(`Rulebook schema violation (${issues.length}):\n${issues.map((issue) => `  - ${issue}`).join("\n")}`);
    this.name = "RulebookDecodeError";
    this.issues = issues;
  }
}

const RULEBOOK_TOP_LEVEL_KEYS = ["schema_version", "retrieved", "name", "rs_alignment", "description", "citations", "rules"] as const;
const RULEBOOK_RS_ALIGNMENT_KEYS = ["consumer", "food_class_names", "minimums_f", "corpus_safety_field", "forbidden_phrases", "citation_for_source"] as const;
const RULEBOOK_CITATION_KEYS = [
  "id", "org", "title", "url", "retrieved", "page_last_updated",
  "quote", "second_quote", "third_quote", "fourth_quote", "fifth_quote",
  "sixth_quote", "seventh_quote", "eighth_quote", "ninth_quote",
  "tenth_quote", "table_quote",
] as const;
const RULEBOOK_RULE_KEYS = [
  "id", "topic", "food_class", "summary", "check", "match_keywords",
  "visual_cues_insufficient", "high_risk_groups", "rs_note",
  "published_appearance_alternative_note", "citation_ids",
] as const;
const RULEBOOK_CHECK_KEYS = ["kind", "temp_f", "temp_c", "rest_minutes", "placement", "alternative_temp_f"] as const;

/** Quote keys in declared JSON order; quotes are collected in this order, never container-iteration order. */
const CITATION_QUOTE_KEYS = [
  "quote", "second_quote", "third_quote", "fourth_quote", "fifth_quote",
  "sixth_quote", "seventh_quote", "eighth_quote", "ninth_quote",
  "tenth_quote", "table_quote",
] as const;

/** The Swift decode's ISO-date shape check, ported verbatim (length 10, '-' at index 4, not at index 3). */
function isoDateIssues(value: string, field: string): string[] {
  if (value.length !== 10 || value[4] !== "-" || value[3] === "-") {
    return [`${field}: '${value}' is not an ISO date (YYYY-MM-DD)`];
  }
  return [];
}

function decodeCitation(raw: unknown, issues: string[], index: number): CitationData {
  const what = `citations[${index}]`;
  if (!isRecord(raw)) {
    throw new RulebookDecodeError([`${what} must be an object`]);
  }
  checkKeys(raw, RULEBOOK_CITATION_KEYS, what, issues);
  const id = readString(raw["id"]);
  const org = readString(raw["org"]);
  const title = readString(raw["title"]);
  const url = readString(raw["url"]);
  const retrieved = readString(raw["retrieved"]);
  if (id === null || org === null || title === null || url === null || retrieved === null) {
    throw new RulebookDecodeError([`${what} must carry string id/org/title/url/retrieved`]);
  }
  const pageLastUpdated = readString(raw["page_last_updated"]);
  const quotes: string[] = [];
  for (const key of CITATION_QUOTE_KEYS) {
    const quote = readString(raw[key]);
    if (quote !== null) {
      quotes.push(quote);
    }
  }
  return { id, org, title, url, retrieved, pageLastUpdated, quotes };
}

function decodeCheck(raw: unknown, issues: string[], what: string): CheckData | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  if (!isRecord(raw)) {
    throw new RulebookDecodeError([`${what} must be an object`]);
  }
  checkKeys(raw, RULEBOOK_CHECK_KEYS, what, issues);
  const kind = readString(raw["kind"]);
  const tempF = readNumber(raw["temp_f"]);
  const tempC = readNumber(raw["temp_c"]);
  const restMinutes = readNumber(raw["rest_minutes"]);
  if (kind === null || tempF === null || tempC === null || restMinutes === null) {
    throw new RulebookDecodeError([`${what} must carry kind/temp_f/temp_c/rest_minutes`]);
  }
  if (kind !== "thermometer" && kind !== "rest") {
    throw new RulebookDecodeError([`${what}: unknown check kind '${kind}'`]);
  }
  const placement = readString(raw["placement"]);
  const alternativeTempF = readNumber(raw["alternative_temp_f"]);
  return { kind, tempF, tempC, restMinutes, placement, alternativeTempF };
}

function decodeRule(raw: unknown, issues: string[], index: number): RuleData {
  const what = `rules[${index}]`;
  if (!isRecord(raw)) {
    throw new RulebookDecodeError([`${what} must be an object`]);
  }
  checkKeys(raw, RULEBOOK_RULE_KEYS, what, issues);
  const id = readString(raw["id"]);
  const topic = readString(raw["topic"]);
  const summary = readString(raw["summary"]);
  if (id === null || topic === null || summary === null) {
    throw new RulebookDecodeError([`${what} must carry string id/topic/summary`]);
  }
  if (!(RULE_TOPICS as readonly string[]).includes(topic)) {
    throw new RulebookDecodeError([`${what}: unknown topic '${topic}'`]);
  }
  const foodClassRaw = readString(raw["food_class"]);
  let foodClass: FoodClass | null = null;
  if (foodClassRaw !== null) {
    if (!(FOOD_CLASSES as readonly string[]).includes(foodClassRaw)) {
      throw new RulebookDecodeError([`${what}: unknown food_class '${foodClassRaw}'`]);
    }
    foodClass = foodClassRaw as FoodClass;
  }
  const check = decodeCheck(raw["check"], issues, `${what}.check`);
  const matchKeywords = readStringArray(raw["match_keywords"]);
  const visualCuesInsufficient = readStringArray(raw["visual_cues_insufficient"]);
  const highRiskGroups = readStringArray(raw["high_risk_groups"]);
  const citationIDs = readStringArray(raw["citation_ids"]);
  if (citationIDs === null) {
    throw new RulebookDecodeError([`${what}: citation_ids must be an array of strings`]);
  }
  return {
    id,
    topic: topic as RuleTopic,
    foodClass,
    summary,
    check,
    matchKeywords,
    visualCuesInsufficient,
    highRiskGroups,
    rsNote: readString(raw["rs_note"]),
    publishedAppearanceAlternativeNote: readString(raw["published_appearance_alternative_note"]),
    citationIDs,
  };
}

function decodeRSAlignment(raw: unknown, issues: string[], ): RSAlignmentData {
  const what = "rs_alignment";
  if (!isRecord(raw)) {
    throw new RulebookDecodeError([`${what} must be an object`]);
  }
  checkKeys(raw, RULEBOOK_RS_ALIGNMENT_KEYS, what, issues);
  const consumer = readString(raw["consumer"]);
  const foodClassNames = readString(raw["food_class_names"]);
  const corpusSafetyField = readString(raw["corpus_safety_field"]);
  const forbiddenPhrases = readString(raw["forbidden_phrases"]);
  const citationForSource = readString(raw["citation_for_source"]);
  const minimumsFRaw = raw["minimums_f"];
  if (consumer === null || foodClassNames === null || corpusSafetyField === null || forbiddenPhrases === null || citationForSource === null || !isRecord(minimumsFRaw)) {
    throw new RulebookDecodeError([`${what} must carry consumer/food_class_names/minimums_f/corpus_safety_field/forbidden_phrases/citation_for_source`]);
  }
  const minimumsF: Record<string, number> = {};
  for (const [key, value] of Object.entries(minimumsFRaw)) {
    const numeric = readNumber(value);
    if (numeric === null) {
      throw new RulebookDecodeError([`${what}.minimums_f.${key} must be a number`]);
    }
    minimumsF[key] = numeric;
  }
  return { consumer, foodClassNames, minimumsF, corpusSafetyField, forbiddenPhrases, citationForSource };
}

/** Citation attribution used in flags and rewrites: "ORG — Title". */
export function citationAttribution(citation: CitationData): string {
  return `${citation.org} — ${citation.title}`;
}

/** Post-decode semantic checks (Rulebook.validate), ported. */
function validateRulebook(book: RulebookData): string[] {
  const issues: string[] = [];
  if (book.schemaVersion !== 1) {
    issues.push(`schema_version must be 1, got ${book.schemaVersion}`);
  }
  issues.push(...isoDateIssues(book.retrieved, "retrieved"));

  const citationByID = new Map<string, CitationData>();
  for (const citation of book.citations) {
    if (citationByID.has(citation.id)) {
      issues.push(`duplicate citation id ${citation.id}`);
    }
    citationByID.set(citation.id, citation);
    const where = `citation ${citation.id}`;
    if (citation.org.length === 0) {
      issues.push(`${where}: org is empty`);
    }
    if (citation.title.length === 0) {
      issues.push(`${where}: title is empty`);
    }
    if (!(citation.url.startsWith("http://") || citation.url.startsWith("https://"))) {
      issues.push(`${where}: url is not absolute http(s): ${citation.url}`);
    }
    issues.push(...isoDateIssues(citation.retrieved, `${where} retrieved`));
    if (citation.quotes.length === 0) {
      issues.push(`${where}: has no verbatim quote`);
    }
    for (const [i, quote] of citation.quotes.entries()) {
      if (quote.length < 20) {
        issues.push(`${where}: quote[${i}] is not a verbatim quotation (too short)`);
      }
    }
  }

  const ruleIDs = new Set<string>();
  for (const rule of book.rules) {
    if (ruleIDs.has(rule.id)) {
      issues.push(`duplicate rule id ${rule.id}`);
    }
    ruleIDs.add(rule.id);
    const where = `rule ${rule.id}`;
    if (rule.citationIDs.length === 0) {
      issues.push(`${where}: no citation — a rule without a source does not ship`);
    }
    for (const id of rule.citationIDs) {
      if (!citationByID.has(id)) {
        issues.push(`${where}: citation id ${id} does not resolve`);
      }
    }
    if (rule.check !== null) {
      if (rule.check.tempF < 90 || rule.check.tempF > 300) {
        issues.push(`${where}: check temp_f ${rule.check.tempF} outside the plausible range`);
      }
      const converted = ((rule.check.tempF - 32) * 5) / 9;
      if (Math.abs(rule.check.tempC - converted) > 1.0) {
        issues.push(`${where}: check temp_c ${rule.check.tempC} does not match temp_f ${rule.check.tempF}`);
      }
      if (rule.check.restMinutes < 0) {
        issues.push(`${where}: rest_minutes is negative`);
      }
    }
    if (rule.topic === "doneness" && rule.check === null) {
      issues.push(`${where}: doneness rule has no thermometer check`);
    }
    if (rule.matchKeywords !== null && rule.matchKeywords.length === 0) {
      issues.push(`${where}: match_keywords is empty`);
    }
  }
  return issues;
}

/**
 * Decodes and validates the rulebook, strictly. Throws `RulebookDecodeError`
 * listing every schema violation — the failure is loud, nothing half-valid
 * ships.
 */
export function decodeRulebook(data: string): RulebookData {
  const preflightIssues: string[] = [];
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch (error) {
    throw new RulebookDecodeError([`rules data is not valid JSON: ${error instanceof Error ? error.message : String(error)}`]);
  }
  if (!isRecord(raw)) {
    throw new RulebookDecodeError(["top level must be an object"]);
  }
  checkKeys(raw, RULEBOOK_TOP_LEVEL_KEYS, "top level", preflightIssues);
  if (isRecord(raw["rs_alignment"])) {
    checkKeys(raw["rs_alignment"], RULEBOOK_RS_ALIGNMENT_KEYS, "rs_alignment", preflightIssues);
  }
  if (Array.isArray(raw["citations"])) {
    for (const [index, citation] of raw["citations"].entries()) {
      if (isRecord(citation)) {
        checkKeys(citation, RULEBOOK_CITATION_KEYS, `citations[${index}]`, preflightIssues);
      }
    }
  }
  if (Array.isArray(raw["rules"])) {
    for (const [index, rule] of raw["rules"].entries()) {
      if (isRecord(rule)) {
        checkKeys(rule, RULEBOOK_RULE_KEYS, `rules[${index}]`, preflightIssues);
        if (isRecord(rule["check"])) {
          checkKeys(rule["check"], RULEBOOK_CHECK_KEYS, `rules[${index}] check`, preflightIssues);
        }
      }
    }
  }
  if (preflightIssues.length > 0) {
    throw new RulebookDecodeError(preflightIssues);
  }

  const issues: string[] = [];
  const schemaVersion = readNumber(raw["schema_version"]);
  const retrieved = readString(raw["retrieved"]);
  const name = readString(raw["name"]);
  const descriptionText = readString(raw["description"]);
  if (schemaVersion === null || retrieved === null || name === null || descriptionText === null) {
    throw new RulebookDecodeError(["top level must carry schema_version/retrieved/name/description"]);
  }
  if (!Array.isArray(raw["citations"]) || !Array.isArray(raw["rules"])) {
    throw new RulebookDecodeError(["citations and rules must be arrays"]);
  }
  const citations = raw["citations"].map((citation, index) => decodeCitation(citation, issues, index));
  const rules = raw["rules"].map((rule, index) => decodeRule(rule, issues, index));
  const rsAlignment = decodeRSAlignment(raw["rs_alignment"], issues);
  const book: RulebookData = { schemaVersion, retrieved, name, rsAlignment, descriptionText, citations, rules };
  issues.push(...validateRulebook(book));
  if (issues.length > 0) {
    throw new RulebookDecodeError(issues);
  }
  return book;
}

// MARK: - DonenessLookup (DonenessLookup.swift)

/** A doneness rule matched to a text (ingredient name or recipe step). */
export interface DonenessMatch {
  readonly rule: RuleData;
  /** The keyword that matched, for explainability. */
  readonly matchedKeyword: string;
  /** Selection rank of the winning keyword (lower = more specific context). */
  readonly matchTier: number;
}

/** Words that state how the protein was processed — they decide the class over anything else. */
const PROCESSING_WORDS: ReadonlySet<string> = new Set([
  "ground", "minced", "mince", "diced", "shredded", "burger", "patty", "patties",
]);

/** Species words — more specific than the cut they come from. */
const SPECIES_WORDS: ReadonlySet<string> = new Set([
  "chicken", "turkey", "duck", "goose", "quail", "beef", "pork", "lamb",
  "veal", "venison", "mutton", "goat", "ham", "gammon", "bacon",
  "salmon", "cod", "tuna", "trout", "haddock", "pollock", "catfish",
  "bass", "mackerel", "sardine", "sardines", "anchovy", "halibut",
  "shrimp", "prawn", "prawns", "mussel", "mussels", "clam", "clams",
  "oyster", "oysters", "scallop", "scallops", "crab", "lobster",
  "squid", "octopus", "cockles", "egg", "eggs", "yolk", "yolks",
  "leftover", "leftovers",
]);

/** Selection precedence: 0 beats 1 beats 2. */
function keywordTier(keyword: string): number {
  const words = new Set(keyword.split(" "));
  for (const word of words) {
    if (PROCESSING_WORDS.has(word)) {
      return 0;
    }
  }
  for (const word of words) {
    if (SPECIES_WORDS.has(word)) {
      return 1;
    }
  }
  return 2;
}

/** Species whose processed form keeps the poultry minimum (165 °F), not the generic ground-meat 160 °F. */
const POULTRY_SPECIES: ReadonlySet<string> = new Set(["chicken", "turkey", "duck", "goose", "quail", "hen"]);

/** Generic protein words beyond the class keywords — meats, seafood and processed meats the rulebook may not classify. */
const GENERIC_PROTEIN_WORDS: ReadonlySet<string> = new Set([
  "meat", "meats", "seafood", "offal", "rabbit", "hare", "venison",
  "bison", "buffalo", "boar", "ostrich", "emu", "kangaroo", "crocodile",
  "alligator", "frog", "snail", "snails", "escargot", "liver", "kidney",
  "tongue", "tripe", "sweetbread", "sweetbreads", "sausage", "sausages",
  "bratwurst", "kielbasa", "chorizo", "salami", "pepperoni", "prosciutto",
  "pancetta", "mortadella", "bologna", "frankfurter", "frankfurters",
  "hot dog", "hot dogs", "deli meat", "deli meats", "lunch meat",
  "cold cuts", "pheasant", "partridge", "grouse", "pigeon", "squab",
  "moose", "elk", "caribou", "reindeer", "squirrel",
]);

/** Pantry compounds where the food word names a product, not the protein being cooked — matching them would fabricate a doneness class. */
const COMPOUND_EXCLUSIONS: readonly string[] = [
  "fish sauce", "fish stock", "chicken stock", "beef stock", "beef broth",
  "bone broth", "ham stock", "meat tenderiser", "meat tenderizer",
  "meat thermometer", "meat thermometre",
];

/** Neutralises pantry compounds so "fish sauce" never reads as fish. */
export function neutraliseCompounds(text: string): string {
  let out = text;
  for (const compound of COMPOUND_EXCLUSIONS) {
    out = out.split(compound).join(compound.split(" ").join(""));
  }
  return out;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Whole-word, adjacency-preserving match. Multi-word keywords allow whitespace between tokens; \b boundaries stop "egg" matching "eggplant". */
export function keywordMatches(keyword: string, foldedText: string): boolean {
  const escaped = escapeRegExp(keyword.toLowerCase());
  const pattern = "\\b" + escaped.split(" ").join("\\s+") + "\\b";
  return new RegExp(pattern).test(foldedText);
}

function matchesPoultrySpecies(foldedText: string): boolean {
  for (const species of POULTRY_SPECIES) {
    if (keywordMatches(species, foldedText)) {
      return true;
    }
  }
  return false;
}

/** Whole-word protein mention (species or generic words), with pantry compounds neutralised. */
export function mentionsProtein(text: string): boolean {
  const folded = neutraliseCompounds(text.toLowerCase());
  for (const word of GENERIC_PROTEIN_WORDS) {
    if (keywordMatches(word, folded)) {
      return true;
    }
  }
  for (const word of SPECIES_WORDS) {
    if (keywordMatches(word, folded)) {
      return true;
    }
  }
  return false;
}

/** Doneness keywords that are bare cooking-verb forms — "bake" in the casserole list names dishes like an egg bake, not the imperative. */
const BARE_VERB_KEYWORD_PATTERN = "^(?:bake|roast|grill|broil|fry|heat|cook)(?:s|ed|ing)?$";

export function isBareCookingVerbKeyword(keyword: string): boolean {
  return new RegExp(BARE_VERB_KEYWORD_PATTERN).test(keyword);
}

/** Looks up the applicable doneness check for an ingredient or recipe step (most specific context wins). */
export class DonenessLookup {
  private readonly donenessRules: readonly RuleData[];

  constructor(rulebook: RulebookData) {
    // Rules with keywords and a thermometer check, in file order; the
    // lookup ranks candidates by matched-keyword specificity.
    this.donenessRules = rulebook.rules.filter((rule) => rule.check !== null && rule.matchKeywords !== null);
  }

  /** The doneness rule for a class, if the rulebook defines one. */
  rule(foodClass: FoodClass): RuleData | null {
    return this.donenessRules.find((rule) => rule.foodClass === foodClass) ?? null;
  }

  check(text: string): DonenessMatch | null {
    const folded = neutraliseCompounds(text.toLowerCase());
    let best: DonenessMatch | null = null;
    for (const rule of this.donenessRules) {
      for (const keyword of rule.matchKeywords ?? []) {
        if (!keywordMatches(keyword, folded)) {
          continue;
        }
        const tier = keywordTier(keyword);
        const better =
          best === null
            ? true
            : tier !== best.matchTier
              ? tier < best.matchTier
              : keyword.length > best.matchedKeyword.length;
        if (better) {
          best = { rule, matchedKeyword: keyword, matchTier: tier };
        }
      }
    }
    // Poultry processed as mince keeps the poultry minimum: FSIS publishes
    // ground poultry separately, and meat_ground's 160 °F would understate
    // it (the corpus must cite meat_poultry for ground poultry too).
    if (best?.rule.foodClass === "meat_ground" && matchesPoultrySpecies(folded)) {
      const groundPoultry = this.donenessRules.find((rule) => rule.id === "ground-poultry-165");
      if (groundPoultry !== undefined) {
        best = { rule: groundPoultry, matchedKeyword: "ground poultry", matchTier: 0 };
      }
    }
    return best;
  }

  /** All rules whose keywords match the text, most specific first (tier, then longer keyword, then rulebook order). */
  matches(text: string): readonly DonenessMatch[] {
    const folded = neutraliseCompounds(text.toLowerCase());
    const candidates: Array<{ match: DonenessMatch; order: number }> = [];
    for (const [order, rule] of this.donenessRules.entries()) {
      for (const keyword of rule.matchKeywords ?? []) {
        if (keywordMatches(keyword, folded)) {
          candidates.push({ match: { rule, matchedKeyword: keyword, matchTier: keywordTier(keyword) }, order });
        }
      }
    }
    // Poultry processed as mince keeps the poultry minimum (the same
    // override `check` applies).
    if (candidates.some((candidate) => candidate.match.rule.foodClass === "meat_ground") && matchesPoultrySpecies(folded)) {
      const groundPoultry = this.donenessRules.find((rule) => rule.id === "ground-poultry-165");
      if (groundPoultry !== undefined) {
        candidates.push({ match: { rule: groundPoultry, matchedKeyword: "ground poultry", matchTier: 0 }, order: -1 });
      }
    }
    return candidates
      .sort((lhs, rhs) => {
        if (lhs.match.matchTier !== rhs.match.matchTier) {
          return lhs.match.matchTier - rhs.match.matchTier;
        }
        if (lhs.match.matchedKeyword.length !== rhs.match.matchedKeyword.length) {
          return rhs.match.matchedKeyword.length - lhs.match.matchedKeyword.length;
        }
        return lhs.order - rhs.order;
      })
      .map((candidate) => candidate.match);
  }
}

// MARK: - StepLinter (StepLinter.swift)

/** (regex pattern, matched-phrase description). Order = report order. */
const APPEARANCE_PATTERNS: ReadonlyArray<readonly [pattern: string, label: string]> = [
  ["no longer pink", "no longer pink"],
  ["no pink", "no pink"],
  ["not pink", "not pink"],
  ["juices? (?:run|runs) clear", "juices run clear"],
  ["clear juices", "clear juices"],
  ["cooked through", "cooked through"],
  ["no longer translucent", "no longer translucent"],
  ["browned through", "browned through"],
  ["firm to the touch", "firm to the touch"],
  ["golden", "golden"],
  ["opaque", "opaque"],
];

/** Phrases that show the step already checks a temperature. */
const THERMOMETER_PATTERNS: readonly string[] = [
  "thermometer",
  "internal temperature",
  "\\d+(?:\\.\\d+)?\\s*°\\s*[cf]",
  "\\d+\\s*degrees?\\s+(?:c|f|celsius|fahrenheit)\\b",
  "reaches? (?:an internal )?temperature",
];

const DURATION_PATTERN = "\\b\\d+(?:[.,]\\d+)?(?:\\s*(?:-|–|to)\\s*\\d+(?:[.,]\\d+)?)?\\s*(?:minutes?|mins?|hours?|hrs?|hrs)\\b";

const AMBIENT_THAW_PATTERN =
  "(?:thaw|defrost)\\b[^.]*(?:on the counter|at room temperature|room-temp|in hot water|under hot water|outside|in the sun)|(?:counter|room temperature)[^.]*\\b(?:thaw|defrost)";

const LEFTOVERS_OUT_PATTERN =
  "(?:leftover|leftovers|cooked (?:rice|pasta|chicken|meat|fish|food|dish))\\b[^.]*\\b(?:left (?:out|at room temperature)|leaving (?:it|them) out|(?:at|to) room temperature|on the counter|stand(?:ing)? at room temperature)";

/** Handling steps — cooling, chilling, marinating, resting, proving — name durations that are not cooking times. */
const HANDLING_VERB_PATTERN =
  "\\b(?:refrigerat\\w*|chill\\w*|freez\\w*|frozen|cool(?:s|ed|ing)?|marinat\\w*|soak\\w*|rest(?:s|ed|ing)?|proof\\w*|proving|stand(?:s|ing)?)\\b";

/** Appearance phrases that inherently claim protein doneness — unsafe on their own. */
const PROTEIN_IMPLIED_PATTERNS: readonly string[] = [
  "no longer pink", "no pink", "not pink", "no longer translucent",
  "opaque", "juices run clear", "juice runs clear", "clear juices",
  "cooked through", "browned through", "firm to the touch",
];

/** Cooking verbs — heat applied to food. */
const COOKING_VERB_PATTERN =
  "\\b(?:cook|cooks|cooked|cooking|bake|bakes|baked|baking|roast|roasts|roasted|roasting|grill|grills|grilled|grilling|broil|broils|broiled|broiling|fry|fries|fried|frying|sauté|sautés|sautéed|saute|sautes|sear|sears|seared|searing|boil|boils|boiled|boiling|poach|poaches|poached|poaching|simmer|simmers|simmered|simmering|braise|braises|braised|braising|steam|steams|steamed|steaming|scramble|scrambles|scrambled|barbecue|chargrill|blacken|blackened|deep.?fry|stir.?fry|pan.?fry|air.?fry|microwave|microwaves|microwaved|reheat|reheats|reheated|reheating)\\b";

/** Reheat verbs beyond the appliance itself. */
const REHEAT_VERB_PATTERN = "\\b(?:reheat|reheats|reheated|reheating|re-warm|rewarm|warm up|warming up|warm through|warm the|warm it|warm them)\\b";

const THAW_WORD_PATTERN = "\\b(?:thaw|thaws|thawing|thawed|defrost|defrosts|defrosting|defrosted)\\b";

/** Foods whose reheating must reach the reheating rule's minimum. */
const REHEATABLE_FOOD_PATTERN =
  "\\b(?:leftovers?|left[- ]?overs?|cooked (?:rice|pasta|chicken|meat|fish|food|dish|meal)|sauce|soup|gravy|stew|casserole|curry|chilli|chili|chowder|rice|pasta|noodles?|pizza|pie)\\b";

/** Non-protein cooked objects: when a step names one, the recipe's protein context does not put the step under a doneness requirement. */
const COOKED_OBJECT_STOP_PATTERN =
  "\\b(?:stock|broth|water|wine|beer|rice|pasta|noodles?|lentils?|beans?|quinoa|couscous|oats|porridge|vegetables?|onions?|garlic|potato(?:es)?|sauce|syrup|cream|milk|butter|oil|dough|bread|gravy)\\b";

/** Vague or appearance doneness claims — the clause-4 trigger when the only temperature around is an oven/pan/microwave one. */
const DONENESS_CLAIM_PATTERN =
  "(?:until|till)\\s+(?:it(?:'s| is)?\\s+|they(?:'re| are)?\\s+|everything is\\s+)?(?:fully\\s+|completely\\s+)?(?:done|cooked|cooked through|safe to eat)|cooked through|no longer pink|no pink|not pink|juices? (?:run|runs) clear|clear juices|no longer translucent|browned through|firm to the touch|golden|opaque";

/** Thermometer words (contract clause 1), plus reasonable synonyms. */
const THERMOMETER_WORD_PATTERN = "\\bthermomet(?:er|re)s?\\b|\\binstant[- ]read\\b|\\bprobe\\b";

/** A temperature statement: number(s) with an explicit °F/°C unit. Ranges yield both bounds; unitless numbers never count. */
const TEMP_PATTERN =
  "(\\d+(?:[.,]\\d+)?)(?:\\s*(?:–|—|-|to)\\s*(\\d+(?:[.,]\\d+)?))?\\s*(?:°\\s*([cf])\\b|deg(?:rees?)?\\.?\\s+([cf])(?:elsius|ahrenheit|renheit)?\\b)";

/** One parsed temperature statement: value, unit, whether it belongs to a device rather than the food's interior, and the verbatim text. */
export interface TempMention {
  readonly value: number;
  readonly unit: "fahrenheit" | "celsius";
  readonly isDevice: boolean;
  readonly text: string;
}

/** The legacy six-class flag, lifted into the strict format by `findings`. */
interface LintFlag {
  readonly kind: Exclude<FindingKind, "belowMinimumTemperature" | "missingThermometer" | "missingInternalTemperature" | "missingRestTime" | "ovenTemperatureAsDoneness" | "metadataNotInText" | "flagForReview" | "failClosed">;
  readonly ruleID: string;
  readonly phrase: string;
  readonly sourceAttribution: string;
  readonly sourceURL: string;
  readonly sourceQuote: string;
  readonly suggestedTempF: number | null;
  readonly suggestedRewrite: string;
}

/** How the strict layer reads a step. */
export type StepContext =
  | { readonly kind: "cooking"; readonly match: DonenessMatch }
  | { readonly kind: "reheating"; readonly match: DonenessMatch }
  | { readonly kind: "thawing" }
  | { readonly kind: "other" };

/** Structured corpus safety field, parsed from the record's metadata. */
interface SafetyFieldRecord {
  readonly className: string;
  readonly tempF: number;
  readonly method: string;
  readonly source: string;
}

const WORD_NUMBERS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8,
  nine: 9, ten: 10, fifteen: 15, twenty: 20, thirty: 30, forty: 40, "forty-five": 45,
};

/** Flags unsafe phrasing in recipe steps and verifies the strict canon contract (clauses 1–7). */
export class StepLinter {
  private readonly book: RulebookData | null;
  private readonly lookup: DonenessLookup | null;
  private readonly rulebookFailure: string | null;

  constructor(rulebook: RulebookData | null, failureReason?: string | null) {
    if (rulebook === null) {
      this.book = null;
      this.lookup = null;
      this.rulebookFailure = failureReason ?? "no rules data was provided (the rules file is missing)";
      return;
    }
    this.book = rulebook;
    this.lookup = new DonenessLookup(rulebook);
    this.rulebookFailure = null;
  }

  // MARK: Detection helpers

  private static matches(pattern: string, text: string): boolean {
    return new RegExp(pattern, "i").test(text);
  }

  private static firstMatch(patterns: readonly string[], text: string): string | null {
    for (const pattern of patterns) {
      let regex: RegExp;
      try {
        regex = new RegExp(pattern, "i");
      } catch {
        continue;
      }
      const match = regex.exec(text);
      if (match !== null) {
        return match[0];
      }
    }
    return null;
  }

  private matchesAny(text: string, phrases: readonly string[]): boolean {
    return phrases.some((phrase) => StepLinter.matches("\\b" + escapeRegExp(phrase), text));
  }

  private mentionsLeftovers(text: string): boolean {
    return this.matchesAny(text, ["leftover", "left overs", "left-over", "reheat", "re-warm"]);
  }

  private mentionsEggs(text: string): boolean {
    return this.matchesAny(text, ["egg", "eggs", "yolk", "yolks"]);
  }

  private mentionsReheat(text: string): boolean {
    return this.matchesAny(text, ["reheat", "re-warm", "rewarm", "warm up", "warm through", "warm the", "warm it", "microwave"]);
  }

  private mentionsRawEggDish(text: string): boolean {
    return this.matchesAny(text, [
      "caesar", "tiramisu", "mayonnaise", "eggnog", "hollandaise",
      "ice cream", "mousse", "cookie dough", "raw egg",
    ]);
  }

  // MARK: Flag construction (rewrites are data-driven from the rulebook)

  private rule(id: string): RuleData | null {
    return this.book?.rules.find((rule) => rule.id === id) ?? null;
  }

  private citations(forRule: RuleData): readonly CitationData[] {
    const book = this.book;
    if (book === null) {
      return [];
    }
    return forRule.citationIDs
      .map((id) => book.citations.find((citation) => citation.id === id))
      .filter((citation): citation is CitationData => citation !== undefined);
  }

  private source(id: string, quoteIndex = 0): { attribution: string; url: string; quote: string } | null {
    const rule = this.rule(id);
    if (rule === null) {
      return null;
    }
    const citation = this.citations(rule)[0];
    if (citation === undefined || quoteIndex >= citation.quotes.length) {
      return null;
    }
    return { attribution: citationAttribution(citation), url: citation.url, quote: citation.quotes[quoteIndex] };
  }

  private makeAppearanceFlag(step: string, phrase: string): LintFlag {
    const match = this.lookup?.check(step) ?? null;
    const proteinRule = match?.rule ?? this.ruleForClass("meat_poultry") ?? this.rule("thermometer-only-reliable");
    const src = this.source("thermometer-only-reliable");
    if (src === null) {
      throw new Error("rulebook invariant: thermometer-only-reliable cited");
    }
    let rewrite = step;
    if (proteinRule !== null && proteinRule.check !== null) {
      const check = proteinRule.check;
      const placement = check.placement ?? "the thickest part";
      rewrite = `Cook until ${placement} reaches ${Math.trunc(check.tempC)} °C (${Math.trunc(check.tempF)} °F) on a food thermometer — check at the timer rather than judging appearance. (Source: ${src.attribution}, ${src.url}, retrieved ${this.book?.retrieved ?? ""}: "Appearance and color are not reliable indicators of safety or doneness.")`;
    }
    return {
      kind: "appearanceDoneness",
      ruleID: "thermometer-only-reliable",
      phrase,
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: proteinRule?.check?.tempF ?? null,
      suggestedRewrite: rewrite,
    };
  }

  private makeTimeOnlyFlag(step: string, protein: DonenessMatch): LintFlag {
    const rule = protein.rule;
    const check = rule.check;
    let rewrite = step;
    if (check !== undefined && check !== null) {
      const placement = check.placement !== null ? ` in ${check.placement}` : "";
      const verb = rule.foodClass === "leftovers" ? "Reheat" : "Cook";
      const rest = check.restMinutes > 0 ? `, then rest ${Math.trunc(check.restMinutes)} minutes` : "";
      const attribution = this.citations(rule)[0] !== undefined ? citationAttribution(this.citations(rule)[0]) : "USDA FSIS";
      rewrite = `${verb} until a food thermometer${placement} reads ${Math.trunc(check.tempC)} °C (${Math.trunc(check.tempF)} °F)${rest} — the timer only tells you when to check. (Source: ${attribution}, retrieved ${this.book?.retrieved ?? ""})`;
    }
    const src = this.source(rule.id);
    if (src === null) {
      throw new Error("rulebook invariant: protein rule cited");
    }
    return {
      kind: "timeOnlyCooking",
      ruleID: rule.id,
      phrase: protein.matchedKeyword,
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: check?.tempF ?? null,
      suggestedRewrite: rewrite,
    };
  }

  private makeRawEggFlag(step: string): LintFlag {
    const rewrite = `Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved ${this.book?.retrieved ?? ""})`;
    const src = this.source("raw-egg-recipes-pasteurized");
    if (src === null) {
      throw new Error("rulebook invariant: raw-egg rule cited");
    }
    return {
      kind: "rawEggNoWarning",
      ruleID: "raw-egg-recipes-pasteurized",
      phrase: "",
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: FOOD_CLASS_MINIMUM_TEMP_F.egg,
      suggestedRewrite: rewrite,
    };
  }

  private makeThawFlag(step: string): LintFlag {
    const rewrite = `Thaw in the refrigerator, in cold water (leak-proof bag, water changed every 30 minutes), or in the microwave — and cook immediately after cold-water or microwave thawing. Never thaw at room temperature. (Source: USDA FSIS — The Big Thaw, retrieved ${this.book?.retrieved ?? ""})`;
    const src = this.source("thaw-counter-unsafe");
    if (src === null) {
      throw new Error("rulebook invariant: thaw rule cited");
    }
    return {
      kind: "ambientThawing",
      ruleID: "thaw-counter-unsafe",
      phrase: "",
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: null,
      suggestedRewrite: rewrite,
    };
  }

  private makeLeftoversOutFlag(step: string): LintFlag {
    const rewrite = `Refrigerate or freeze leftovers within 2 hours (within 1 hour above 90 °F / 32 °C); discard perishable food left out longer. (Source: USDA FSIS — Leftovers and Food Safety, retrieved ${this.book?.retrieved ?? ""})`;
    const src = this.source("two-hour-rule");
    if (src === null) {
      throw new Error("rulebook invariant: two-hour rule cited");
    }
    return {
      kind: "leftoversHeldOut",
      ruleID: "two-hour-rule",
      phrase: "",
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: FOOD_CLASS_MINIMUM_TEMP_F.leftovers,
      suggestedRewrite: rewrite,
    };
  }

  private makeReheatFlag(step: string): LintFlag {
    const rewrite = `Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved ${this.book?.retrieved ?? ""})`;
    const src = this.source("leftovers-reheat-165");
    if (src === null) {
      throw new Error("rulebook invariant: reheat rule cited");
    }
    return {
      kind: "reheatingWithoutThermometer",
      ruleID: "leftovers-reheat-165",
      phrase: "",
      sourceAttribution: src.attribution,
      sourceURL: src.url,
      sourceQuote: src.quote,
      suggestedTempF: FOOD_CLASS_MINIMUM_TEMP_F.leftovers,
      suggestedRewrite: rewrite,
    };
  }

  private ruleForClass(foodClass: FoodClass): RuleData | null {
    return this.book?.rules.find((rule) => rule.foodClass === foodClass && rule.check !== null) ?? null;
  }

  // MARK: Legacy phrase layer

  /**
   * Lint one recipe step (the six original failure classes, byte-stable for
   * the corpus audit). `recipe` is the surrounding recipe text used for
   * class context.
   */
  lint(step: string, recipe: string): readonly LintFlag[] {
    if (this.lookup === null || this.book === null) {
      return [];
    }
    const flags: LintFlag[] = [];
    const loweredStep = step.toLowerCase();
    const loweredRecipe = recipe.toLowerCase();
    const hasThermometerCheck = StepLinter.firstMatch(THERMOMETER_PATTERNS, loweredStep) !== null;

    // Protein context: the step itself, else the recipe it belongs to.
    const proteinMatch = this.lookup.check(step) ?? this.lookup.check(recipe);
    const stepProtein = this.lookup.check(step);

    // 1. Doneness by appearance — never a safety verdict. Phrases that
    // inherently claim protein doneness flag standalone; pure colour
    // phrases ("golden") need protein or leftover context.
    if (!hasThermometerCheck) {
      const appearance = StepLinter.firstMatch(
        APPEARANCE_PATTERNS.map(([pattern]) => pattern),
        loweredStep,
      );
      if (appearance !== null) {
        const label = APPEARANCE_PATTERNS.find(([pattern]) => StepLinter.matches(pattern, loweredStep))?.[1] ?? appearance;
        const proteinImplied = PROTEIN_IMPLIED_PATTERNS.some((needle) => loweredStep.includes(needle));
        if (proteinImplied || proteinMatch !== null || this.mentionsLeftovers(loweredStep) || this.mentionsLeftovers(loweredRecipe)) {
          flags.push(this.makeAppearanceFlag(step, label));
        }
      }
    }

    // 2. Time-only cooking for protein steps. Handling steps (cooling,
    // chilling, resting, marinating) never flag.
    if (
      !hasThermometerCheck &&
      !StepLinter.matches(HANDLING_VERB_PATTERN, loweredStep) &&
      (stepProtein ?? (this.mentionsLeftovers(loweredStep) ? this.leftoversMatch() : null)) !== null
    ) {
      const protein = stepProtein ?? this.leftoversMatch();
      if (protein !== null && StepLinter.matches(DURATION_PATTERN, loweredStep)) {
        flags.push(this.makeTimeOnlyFlag(step, protein));
      }
    }

    // 3. Raw-egg dishes without the pasteurized-egg warning (either
    // spelling of the treatment).
    if (
      (this.mentionsRawEggDish(loweredStep) || (this.mentionsRawEggDish(loweredRecipe) && this.mentionsEggs(loweredStep))) &&
      !this.matchesAny(loweredStep, ["pasteuriz", "pasteuris"]) &&
      !this.matchesAny(loweredRecipe, ["pasteuriz", "pasteuris"])
    ) {
      flags.push(this.makeRawEggFlag(step));
    }

    // 4. Ambient thawing.
    if (StepLinter.matches(AMBIENT_THAW_PATTERN, loweredStep)) {
      flags.push(this.makeThawFlag(step));
    }

    // 5. Leftovers held out at room temperature.
    if (StepLinter.matches(LEFTOVERS_OUT_PATTERN, loweredStep)) {
      flags.push(this.makeLeftoversOutFlag(step));
    }

    // 6. Reheating without a temperature check.
    if (
      !hasThermometerCheck &&
      this.mentionsReheat(loweredStep) &&
      (this.mentionsLeftovers(loweredStep) || this.mentionsLeftovers(loweredRecipe) || StepLinter.matches("\\b(?:sauce|soup|gravy|stew|casserole|rice|pasta|curry)\\b", loweredStep))
    ) {
      flags.push(this.makeReheatFlag(step));
    }

    return flags;
  }

  private leftoversMatch(): DonenessMatch | null {
    const leftoversRule = this.lookup?.rule("leftovers");
    if (this.lookup === null || leftoversRule === undefined || leftoversRule === null) {
      return null;
    }
    return { rule: leftoversRule, matchedKeyword: "leftover", matchTier: 2 };
  }

  /** Lint a whole instruction block: splits the newline-numbered steps and lints each with the full recipe text as context. */
  lintRecipe(title: string, ingredients: string, instructions: string): ReadonlyArray<{ stepIndex: number; step: string; flags: readonly LintFlag[] }> {
    const context = `${title} ${ingredients} ${instructions}`;
    return numberedSteps(instructions).map((step, index) => ({ stepIndex: index, step, flags: this.lint(step, context) }));
  }

  // MARK: Strict canon verification (clauses 1–7)

  /**
   * The strict canon findings for one step: everything the legacy phrase
   * layer finds, plus verification that the step's doneness check counts.
   * `safetyField` is the raw JSON of the record's structured safety field —
   * a field the text does not show, an unparseable field or an unknown
   * class all fail closed.
   */
  findings(step: string, recipe: string, safetyField: string | null = null): readonly LintFinding[] {
    // Clause 7 first: without a usable rulebook there are no reviewed rules
    // to check against, so every query fails closed.
    if (this.rulebookFailure !== null || this.book === null || this.lookup === null) {
      const failure = this.rulebookFailure ?? "no usable rulebook";
      return [failClosedFinding(failure, step)];
    }

    const found: LintFinding[] = [];
    const context = this.classify(step, recipe);

    // Clause 6: unclassifiable protein — a reviewer decides, never a pass.
    if (
      context.kind === "other" &&
      StepLinter.matches(COOKING_VERB_PATTERN, step.toLowerCase()) &&
      mentionsProtein(step) &&
      this.lookup.check(step) === null &&
      this.lookup.check(recipe) === null
    ) {
      found.push({
        kind: "flagForReview",
        ruleID: "",
        phrase: "",
        sourceAttribution: "",
        sourceURL: "",
        sourceQuote: "",
        suggestedTempF: null,
        suggestedRewrite: "",
        detail: `the step names a protein ("${step.trim()}") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass`,
        currentText: step,
      });
    }

    // Strict doneness verification for cooking and reheating steps.
    if (context.kind === "cooking" || context.kind === "reheating") {
      found.push(...this.verify(step, context.match));
    }

    // Legacy phrase-layer findings, lifted into the strict format. The
    // strict umbrella is suppressed when a named legacy class already
    // describes the defect.
    const legacy = this.lint(step, recipe).map((flag): LintFinding => ({ ...flag, detail: "", currentText: step }));
    const legacyKinds = new Set(legacy.map((finding) => finding.kind));
    const umbrellaSuppressed = ["timeOnlyCooking", "appearanceDoneness", "reheatingWithoutThermometer"].some((kind) => legacyKinds.has(kind as LintFlag["kind"]));
    if (umbrellaSuppressed) {
      for (let i = found.length - 1; i >= 0; i--) {
        if (found[i].kind === "missingInternalTemperature") {
          found.splice(i, 1);
        }
      }
    }
    found.push(...legacy);

    // Clause 5: metadata the text does not show is a finding, not a pass.
    if (safetyField !== null) {
      found.push(...this.verifySafetyField(safetyField, step, this.textHasValidCheck(step, context)));
    }

    // Deterministic report order, one finding per kind. Fail closed
    // dominates: when the record cannot be evaluated, the fail-closed
    // verdict is the finding — no per-step diagnoses beside it.
    if (found.some((finding) => finding.kind === "failClosed")) {
      return found.filter((finding) => finding.kind === "failClosed");
    }
    const seen = new Set<FindingKind>();
    return found
      .filter((finding) => {
        if (seen.has(finding.kind)) {
          return false;
        }
        seen.add(finding.kind);
        return true;
      })
      .sort((lhs, rhs) => FINDING_REPORT_ORDER.indexOf(lhs.kind) - FINDING_REPORT_ORDER.indexOf(rhs.kind));
  }

  /** Strict findings for a whole instruction block; `safetyFields` maps a zero-based step index to that record's structured safety field. */
  findingsForRecipe(
    title: string,
    ingredients: string,
    instructions: string,
    safetyFields: ReadonlyMap<number, string> = new Map(),
  ): ReadonlyArray<{ stepIndex: number; step: string; findings: readonly LintFinding[] }> {
    const context = `${title} ${ingredients} ${instructions}`;
    return numberedSteps(instructions).map((step, index) => ({
      stepIndex: index,
      step,
      findings: this.findings(step, context, safetyFields.get(index) ?? null),
    }));
  }

  // MARK: Classification

  /** Classifies a step for strict verification. Reheating overrides the product class. */
  classify(step: string, recipe: string): StepContext {
    const loweredStep = step.toLowerCase();
    const thawingStep = StepLinter.matches(THAW_WORD_PATTERN, loweredStep);
    const reheatVerb = StepLinter.matches(REHEAT_VERB_PATTERN, loweredStep);
    // "Microwave" alone is also a safe thaw method: a thaw word demotes the
    // appliance word from the reheat indicators.
    const reheatIndicator = reheatVerb || loweredStep.includes("microwave");

    // Reheating: a reheat indicator over leftover-ish food or a protein.
    const stepCheck = this.lookup?.check(step) ?? null;
    const speciesMatch = stepCheck !== null ? stepCheck.rule.topic !== "reheating" : false;
    const reheatable = StepLinter.matches(REHEATABLE_FOOD_PATTERN, loweredStep) || speciesMatch;
    if (reheatIndicator && reheatable && !(thawingStep && !reheatVerb)) {
      const reheatingMatch = this.lookup?.matches(step).find((match) => match.rule.topic === "reheating");
      if (reheatingMatch !== undefined) {
        return { kind: "reheating", match: reheatingMatch };
      }
    }

    // Thawing steps carry no doneness requirement (the legacy layer flags
    // ambient thawing).
    if (thawingStep) {
      return { kind: "thawing" };
    }

    // Protein cooking: a cooking verb plus a protein class from the step,
    // or — when the step names no protein — from the recipe context, unless
    // the step cooks a named non-protein object (stock, rice…).
    if (StepLinter.matches(COOKING_VERB_PATTERN, loweredStep)) {
      // A bare cooking-verb keyword binds a protein class only when the
      // step or recipe also names a protein — otherwise "Bake the bread at
      // 400 °F" would fabricate one from how the food cooks.
      const verbOnly = (match: DonenessMatch): boolean =>
        isBareCookingVerbKeyword(match.matchedKeyword) && !mentionsProtein(step) && !mentionsProtein(recipe);
      const stepMatch = this.lookup?.check(step) ?? null;
      if (stepMatch !== null && !verbOnly(stepMatch)) {
        return { kind: "cooking", match: stepMatch };
      }
      const recipeMatch = this.lookup?.check(recipe) ?? null;
      if (recipeMatch !== null && !verbOnly(recipeMatch) && !StepLinter.matches(COOKED_OBJECT_STOP_PATTERN, loweredStep)) {
        return { kind: "cooking", match: recipeMatch };
      }
    }
    return { kind: "other" };
  }

  // MARK: Per-step verification against the applicable rule

  /** Verifies one cooking or reheating step against its applicable rule's check (minimums and rest are read from the rulebook data). */
  private verify(step: string, match: DonenessMatch): readonly LintFinding[] {
    const rule = match.rule;
    if (rule.check === null) {
      return [
        failClosedFinding(`rule ${rule.id} matched the step but carries no thermometer check — the rulebook is incomplete`, step, rule.id),
      ];
    }
    const check = rule.check;
    const lowered = step.toLowerCase();
    const temps = parseTempMentions(step);
    const internalTemps = temps.filter((temp) => !temp.isDevice);
    const deviceTemps = temps.filter((temp) => temp.isDevice);
    const thermometer = StepLinter.matches(THERMOMETER_WORD_PATTERN, lowered);
    const statedRest = statedRestMinutes(step);
    const restRequired = check.restMinutes > 0;
    const belowMinimum = internalTemps.find((temp) => !meetsMinimum(temp, check));
    const tempOK = internalTemps.length > 0 && belowMinimum === undefined;
    const restOK = !restRequired || (statedRest ?? 0) >= check.restMinutes;
    const validCheck = thermometer && tempOK && restOK;

    const found: LintFinding[] = [];
    const src = this.attribution(rule);
    const minimum = `the class minimum ${Math.trunc(check.tempF)} °F (${Math.trunc(check.tempC)} °C)`;
    const placement = check.placement ?? "the thickest part";
    const rewriteHead = `Cook until ${placement} reaches ${Math.trunc(check.tempC)} °C (${Math.trunc(check.tempF)} °F) on a food thermometer`;
    const rewriteTail = ` (Source: ${src.attribution}, ${src.url}, retrieved ${this.book?.retrieved ?? ""})`;

    if (belowMinimum !== undefined) {
      // A stated internal temperature below the class minimum, per unit
      // (stated °F compares to the rule's temp_f, stated °C to its temp_c).
      found.push({
        kind: "belowMinimumTemperature",
        ruleID: rule.id,
        phrase: belowMinimum.text,
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead} — ${belowMinimum.text} is below ${minimum}.${rewriteTail}`,
        detail: `${belowMinimum.text} is below ${minimum} for ${rule.foodClass ?? "this class"} (rule ${rule.id})`,
        currentText: step,
      });
    } else if (tempOK && !thermometer) {
      // At or above the minimum, but the text never names a thermometer.
      found.push({
        kind: "missingThermometer",
        ruleID: rule.id,
        phrase: "",
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead} — a stated temperature counts only when a thermometer verifies it.${rewriteTail}`,
        detail: "an internal temperature at or above the minimum is stated, but no food thermometer is named in the text",
        currentText: step,
      });
    } else if (thermometer && tempOK && restRequired && !restOK) {
      found.push({
        kind: "missingRestTime",
        ruleID: rule.id,
        phrase: "",
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead}, then rest at least ${Math.trunc(check.restMinutes)} minutes.${rewriteTail}`,
        detail: `the class requires a ${Math.trunc(check.restMinutes)}-minute rest (rule ${rule.id}) that the text does not state${statedRest !== null ? ` (it states ${Math.trunc(statedRest)} minutes)` : ""}`,
        currentText: step,
      });
    } else if (thermometer && internalTemps.length === 0) {
      found.push({
        kind: "missingInternalTemperature",
        ruleID: rule.id,
        phrase: "",
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead}.${rewriteTail}`,
        detail: "a thermometer is named but no internal temperature is stated — the check does not count without one",
        currentText: step,
      });
    } else if (!thermometer && internalTemps.length === 0 && (deviceTemps.length === 0 || !StepLinter.matches(DONENESS_CLAIM_PATTERN, lowered))) {
      found.push({
        kind: "missingInternalTemperature",
        ruleID: rule.id,
        phrase: "",
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead}.${rewriteTail}`,
        detail:
          deviceTemps.length === 0
            ? `the step cooks ${match.matchedKeyword} but states no thermometer, no internal temperature and no check of any kind`
            : `${deviceTemps[0]?.text ?? "an oven, pan or microwave temperature"} is not an internal reading — the step cooks ${match.matchedKeyword} with no thermometer-named check`,
        currentText: step,
      });
    }

    // Clause 4: an oven/pan/microwave temperature never counts as doneness.
    if (deviceTemps.length > 0 && StepLinter.matches(DONENESS_CLAIM_PATTERN, lowered) && !validCheck) {
      found.push({
        kind: "ovenTemperatureAsDoneness",
        ruleID: rule.id,
        phrase: deviceTemps[0]?.text ?? "",
        sourceAttribution: src.attribution,
        sourceURL: src.url,
        sourceQuote: src.quote,
        suggestedTempF: check.tempF,
        suggestedRewrite: `${rewriteHead} — the ${deviceTemps[0]?.text ?? "oven temperature"} decides nothing about doneness.${rewriteTail}`,
        detail: `${deviceTemps[0]?.text ?? "an oven/pan temperature"} is an oven, pan or microwave temperature — it never counts as an internal doneness check`,
        currentText: step,
      });
    }
    return found;
  }

  private attribution(rule: RuleData): { attribution: string; url: string; quote: string } {
    const citation = this.citations(rule)[0];
    return {
      attribution: citation !== undefined ? citationAttribution(citation) : "",
      url: citation?.url ?? "",
      quote: citation?.quotes[0] ?? "",
    };
  }

  // MARK: Clause 5 — structured safety metadata

  /** Verifies the record's structured safety field against the rulebook and the instruction text (clause 5). */
  private verifySafetyField(fieldData: string, step: string, textCheckValid: boolean): readonly LintFinding[] {
    const closed = (detail: string): LintFinding[] => [failClosedFinding(detail, step)];
    const record = parseSafetyField(fieldData);
    if (record === null) {
      return closed(`the record's structured safety field could not be parsed as {"class", "temp_f", "method", "source"} — the record is unparseable`);
    }
    if (!(FOOD_CLASSES as readonly string[]).includes(record.className)) {
      return closed(`the record's safety field names food class '${record.className}', which is not one of the eight FSIS classes — cannot verify, failing closed`);
    }
    const foodClass = FOOD_CLASSES.find((candidate) => candidate === record.className) as FoodClass;
    const rule = this.lookup?.rule(foodClass) ?? null;
    if (rule === null || rule.check === null) {
      return closed(`the rulebook defines no thermometer check for class ${record.className} — cannot verify, failing closed`);
    }
    const check = rule.check;
    if (record.method !== "thermometer") {
      return closed(`the record's safety field claims method '${record.method}' — only a thermometer check can count toward doneness`);
    }
    if (record.source.length === 0) {
      return closed("the record's safety field carries no source attribution");
    }
    const src = this.attribution(rule);
    if (record.tempF < check.tempF - 0.05) {
      return [
        {
          kind: "belowMinimumTemperature",
          ruleID: rule.id,
          phrase: "",
          sourceAttribution: src.attribution,
          sourceURL: src.url,
          sourceQuote: src.quote,
          suggestedTempF: check.tempF,
          suggestedRewrite: `Record the check as ${Math.trunc(check.tempC)} °C (${Math.trunc(check.tempF)} °F) on a food thermometer and show it in the instruction text — ${record.tempF} °F is below the ${record.className} minimum. (Source: ${src.attribution}, ${src.url}, retrieved ${this.book?.retrieved ?? ""})`,
          detail: `the record's safety field states ${record.tempF} °F for class ${record.className}, below the rulebook minimum ${Math.trunc(check.tempF)} °F (rule ${rule.id})`,
          currentText: step,
        },
      ];
    }
    // The metadata claims a valid thermometer check; the text must show it.
    if (!textCheckValid) {
      return [
        {
          kind: "metadataNotInText",
          ruleID: rule.id,
          phrase: "",
          sourceAttribution: src.attribution,
          sourceURL: src.url,
          sourceQuote: src.quote,
          suggestedTempF: check.tempF,
          suggestedRewrite: `Cook until ${check.placement ?? "the thickest part"} reaches ${Math.trunc(check.tempC)} °C (${Math.trunc(check.tempF)} °F) on a food thermometer${check.restMinutes > 0 ? `, then rest at least ${Math.trunc(check.restMinutes)} minutes` : ""} — write the check the record's safety field claims into the instruction text. (Source: ${src.attribution}, ${src.url}, retrieved ${this.book?.retrieved ?? ""})`,
          detail: `the record's safety field states class ${record.className} at ${record.tempF} °F by thermometer (source: ${record.source}), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass`,
          currentText: step,
        },
      ];
    }
    return [];
  }

  /** Whether the step text carries a check that counts (clauses 1–3) under the context's applicable rule. */
  private textHasValidCheck(step: string, context: StepContext): boolean {
    if (context.kind !== "cooking" && context.kind !== "reheating") {
      return false;
    }
    const check = context.match.rule.check;
    if (check === null) {
      return false;
    }
    const temps = parseTempMentions(step);
    const internalTemps = temps.filter((temp) => !temp.isDevice);
    const thermometer = StepLinter.matches(THERMOMETER_WORD_PATTERN, step.toLowerCase());
    const restRequired = check.restMinutes > 0;
    const statedRest = statedRestMinutes(step);
    return (
      thermometer &&
      internalTemps.length > 0 &&
      internalTemps.every((temp) => meetsMinimum(temp, check)) &&
      (!restRequired || (statedRest ?? 0) >= check.restMinutes)
    );
  }
}

function failClosedFinding(detail: string, step: string, ruleID = ""): LintFinding {
  return {
    kind: "failClosed",
    ruleID,
    phrase: "",
    sourceAttribution: "",
    sourceURL: "",
    sourceQuote: "",
    suggestedTempF: null,
    suggestedRewrite: "",
    detail,
    currentText: step,
  };
}

/** Splits "1. Do this\n2. Do that" style instructions into steps; continuation lines join the step they belong to. */
export function numberedSteps(instructions: string): readonly string[] {
  const steps: string[] = [];
  for (const rawLine of instructions.split(/\r\n|\n|\r/)) {
    const trimmed = rawLine.trim();
    if (trimmed.length === 0) {
      continue;
    }
    if (startsWithStepNumber(trimmed)) {
      steps.push(trimmed);
    } else if (steps.length > 0) {
      steps[steps.length - 1] += ` ${trimmed}`;
    }
  }
  return steps;
}

/** True when the line begins with a step number like "1." or "2)". */
function startsWithStepNumber(line: string): boolean {
  let index = 0;
  let digits = 0;
  while (index < line.length && line[index] >= "0" && line[index] <= "9") {
    index += 1;
    digits += 1;
  }
  if (digits === 0 || digits > 3) {
    return false;
  }
  return line[index] === "." || line[index] === ")";
}

// MARK: Temperature and rest parsing

/** Sentence pieces of a text: split after sentence enders and newlines. */
export function sentences(text: string): readonly string[] {
  return text
    .split(/[.!?\n]/)
    .map((sentence) => sentence.trim())
    .filter((sentence) => sentence.length > 0);
}

export function parseTempMentions(text: string): readonly TempMention[] {
  const mentions: TempMention[] = [];
  for (const sentence of sentences(text)) {
    const lowered = sentence.toLowerCase();
    const regex = new RegExp(TEMP_PATTERN, "gi");
    for (const match of lowered.matchAll(regex)) {
      const unitLetter = (match[3] ?? match[4] ?? "").toLowerCase();
      if (unitLetter.length === 0 || match[1] === undefined) {
        continue;
      }
      const first = Number.parseFloat(match[1].split(",").join("."));
      if (!Number.isFinite(first)) {
        continue;
      }
      const unit: TempMention["unit"] = unitLetter.startsWith("c") ? "celsius" : "fahrenheit";
      const bounds: number[] = [first];
      if (match[2] !== undefined) {
        const second = Number.parseFloat(match[2].split(",").join("."));
        if (Number.isFinite(second)) {
          bounds.push(second);
        }
      }
      const window = lowered.slice(0, (match.index ?? 0) + match[0].length);
      const isDevice = tempIsDevice(window, lowered);
      for (const value of bounds) {
        mentions.push({ value, unit, isDevice, text: match[0] });
      }
    }
  }
  return mentions;
}

/**
 * Attributes a temperature mention inside a sentence: the cue nearest the
 * temperature decides (a device cue earlier in the sentence does not turn
 * the stated temperature into a pan temperature); an uncued temperature is
 * read as the food's internal temperature (the fail-closed direction).
 */
function tempIsDevice(window: string, sentence: string): boolean {
  const strongDevice = "\\b(?:oven|preheat\\w*|oil|fat|pan|skillet|wok|frying|deep.?fry|air.?fry|fryer|microwave\\w*|slow.?cook\\w*|crock.?pot|pressure.?cook\\w*|sous.?vide|griddle|burner|hotplate|hob|dial)\\b";
  const weakDevice = "\\b(?:bake|bakes|baked|baking|roast|roasts|roasted|roasting|grill|grills|grilled|grilling|broil|broils|broiled|broiling|heat|heats|heated|heating)\\b";
  const internalCue = "\\b(?:internal temperature|internal temp|thermomet\\w+|instant[- ]read|probe|reads?|reading|registers?|registered?|reaches?|reached|insert\\w*|cook to|cooks to|cooked to|bring to|brought to|until (?:it|the|they)|centre|center|thickest|middle|thigh|wing|breast|joint|part|done)\\b";

  const cues: Array<{ device: boolean; end: number }> = [];
  const strongEnd = lastCueEnd(strongDevice, window);
  if (strongEnd !== null) {
    cues.push({ device: true, end: strongEnd });
  }
  const internalEnd = lastCueEnd(internalCue, window);
  if (internalEnd !== null) {
    cues.push({ device: false, end: internalEnd });
  }
  const weakEnd = lastCueEnd(weakDevice, window);
  if (weakEnd !== null) {
    cues.push({ device: true, end: weakEnd });
  }
  if (cues.length > 0) {
    const latest = cues.reduce((best, cue) => (cue.end > best.end ? cue : best));
    return latest.device;
  }
  // No cue before the temperature: an appliance word anywhere in the
  // sentence marks it; otherwise it is the food's internal temperature.
  return new RegExp(strongDevice, "i").test(sentence);
}

function lastCueEnd(pattern: string, text: string): number | null {
  const regex = new RegExp(pattern, "gi");
  let last: number | null = null;
  for (const match of text.matchAll(regex)) {
    last = (match.index ?? 0) + match[0].length;
  }
  return last;
}

/** Whether a stated internal temperature meets the rule's class minimum — each unit compares against the rulebook's own published pair. */
export function meetsMinimum(mention: TempMention, check: CheckData): boolean {
  return mention.unit === "fahrenheit" ? mention.value >= check.tempF - 0.05 : mention.value >= check.tempC - 0.05;
}

/** The rest time the step text states, in minutes (null when none). Rest and standing wording, digits or common number words. */
export function statedRestMinutes(text: string): number | null {
  // A rest word not preceded by "the " (which reads as "the rest of the
  // stock"), followed by a duration.
  const restWordPattern = "(?<!the )\\brest(?:s|ing|ed)?\\b|(?<!the )\\bstand(?:s|ing)?\\b";
  for (const match of text.matchAll(new RegExp(restWordPattern, "gi"))) {
    const upperBound = (match.index ?? 0) + match[0].length;
    const after = text.slice(upperBound, upperBound + 60);
    const duration = durationMinutes(after);
    if (duration !== null) {
      return duration;
    }
  }
  // Reversed: "3 minutes rest".
  const reversed = new RegExp("\\b(\\d+|one|two|three|four|five|ten|fifteen|twenty|thirty|forty[- ]?five)\\s*(?:minutes?|mins?|hours?|hrs?)\\b[^.]{0,20}\\brest", "i");
  const match = reversed.exec(text);
  if (match !== null && match[1] !== undefined) {
    const word = match[1].toLowerCase();
    const parsed = WORD_NUMBERS[word] ?? Number.parseFloat(word);
    // Swift's `Double(word) ?? 0`: an unparsable number word reads as 0.
    const value = Number.isFinite(parsed) ? parsed : 0;
    const isHours = /hours?|hrs?/i.test(match[0]);
    return isHours ? value * 60 : value;
  }
  return null;
}

function durationMinutes(text: string): number | null {
  const regex = /\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty[- ]?five)\s*(minutes?|mins?|hours?|hrs?)\b/i;
  const match = regex.exec(text);
  if (match === null || match[1] === undefined || match[2] === undefined) {
    return null;
  }
  const word = match[1].toLowerCase();
  const parsed = WORD_NUMBERS[word] ?? Number.parseFloat(word.split(",").join("."));
  if (!Number.isFinite(parsed)) {
    return 0;
  }
  const unit = match[2].toLowerCase();
  return unit.startsWith("h") ? parsed * 60 : parsed;
}

/** Parses the corpus safety field shape; returns null when unparseable (the caller fails closed). */
export function parseSafetyField(data: string): SafetyFieldRecord | null {
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch {
    return null;
  }
  if (!isRecord(raw)) {
    return null;
  }
  const allowed = new Set(["class", "temp_f", "method", "source"]);
  const keys = Object.keys(raw);
  if (keys.length !== allowed.size || keys.some((key) => !allowed.has(key))) {
    return null;
  }
  const className = readString(raw["class"]);
  const tempF = readNumber(raw["temp_f"]);
  const method = readString(raw["method"]);
  const source = readString(raw["source"]);
  if (className === null || tempF === null || method === null || source === null) {
    return null;
  }
  return { className, tempF, method, source };
}

// MARK: - CopyLint (CopyLint.swift)

export interface CopyRecord {
  readonly file: string;
  readonly recordID: string;
  readonly field: string;
  readonly text: string;
}

export interface CopyFinding {
  readonly file: string;
  readonly recordID: string;
  readonly field: string;
  /** The CopyLint pattern id (the banned-pattern row in COPY.md's table). */
  readonly patternID: string;
  /** A verbatim snippet of the flagged copy. */
  readonly currentText: string;
  /** The exact replacement copy, followed by the policy citation. */
  readonly requiredChange: string;
  /** The whole finding on one line: file · record id · field · current text · required change. */
  readonly canonicalLine: string;
}

export class CopyLintDecodeError extends Error {
  constructor(reason: string) {
    super(`copy-lint pattern data is invalid: ${reason}`);
    this.name = "CopyLintDecodeError";
  }
}

interface DecodedPattern {
  readonly id: string;
  readonly all: readonly (readonly string[])[];
  readonly except: readonly string[];
  readonly rewrite: string;
  readonly citationOrg: string;
  readonly citationTitle: string;
  readonly citationURL: string;
  readonly citationRetrieved: string;
  readonly citationQuote: string;
}

/** A pattern with its regexes compiled. */
interface CompiledPattern {
  readonly pattern: DecodedPattern;
  readonly all: readonly (readonly RegExp[])[];
  readonly except: readonly RegExp[];
}

function compilePatterns(patterns: readonly string[]): readonly RegExp[] {
  return patterns.map((pattern) => {
    try {
      return new RegExp(pattern, "i");
    } catch (error) {
      throw new CopyLintDecodeError(`invalid regex ${pattern}: ${error instanceof Error ? error.message : String(error)}`);
    }
  });
}

function copyPatternRequiredChange(pattern: DecodedPattern): string {
  return `Replace with: ${pattern.rewrite} (policy: ${pattern.id}; source: ${pattern.citationOrg} — ${pattern.citationTitle}; ${pattern.citationURL}; retrieved ${pattern.citationRetrieved}: "${pattern.citationQuote}")`;
}

/**
 * Flags spoilage and use-it-up phrasing the food-safety canon bans, and
 * proposes cited replacement copy. Matching model: a pattern fires when
 * every group in its `all` list matches somewhere in the record text
 * (case-insensitive) and no `except` regex matches the record.
 */
export class CopyLint {
  private readonly patterns: readonly CompiledPattern[];

  constructor(patternsData: string) {
    const decoded = CopyLint.decodePatternsData(patternsData);
    this.patterns = decoded.map((pattern) => ({
      pattern,
      all: pattern.all.map((group) => compilePatterns(group)),
      except: compilePatterns(pattern.except),
    }));
  }

  /** The pattern ids, in file order — the banned-pattern rows of COPY.md. */
  get patternIDs(): readonly string[] {
    return this.patterns.map((compiled) => compiled.pattern.id);
  }

  /** Scans the records and returns one finding per (record, pattern) hit, in record order then pattern order. */
  lint(records: readonly CopyRecord[]): readonly CopyFinding[] {
    const findings: CopyFinding[] = [];
    for (const record of records) {
      for (const compiled of this.patterns) {
        const snippet = CopyLint.firstSnippet(record, compiled);
        if (snippet === null) {
          continue;
        }
        const requiredChange = copyPatternRequiredChange(compiled.pattern);
        findings.push({
          file: record.file,
          recordID: record.recordID,
          field: record.field,
          patternID: compiled.pattern.id,
          currentText: snippet,
          requiredChange,
          canonicalLine: [record.file, record.recordID, record.field, snippet, requiredChange].join(" · "),
        });
      }
    }
    return findings;
  }

  /**
   * The snippet covering the matched claim, or null when the pattern does
   * not fire. Groups may match in different sentences, so the snippet spans
   * from the sentence holding the earliest group match to the sentence
   * holding the latest one — verbatim text, terminators kept.
   */
  private static firstSnippet(record: CopyRecord, compiled: CompiledPattern): string | null {
    const text = record.text;
    let spanStart = Number.MAX_SAFE_INTEGER;
    let spanEnd = 0;
    for (const group of compiled.all) {
      let groupMatched = false;
      for (const regex of group) {
        const match = regex.exec(text);
        if (match === null) {
          continue;
        }
        groupMatched = true;
        spanStart = Math.min(spanStart, match.index);
        spanEnd = Math.max(spanEnd, match.index + match[0].length);
      }
      if (!groupMatched) {
        return null;
      }
    }
    for (const guardRegex of compiled.except) {
      if (guardRegex.test(text)) {
        return null;
      }
    }
    return CopyLint.snippet(spanStart, spanEnd, text);
  }

  /** The verbatim text from the start of the sentence holding `from` to the end of the sentence holding `to` (terminators kept). */
  private static snippet(from: number, to: number, text: string): string {
    const terminators = new Set([".", "!", "?", "\n"]);
    let start = 0;
    for (let i = Math.min(from, text.length) - 1; i >= 0; i--) {
      if (terminators.has(text[i] as string)) {
        start = i + 1;
        break;
      }
    }
    let end = Math.min(Math.max(from, to), text.length);
    while (end < text.length) {
      if (terminators.has(text[end] as string)) {
        end += 1; // keep the terminator — the snippet stays verbatim
        break;
      }
      end += 1;
    }
    return text.slice(Math.min(start, text.length), Math.max(0, end)).trim();
  }

  private static decodePatternsData(patternsData: string): readonly DecodedPattern[] {
    let raw: unknown;
    try {
      raw = JSON.parse(patternsData);
    } catch (error) {
      throw new CopyLintDecodeError(`pattern data is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (!isRecord(raw)) {
      throw new CopyLintDecodeError("top level must be an object");
    }
    const doc = raw;
    CopyLint.checkKeys(doc, ["schema_version", "name", "retrieved", "policy_doc", "notes", "patterns"], "top level");
    if (doc["schema_version"] !== 1) {
      throw new CopyLintDecodeError(`schema_version must be 1 (the shipped policy is version 1); found: ${String(doc["schema_version"] ?? "missing")}`);
    }
    if (!Array.isArray(doc["patterns"])) {
      throw new CopyLintDecodeError("patterns must be an array of objects");
    }
    const patternEntries = doc["patterns"] as unknown[];
    if (patternEntries.length === 0) {
      throw new CopyLintDecodeError("patterns must not be empty — an empty set would silently narrow the policy");
    }
    const topRetrieved = readString(doc["retrieved"]);
    if (topRetrieved === null || topRetrieved.length === 0) {
      throw new CopyLintDecodeError("top-level retrieved is missing or empty");
    }
    CopyLint.checkDate(topRetrieved, "top-level retrieved");

    const decoded: DecodedPattern[] = [];
    const seenIDs = new Set<string>();
    for (const [index, entryRaw] of patternEntries.entries()) {
      const what = `pattern ${index}`;
      if (!isRecord(entryRaw)) {
        throw new CopyLintDecodeError(`${what} must be an object`);
      }
      const entry = entryRaw;
      CopyLint.checkKeys(entry, ["id", "all", "except", "rewrite", "citation"], what);
      const id = readString(entry["id"]);
      if (id === null || id.length === 0) {
        throw new CopyLintDecodeError(`${what}: id is missing or empty`);
      }
      if (seenIDs.has(id)) {
        throw new CopyLintDecodeError(`${what}: duplicate id ${id}`);
      }
      seenIDs.add(id);

      const allRaw = entry["all"];
      if (!Array.isArray(allRaw) || allRaw.length === 0 || allRaw.length > 4) {
        throw new CopyLintDecodeError(`${what}: all must be an array of 1–4 groups`);
      }
      const groups: string[][] = [];
      for (const [groupIndex, groupRaw] of allRaw.entries()) {
        const regexes = readStringArray(groupRaw);
        if (regexes === null || regexes.length === 0 || regexes.length > 12) {
          throw new CopyLintDecodeError(`${what}: group ${groupIndex} must be an array of 1–12 regex strings`);
        }
        compilePatterns(regexes); // throws on an invalid regex
        groups.push(regexes);
      }

      let except: string[] = [];
      const exceptRaw = entry["except"];
      if (exceptRaw !== undefined && exceptRaw !== null) {
        const regexes = readStringArray(exceptRaw);
        if (regexes === null || regexes.length === 0) {
          throw new CopyLintDecodeError(`${what}: except must be an array of regex strings when present`);
        }
        compilePatterns(regexes);
        except = regexes;
      }

      const rewrite = readString(entry["rewrite"]);
      if (rewrite === null || rewrite.length === 0) {
        throw new CopyLintDecodeError(`${what}: rewrite is missing or empty — every banned pattern carries its exact replacement copy`);
      }

      const citation = entry["citation"];
      if (!isRecord(citation)) {
        throw new CopyLintDecodeError(`${what}: citation is missing`);
      }
      CopyLint.checkKeys(citation, ["id", "org", "title", "url", "retrieved", "quote"], `${what} citation`);
      for (const field of ["id", "org", "title", "url", "retrieved", "quote"]) {
        const value = readString(citation[field]);
        if (value === null || value.length === 0) {
          throw new CopyLintDecodeError(`${what}: citation.${field} is missing or empty`);
        }
      }
      const quote = readString(citation["quote"]);
      if (quote === null || quote.length < 20) {
        throw new CopyLintDecodeError(`${what}: citation.quote too short to be verbatim`);
      }
      const url = readString(citation["url"]);
      if (url === null || !url.startsWith("https://")) {
        throw new CopyLintDecodeError(`${what}: citation.url must be https`);
      }
      CopyLint.checkDate(readString(citation["retrieved"]) ?? "", `${what} citation.retrieved`);

      decoded.push({
        id,
        all: groups,
        except,
        rewrite,
        citationOrg: readString(citation["org"]) ?? "",
        citationTitle: readString(citation["title"]) ?? "",
        citationURL: readString(citation["url"]) ?? "",
        citationRetrieved: readString(citation["retrieved"]) ?? "",
        citationQuote: readString(citation["quote"]) ?? "",
      });
    }
    return decoded;
  }

  private static checkKeys(dict: Record<string, unknown>, allowed: readonly string[], what: string): void {
    const allowedSet = new Set(allowed);
    const unknown = Object.keys(dict)
      .filter((key) => !allowedSet.has(key))
      .sort();
    if (unknown.length > 0) {
      throw new CopyLintDecodeError(`${what}: unknown key(s) ${unknown.join(", ")} — extend the decoder before extending the file`);
    }
  }

  private static checkDate(value: string, what: string): void {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
      throw new CopyLintDecodeError(`${what}: retrieval date must be YYYY-MM-DD, found: ${value}`);
    }
  }
}

// MARK: - Records format (RecordsFormat.swift — the fl-safety-lint input shape)

export interface RecipeRecordInput {
  readonly kind: "recipe";
  readonly file: string;
  readonly id: string;
  readonly title: string;
  readonly ingredients: string;
  readonly instructions: string;
  /** Zero-based step index → the record's structured safety field (raw JSON). */
  readonly safetyFields: ReadonlyMap<number, string>;
}

export interface CopyRecordInput {
  readonly kind: "copy";
  readonly file: string;
  readonly id: string;
  readonly field: string;
  readonly text: string;
}

export type LintInputRecord = RecipeRecordInput | CopyRecordInput;

export class RecordsFormatError extends Error {
  constructor(message: string) {
    super(`records format error: ${message}`);
    this.name = "RecordsFormatError";
  }
}

const RECORDS_TOP_LEVEL_KEYS = ["schema_version", "description", "records"] as const;
const RECORDS_RECORD_KEYS = ["kind", "file", "id", "title", "ingredients", "instructions", "safety_fields", "field", "text"] as const;
const RECORDS_RECIPE_KEYS = ["kind", "file", "id", "title", "ingredients", "instructions", "safety_fields"] as const;
const RECORDS_COPY_KEYS = ["kind", "file", "id", "field", "text"] as const;

function decodeSafetyFields(raw: unknown, what: string): ReadonlyMap<number, string> {
  if (raw === undefined || raw === null) {
    return new Map();
  }
  if (!isRecord(raw)) {
    throw new RecordsFormatError(`${what}: safety_fields must be an object mapping step indices to safety-field objects`);
  }
  const fields = new Map<number, string>();
  for (const [key, value] of Object.entries(raw)) {
    const index = Number.parseInt(key, 10);
    if (!Number.isInteger(index) || index < 0 || String(index) !== key) {
      throw new RecordsFormatError(`${what}: safety_fields key '${key}' is not a zero-based step index`);
    }
    if (!isRecord(value)) {
      throw new RecordsFormatError(`${what}: safety_fields['${key}'] must be an object`);
    }
    fields.set(index, JSON.stringify(value));
  }
  return fields;
}

/** Decodes one record object, strictly failing closed on any shape it does not recognise. */
export function decodeRecord(raw: unknown, what: string): LintInputRecord {
  if (!isRecord(raw)) {
    throw new RecordsFormatError(`${what} must be an object`);
  }
  {
    const issues: string[] = [];
    checkKeys(raw, RECORDS_RECORD_KEYS, what, issues);
    if (issues.length > 0) {
      throw new RecordsFormatError(issues[0]);
    }
  }
  const kind = readString(raw["kind"]);
  if (kind === null) {
    throw new RecordsFormatError(`${what}: kind is missing (must be "recipe" or "copy")`);
  }
  const file = readString(raw["file"]);
  const id = readString(raw["id"]);
  if (file === null || file.length === 0 || id === null || id.length === 0) {
    throw new RecordsFormatError(`${what}: file and id must be non-empty strings`);
  }

  if (kind === "recipe") {
    {
      const issues: string[] = [];
      checkKeys(raw, RECORDS_RECIPE_KEYS, `${what} (recipe)`, issues);
      if (issues.length > 0) {
        throw new RecordsFormatError(issues[0]);
      }
    }
    const instructions = readString(raw["instructions"]);
    if (instructions === null || instructions.length === 0) {
      throw new RecordsFormatError(`${what}: instructions is missing or empty`);
    }
    const safetyFields = decodeSafetyFields(raw["safety_fields"], what);
    return {
      kind: "recipe",
      file,
      id,
      title: readString(raw["title"]) ?? "",
      ingredients: readString(raw["ingredients"]) ?? "",
      instructions,
      safetyFields,
    };
  }

  if (kind === "copy") {
    {
      const issues: string[] = [];
      checkKeys(raw, RECORDS_COPY_KEYS, `${what} (copy)`, issues);
      if (issues.length > 0) {
        throw new RecordsFormatError(issues[0]);
      }
    }
    const field = readString(raw["field"]);
    const text = readString(raw["text"]);
    if (field === null || field.length === 0 || text === null || text.length === 0) {
      throw new RecordsFormatError(`${what}: field and text must be non-empty strings`);
    }
    return { kind: "copy", file, id, field, text };
  }

  throw new RecordsFormatError(`${what}: unknown kind '${kind}' (must be "recipe" or "copy")`);
}

/** Decodes a whole records file: {"schema_version": 1, "description": …, "records": […]}. */
export function decodeRecords(data: string): readonly LintInputRecord[] {
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch (error) {
    throw new RecordsFormatError(`records file is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!isRecord(raw)) {
    throw new RecordsFormatError("records file top level must be an object");
  }
  const issues: string[] = [];
  checkKeys(raw, RECORDS_TOP_LEVEL_KEYS, "records file top level", issues);
  if (issues.length > 0) {
    throw new RecordsFormatError(issues[0]);
  }
  if (raw["schema_version"] !== 1) {
    throw new RecordsFormatError(`schema_version must be 1, found: ${String(raw["schema_version"] ?? "missing")}`);
  }
  if (!Array.isArray(raw["records"])) {
    throw new RecordsFormatError("records must be an array");
  }
  return raw["records"].map((record, index) => decodeRecord(record, `records[${index}]`));
}

// MARK: - LintRunner (LintRunner.swift)

/** One canon finding on either surface, wrapped so the renderer and the format checks stay on the canon format. */
export interface CanonFinding {
  /** "step" or "copy" — which linter emitted the finding. */
  readonly surface: "step" | "copy";
  /** The finding class: a LintFinding kind for step findings, the CopyLint pattern id for copy findings. */
  readonly kindName: string;
  /** The canon-format line, prefixed with the kind for grep-ability. */
  readonly line: string;
  readonly ruleID: string;
  readonly patternID: string | null;
  readonly suggestedRewrite: string;
  readonly detail: string;
  readonly isFailClosedOrReview: boolean;
}

export class LintDriverError extends Error {
  constructor(message: string) {
    super(`fl-safety-lint: ${message}`);
    this.name = "LintDriverError";
  }
}

function canonFindingFromStep(finding: LintFinding, file: string, recordID: string, field: string): CanonFinding {
  return {
    surface: "step",
    kindName: finding.kind,
    line: findingLine(finding, file, recordID, field),
    ruleID: finding.ruleID,
    patternID: null,
    suggestedRewrite: finding.suggestedRewrite,
    detail: finding.detail,
    isFailClosedOrReview: finding.kind === "failClosed" || finding.kind === "flagForReview",
  };
}

function canonFindingFromCopy(finding: CopyFinding): CanonFinding {
  return {
    surface: "copy",
    kindName: finding.patternID,
    line: `[${finding.patternID}] ${finding.canonicalLine}`,
    ruleID: "",
    patternID: finding.patternID,
    suggestedRewrite: finding.requiredChange,
    detail: "",
    isFailClosedOrReview: false,
  };
}

/**
 * Runs the package linters over decoded records. The runner holds no lint
 * rules and no phrasing knowledge: everything it reports comes from
 * `StepLinter.findingsForRecipe` or `CopyLint.lint`.
 */
export function lintRecords(
  records: readonly LintInputRecord[],
  rulebookData: string | null,
  patternsData: string | null,
): { recordCount: number; findings: readonly CanonFinding[] } {
  const stepLinter = new StepLinter(rulebookData === null ? null : decodeRulebookStrictOrNull(rulebookData));
  const needsPatterns = records.some((record) => record.kind === "copy");
  let copyLint: CopyLint | null = null;
  if (needsPatterns) {
    if (patternsData === null) {
      throw new LintDriverError("the records contain copy records but no copy-lint pattern data is available — pass --patterns <copy-lint-patterns.json>");
    }
    try {
      copyLint = new CopyLint(patternsData);
    } catch (error) {
      throw new LintDriverError(`the copy-lint pattern data could not be loaded: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  const findings: CanonFinding[] = [];
  for (const record of records) {
    if (record.kind === "recipe") {
      for (const row of stepLinter.findingsForRecipe(record.title, record.ingredients, record.instructions, record.safetyFields)) {
        for (const finding of row.findings) {
          findings.push(canonFindingFromStep(finding, record.file, record.id, `instructions[${row.stepIndex + 1}]`));
        }
      }
    } else if (copyLint !== null) {
      for (const finding of copyLint.lint([{ file: record.file, recordID: record.id, field: record.field, text: record.text }])) {
        findings.push(canonFindingFromCopy(finding));
      }
    }
  }
  return { recordCount: records.length, findings };
}

/**
 * The Swift StepLinter(rulebookData:) contract: nil or undecodable rules
 * data produce a fail-closed linter (clause 7), not a throw. The undecodable
 * branch reports through findings; a decodable-but-invalid rulebook also
 * fails closed with the decode issues.
 */
function decodeRulebookStrictOrNull(rulebookData: string): RulebookData | null {
  try {
    return decodeRulebook(rulebookData);
  } catch {
    // Mirrors Swift's init(rulebookData:) failure path: the linter reports
    // the failure as a failClosed finding per query. The failure reason is
    // carried by constructing a failed linter below.
    return null;
  }
}

// MARK: - ConformanceKit (ConformanceKit.swift)

export interface ConformanceCaseResult {
  readonly caseID: string;
  readonly sourceFile: string;
  readonly ok: boolean;
  readonly actualKinds: readonly string[];
  readonly problems: readonly string[];
}

export interface ConformanceReport {
  readonly caseResults: readonly ConformanceCaseResult[];
  /** Canon-coverage problems: the clean replay must produce zero findings. */
  readonly replayProblems: readonly string[];
  /** Canon-coverage gaps: finding kinds or copy patterns no case pins. */
  readonly coverageProblems: readonly string[];
  readonly failedCases: number;
  readonly passedCases: number;
  readonly ok: boolean;
}

export class ConformanceContentError extends Error {
  constructor(message: string) {
    super(`conformance kit error: ${message}`);
    this.name = "ConformanceContentError";
  }
}

interface KitCase {
  readonly id: string;
  readonly sourceFile: string;
  readonly record: LintInputRecord;
  /** null = use the default rulebook; "missing" = no rulebook; string = deliberately broken inline JSON. */
  readonly rulesOverride: { readonly type: "default" } | { readonly type: "missing" } | { readonly type: "data"; readonly data: string };
  readonly expectedKinds: readonly string[];
  readonly expectedRuleID: string | null;
  readonly rewriteContains: readonly string[];
  readonly detailContains: readonly string[];
}

const CONFORMANCE_CASE_FILE_TOP_KEYS = ["schema_version", "name", "description", "cases"] as const;
const CONFORMANCE_CASE_KEYS = ["id", "record", "rules", "expect"] as const;
const CONFORMANCE_EXPECT_KEYS = ["kinds", "rule_id", "rewrite_contains", "detail_contains"] as const;

function decodeCaseFile(data: string, sourceFile: string): readonly KitCase[] {
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch (error) {
    throw new ConformanceContentError(`${sourceFile} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!isRecord(raw)) {
    throw new ConformanceContentError(`${sourceFile} top level must be an object`);
  }
  const doc = raw;
  {
    const issues: string[] = [];
    checkKeys(doc, CONFORMANCE_CASE_FILE_TOP_KEYS, sourceFile, issues);
    if (issues.length > 0) {
      throw new ConformanceContentError(`${sourceFile}: ${issues[0].split(": ").slice(1).join(": ")}`);
    }
  }
  if (doc["schema_version"] !== 1) {
    throw new ConformanceContentError(`${sourceFile}: schema_version must be 1, found: ${String(doc["schema_version"] ?? "missing")}`);
  }
  if (!Array.isArray(doc["cases"]) || doc["cases"].length === 0) {
    throw new ConformanceContentError(`${sourceFile}: cases must be a non-empty array`);
  }
  return doc["cases"].map((item, index) => decodeCase(item, sourceFile, `cases[${index}]`));
}

function decodeCase(raw: unknown, sourceFile: string, what: string): KitCase {
  if (!isRecord(raw)) {
    throw new ConformanceContentError(`${sourceFile} ${what} must be an object`);
  }
  const dict = raw;
  {
    const issues: string[] = [];
    checkKeys(dict, CONFORMANCE_CASE_KEYS, `${sourceFile} ${what}`, issues);
    if (issues.length > 0) {
      throw new ConformanceContentError(`${sourceFile} ${what}: ${issues[0].split(": ").slice(1).join(": ")}`);
    }
  }
  const id = readString(dict["id"]);
  if (id === null || id.length === 0) {
    throw new ConformanceContentError(`${sourceFile} ${what}: id is missing or empty`);
  }
  if (dict["record"] === undefined) {
    throw new ConformanceContentError(`${sourceFile} ${what}: record is missing`);
  }
  const record = decodeRecord(dict["record"], `${sourceFile} ${what}.record`);

  let rulesOverride: KitCase["rulesOverride"];
  const rulesRaw = dict["rules"];
  if (rulesRaw === undefined) {
    // Absent: run against the vendored rulebook.
    rulesOverride = { type: "default" };
  } else if (rulesRaw === null) {
    // Explicit null: the missing-rulebook fail-closed marker (see the
    // conformance README's case schema).
    rulesOverride = { type: "missing" };
  } else if (typeof rulesRaw === "string") {
    rulesOverride = { type: "data", data: rulesRaw };
  } else {
    throw new ConformanceContentError(`${sourceFile} ${what}: rules must be null (missing rulebook) or a string of deliberately broken JSON`);
  }

  const expect = dict["expect"];
  if (!isRecord(expect)) {
    throw new ConformanceContentError(`${sourceFile} ${what}: expect is missing (declare the finding kinds the case must produce)`);
  }
  {
    const issues: string[] = [];
    checkKeys(expect, CONFORMANCE_EXPECT_KEYS, `${sourceFile} ${what}`, issues);
    if (issues.length > 0) {
      throw new ConformanceContentError(`${sourceFile} ${what}: ${issues[0].split(": ").slice(1).join(": ")}`);
    }
  }
  const kinds = readStringArray(expect["kinds"]);
  if (kinds === null) {
    throw new ConformanceContentError(`${sourceFile} ${what}: expect.kinds must be an array of finding-kind strings`);
  }
  if (record.kind !== "copy") {
    for (const kind of kinds) {
      if (!(FINDING_KINDS as readonly string[]).includes(kind)) {
        throw new ConformanceContentError(`${sourceFile} ${what}: unknown finding kind '${kind}'`);
      }
    }
  }
  const rewriteContains = readStringArray(expect["rewrite_contains"]) ?? [];
  const detailContains = readStringArray(expect["detail_contains"]) ?? [];
  return {
    id,
    sourceFile,
    record,
    rulesOverride,
    expectedKinds: kinds,
    expectedRuleID: readString(expect["rule_id"]),
    rewriteContains,
    detailContains,
  };
}

function runCase(
  kitCase: KitCase,
  rulebookData: string | null,
  patternsData: string | null,
): ConformanceCaseResult {
  const problems: string[] = [];
  let actualKinds: readonly string[] = [];
  let findings: readonly CanonFinding[] = [];

  if (kitCase.record.kind === "recipe") {
    let overrideData: string | null;
    switch (kitCase.rulesOverride.type) {
      case "default":
        overrideData = rulebookData;
        break;
      case "missing":
        overrideData = null;
        break;
      case "data":
        overrideData = kitCase.rulesOverride.data;
        break;
    }
    // The fail-closed linter construction: undecodable override data fails
    // closed with a finding carrying the decode reason, exactly like the
    // Swift failable init.
    const linter = overrideData === null ? new StepLinter(null) : stepLinterWithOverride(overrideData);
    const kinds: string[] = [];
    const wrapped: CanonFinding[] = [];
    for (const row of linter.findingsForRecipe(kitCase.record.title, kitCase.record.ingredients, kitCase.record.instructions, kitCase.record.safetyFields)) {
      for (const finding of row.findings) {
        kinds.push(finding.kind);
        wrapped.push(canonFindingFromStep(finding, kitCase.record.file, kitCase.record.id, `instructions[${row.stepIndex + 1}]`));
      }
    }
    actualKinds = kinds;
    findings = wrapped;
  } else {
    if (patternsData === null) {
      return {
        caseID: kitCase.id,
        sourceFile: kitCase.sourceFile,
        ok: false,
        actualKinds: [],
        problems: ["copy case but no pattern data available"],
      };
    }
    let copyLint: CopyLint;
    try {
      copyLint = new CopyLint(patternsData);
    } catch (error) {
      return {
        caseID: kitCase.id,
        sourceFile: kitCase.sourceFile,
        ok: false,
        actualKinds: [],
        problems: [`copy-lint pattern data could not be loaded: ${error instanceof Error ? error.message : String(error)}`],
      };
    }
    const found = copyLint.lint([{ file: kitCase.record.file, recordID: kitCase.record.id, field: kitCase.record.field, text: kitCase.record.text }]);
    actualKinds = found.map((finding) => finding.patternID);
    findings = found.map(canonFindingFromCopy);
  }

  // Exact kind sequence — the pin.
  if (actualKinds.join("\u0000") !== kitCase.expectedKinds.join("\u0000")) {
    problems.push(`expected kinds ${JSON.stringify(kitCase.expectedKinds)}, got ${JSON.stringify(actualKinds)}`);
  }
  // Rule id of a single finding.
  if (kitCase.expectedRuleID !== null && findings.length === 1 && findings[0].ruleID !== kitCase.expectedRuleID) {
    problems.push(`expected rule id '${kitCase.expectedRuleID}', got '${findings[0].ruleID}'`);
  }
  // The rewrite carries the declared substrings.
  for (const needle of kitCase.rewriteContains) {
    const joined = findings.map((finding) => finding.suggestedRewrite).join(" ");
    if (!joined.includes(needle)) {
      problems.push(`no finding rewrite contains '${needle}'`);
    }
  }
  // The detail carries the declared substrings (fail-closed / review).
  for (const needle of kitCase.detailContains) {
    const joined = findings.map((finding) => finding.detail).join(" ");
    if (!joined.includes(needle)) {
      problems.push(`no finding detail contains '${needle}'`);
    }
  }
  // Universal finding format: every finding cites a rule id (or policy id)
  // plus citation and carries one exact rewrite; review and fail-closed
  // findings state what is missing instead.
  for (const finding of findings) {
    if (finding.isFailClosedOrReview) {
      if (finding.detail.length === 0) {
        problems.push(`finding '${finding.kindName}' must state what is missing or what a reviewer must decide (empty detail)`);
      }
    } else if (finding.patternID !== null) {
      const change = finding.suggestedRewrite;
      if (!(change.includes("(policy: ") && change.includes("retrieved "))) {
        problems.push(`copy finding '${finding.patternID}' does not cite its policy and source`);
      }
    } else {
      if (finding.ruleID.length === 0) {
        problems.push(`finding '${finding.kindName}' carries no rule id`);
      }
      if (finding.suggestedRewrite.length === 0) {
        problems.push(`finding '${finding.kindName}' carries no exact rewrite`);
      }
      const line = finding.line;
      if (!line.includes("source:") || !line.includes("retrieved")) {
        problems.push(`finding '${finding.kindName}' does not cite a source (rule id + citation required)`);
      }
    }
  }

  return {
    caseID: kitCase.id,
    sourceFile: kitCase.sourceFile,
    ok: problems.length === 0,
    actualKinds,
    problems,
  };
}

/**
 * The StepLinter(rulebookData:) port for case overrides: undecodable data
 * constructs the fail-closed linter (clause 7) whose findings carry the
 * decode reason instead of throwing.
 */
function stepLinterWithOverride(rulebookData: string): StepLinter {
  try {
    return new StepLinter(decodeRulebook(rulebookData));
  } catch (error) {
    return new StepLinter(null, `the rulebook could not be decoded: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * Runs the kit. `files` maps vendored file NAMES (relative to the
 * conformance directory) to their contents — `cases-*.json` (name-sorted),
 * `true-negatives.json`, `replay-clean.json`. `rulebookData` and
 * `patternsData` are the default data (case-level overrides replace them
 * per case).
 */
export function runConformanceKit(
  files: Readonly<Record<string, string>>,
  rulebookData: string | null,
  patternsData: string,
): ConformanceReport {
  const replayProblems: string[] = [];
  const coverageProblems: string[] = [];

  const caseFileNames = Object.keys(files)
    .filter((name) => name.startsWith("cases-") && name.endsWith(".json"))
    .sort();
  if (caseFileNames.length === 0) {
    replayProblems.push(`no cases-*.json case files found — the kit covers nothing`);
  }

  const cases: KitCase[] = [];
  const copyPatternExpectations: string[] = [];
  for (const fileName of caseFileNames) {
    for (const kitCase of decodeCaseFile(files[fileName] as string, fileName)) {
      if (kitCase.record.kind === "copy") {
        copyPatternExpectations.push(...kitCase.expectedKinds);
      }
      cases.push(kitCase);
    }
  }

  // True negatives: cases whose expect is an empty kinds list.
  const trueNegatives = files["true-negatives.json"];
  if (trueNegatives !== undefined) {
    cases.push(...decodeCaseFile(trueNegatives, "true-negatives.json"));
  } else {
    replayProblems.push("the kit is missing true-negatives.json — true negatives must be pinned");
  }

  const caseResults = cases.map((kitCase) => runCase(kitCase, rulebookData, patternsData));

  // Clean replay: the records-shaped file must produce zero findings.
  const replay = files["replay-clean.json"];
  if (replay !== undefined) {
    let records: readonly LintInputRecord[];
    try {
      records = decodeRecords(replay);
    } catch (error) {
      throw new ConformanceContentError(`replay-clean.json: ${error instanceof Error ? error.message : String(error)}`);
    }
    const run = lintRecords(records, rulebookData, patternsData);
    for (const finding of run.findings) {
      replayProblems.push(`clean replay produced a finding (must be zero): ${finding.line}`);
    }
  } else {
    replayProblems.push("the kit is missing replay-clean.json — the clean replay must be pinned");
  }

  // Coverage: every finding kind the package can emit, and every copy
  // pattern in the loaded pattern file, must be pinned by some case.
  const expected = new Set(cases.flatMap((kitCase) => [...kitCase.expectedKinds]));
  for (const kind of FINDING_KINDS) {
    if (!expected.has(kind)) {
      coverageProblems.push(`the kit never pins finding kind '${kind}' — add a case to cases-*.json or true-negatives.json`);
    }
  }
  const livePatterns = new CopyLint(patternsData).patternIDs;
  for (const pattern of livePatterns) {
    if (!copyPatternExpectations.includes(pattern)) {
      coverageProblems.push(`the kit never pins copy pattern '${pattern}' — add a case to cases-copy-lint.json`);
    }
  }

  const failedCases = caseResults.filter((result) => !result.ok).length;
  return {
    caseResults,
    replayProblems,
    coverageProblems,
    failedCases,
    passedCases: caseResults.length - failedCases,
    ok: failedCases === 0 && replayProblems.length === 0 && coverageProblems.length === 0,
  };
}
