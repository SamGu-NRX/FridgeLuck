/**
 * Camera-observation lint (SPEC 3.1, binding): a camera look describes what a
 * picture can show — browning, size, consistency — and says what it cannot
 * assess. It never gives a safety verdict.
 *
 * The phone-supplied observation strings are free text, so nothing structurally
 * stops a capture from including "chicken is safe to eat". This lint refuses
 * such language at the reads path: verdict-shaped observations are treated as
 * a contract violation and fail closed (never silently relayed, never silently
 * stripped). Detection is a closed list of verdict phrases PLUS two
 * construction classes (verb+verdict co-occurrence like "looks safe"/"is
 * done", and temperature+safety-predicate co-occurrence) — still deliberately
 * narrow, not a general verdict detector: visual descriptions like
 * "golden-brown", "about 2 cm thick", or "cheese melted evenly" pass; verdict
 * constructions fail.
 */

/** One refused observation: what it said and which verdict construction it matched. */
export interface CameraLintFinding {
  readonly observation: string;
  readonly pattern: string;
  readonly reason: string;
}

/**
 * Verdict-shaped constructions, as a closed list with rationale per entry.
 * Each entry is a case-insensitive substring match.
 */
const VERDICT_PATTERNS: readonly { pattern: string; reason: string }[] = [
  { pattern: "safe to eat", reason: "declares the food safe to eat" },
  { pattern: "unsafe to eat", reason: "declares the food unsafe to eat" },
  { pattern: "safe for consumption", reason: "declares the food safe for consumption" },
  { pattern: "edible", reason: "declares the food edible" },
  { pattern: "cooked through", reason: "issues a doneness verdict" },
  { pattern: "fully cooked", reason: "issues a doneness verdict" },
  { pattern: "undercooked", reason: "issues a doneness verdict" },
  { pattern: "overcooked to unsafe", reason: "issues a safety verdict" },
  { pattern: "not spoiled", reason: "issues a spoilage verdict" },
  { pattern: "is spoiled", reason: "issues a spoilage verdict" },
  { pattern: "no signs of spoilage", reason: "issues a spoilage verdict" },
  { pattern: "no signs of bacteria", reason: "issues a microbial-safety verdict" },
  { pattern: "done cooking", reason: "issues a doneness verdict" },
  { pattern: "it is done", reason: "issues a doneness verdict" },
  { pattern: "ready to eat", reason: "issues a consumption-readiness verdict" },
  { pattern: "safe to consume", reason: "declares the food safe to consume" },
  { pattern: "fit to eat", reason: "declares the food fit to eat" },
  { pattern: "no longer pink", reason: "issues a doneness verdict by colour" }
];

/**
 * Verb + verdict co-occurrence: "looks safe", "is done", "seems cooked",
 * "smells spoiled" — a linking verb asserting a verdict about the food.
 * Broader than any closed list, narrower than description ("browning",
 * "melted evenly", "about 2 cm thick" never match).
 */
const VERDICT_CONSTRUCTION_RE = /\b(?:is|looks|seems|smells)\s+(?:done|safe|edible|cooked|spoiled|bad|ready)\b/i;

/**
 * A temperature reading inside an observation is measurement, not verdict —
 * UNLESS it is combined with a safety predicate ("internal temperature is
 * 74 C so it is safe"). Those co-occurrences are refused even though neither
 * half alone would be.
 */
const TEMPERATURE_RE = /internal temperature|core temperature|\d+\s*(?:°|degrees)\s*c\b|fahrenheit|\d+\s*(?:°|degrees)\s*f\b/i;
const SAFETY_PREDICATE_RE = /\bsafe\b|\bunsafe\b|\bhostile\b|free of (?:bacteria|pathogens)|no (?:bacteria|pathogens)|bacteria (?:is|are) (?:dead|gone|killed)/i;

/** Lint the free-text observations of one camera look. Empty result = clean. */
export function lintCameraObservations(observed: readonly string[]): CameraLintFinding[] {
  const findings: CameraLintFinding[] = [];
  for (const observation of observed) {
    const lowered = observation.toLowerCase();
    const matched = VERDICT_PATTERNS.find(({ pattern }) => lowered.includes(pattern));
    if (matched) {
      findings.push({ observation, pattern: matched.pattern, reason: `camera observation ${matched.reason} (SPEC 3.1 forbids safety verdicts)` });
      continue;
    }
    if (VERDICT_CONSTRUCTION_RE.test(observation)) {
      findings.push({
        observation,
        pattern: "verb + verdict construction",
        reason: "camera observation asserts a verdict through a linking verb (is/looks/seems/smells + done/safe/edible/cooked/spoiled/bad/ready) — SPEC 3.1 forbids safety verdicts"
      });
      continue;
    }
    if (TEMPERATURE_RE.test(observation) && SAFETY_PREDICATE_RE.test(observation)) {
      findings.push({
        observation,
        pattern: "temperature + safety predicate",
        reason: "camera observation combines a temperature reading with a safety predicate — a temperature-safety verdict (SPEC 3.1 forbids safety verdicts)"
      });
    }
  }
  return findings;
}

/** Thrown when a camera capture carries verdict language: the reads path refuses to relay it. */
export class CameraLintError extends Error {
  readonly findings: readonly CameraLintFinding[];

  constructor(findings: readonly CameraLintFinding[]) {
    super(
      `camera observation lint refused ${findings.length} safety-verdict finding(s) (SPEC 3.1: a camera look never gives a safety verdict): ` +
        findings.map((f) => `"${f.observation}" — ${f.reason}`).join("; ")
    );
    this.name = "CameraLintError";
    this.findings = findings;
  }
}
