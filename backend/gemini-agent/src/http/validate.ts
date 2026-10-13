import type {
  ConfidenceAssessRequest,
  ConfidenceOutcomeRequest,
  NotificationPlanRequest,
  RecipeGenerationRequest,
  ReverseScanRankRequest
} from "../types/contracts.js";
import { PHOTO_BASE64_MAX_CHARS } from "./limits.js";
import { RequestValidationError } from "./errors.js";

// Strict request validation for the HTTP surface, derived from the actual
// contracts in src/types/contracts.ts and the wire behavior of the iOS client:
//   - confidences and scores arrive as doubles in [0, 1] (the client clamps);
//   - ids and counts arrive as integers;
//   - dates arrive as ISO 8601 (date-only or full timestamps, both occur);
//   - locales arrive as `Locale.current.identifier`, e.g. "en_US" — dashes do
//     NOT appear on the wire, so a charset check (not Intl.Locale) is used;
//   - timezones arrive as `TimeZone.current.identifier` (IANA names).
//
// Validation NARROWS the payload: unknown fields are dropped here and are
// never forwarded toward prompts. Every failure throws a RequestValidationError
// carrying a static field path — never a value from the request.
//
// Array/string bounds are deliberately generous relative to the app client
// (services already slice their prompts) so this only rejects hostile or
// broken traffic, not legitimate clients.

// ─── Bounds ──────────────────────────────────────────────────────────────────

const NAME_MAX_CHARS = 120;
const TITLE_MAX_CHARS = 200;
const REASON_MAX_CHARS = 200;
const ID_MAX_CHARS = 128;
const TOKEN_MAX_CHARS = 256;
const DATE_MAX_CHARS = 40;

const INGREDIENT_NAMES_MAX_ITEMS = 64;
const TAG_LIST_MAX_ITEMS = 32;
const AVOID_LIST_MAX_ITEMS = 64;
const DETECTIONS_MAX_ITEMS = 100;
const CANDIDATES_MAX_ITEMS = 100;
const RULES_MAX_ITEMS = 16;
const INVENTORY_MAX_ITEMS = 1000;
const SIGNALS_MAX_ITEMS = 64;
const REASONS_MAX_ITEMS = 16;

const QUANTITY_MAX_GRAMS = 1_000_000;
const COUNT_MAX = 100_000;
const SCORE_MIN = 0;
const SCORE_MAX = 1;

// Free text must not carry control characters into prompts or notifications.
const NO_CONTROL_CHARS = /^[^\u0000-\u001F\u007F-\u009F]*$/;
const LOCALE_PATTERN = /^[A-Za-z0-9_-]+$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
// ISO 8601: date-only ("2026-03-12") or timestamp ("2026-03-12T06:00:00Z").
const ISO_DATE_PATTERN =
  /^\d{4}-\d{2}-\d{2}([Tt]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:?\d{2})?)?$/;

// ─── Primitive helpers ───────────────────────────────────────────────────────

function fail(field: string, status: 400 | 413 = 400): never {
  throw new RequestValidationError(field, status);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function requireObject(body: unknown): Record<string, unknown> {
  if (!isPlainObject(body)) fail("body");
  return body;
}

function boundedString(
  value: unknown,
  field: string,
  opts: { min: number; max: number; pattern?: RegExp }
): string {
  if (typeof value !== "string") fail(field);
  if (value.length < opts.min || value.length > opts.max) fail(field);
  if (!NO_CONTROL_CHARS.test(value)) fail(field);
  if (opts.pattern && !opts.pattern.test(value)) fail(field);
  return value;
}

function boundedStringArray(
  value: unknown,
  field: string,
  opts: { minItems: number; maxItems: number; maxChars: number }
): string[] {
  if (!Array.isArray(value)) fail(field);
  if (value.length < opts.minItems || value.length > opts.maxItems) fail(field);
  return value.map((item, index) =>
    boundedString(item, `${field}[${index}]`, { min: 1, max: opts.maxChars })
  );
}

function finiteNumber(
  value: unknown,
  field: string,
  opts: { min?: number; max?: number }
): number {
  if (typeof value !== "number" || !Number.isFinite(value)) fail(field);
  if (opts.min !== undefined && value < opts.min) fail(field);
  if (opts.max !== undefined && value > opts.max) fail(field);
  return value;
}

function optionalFiniteNumber(
  value: unknown,
  field: string,
  opts: { min?: number; max?: number }
): number | undefined {
  if (value === undefined) return undefined;
  return finiteNumber(value, field, opts);
}

function intInRange(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    fail(field);
  }
  return value;
}

function optionalIntInRange(
  value: unknown,
  field: string,
  min: number,
  max: number
): number | undefined {
  if (value === undefined) return undefined;
  return intInRange(value, field, min, max);
}

function enumValue<T extends string>(value: unknown, field: string, allowed: readonly T[]): T {
  if (typeof value !== "string" || !(allowed as readonly string[]).includes(value)) fail(field);
  return value as T;
}

function optionalEnumValue<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[]
): T | undefined {
  if (value === undefined) return undefined;
  return enumValue(value, field, allowed);
}

function isoDate(value: unknown, field: string, required: boolean): string | undefined {
  if (value === undefined) {
    if (required) fail(field);
    return undefined;
  }
  if (typeof value !== "string") fail(field);
  if (value.length === 0 || value.length > DATE_MAX_CHARS) fail(field);
  if (!ISO_DATE_PATTERN.test(value)) fail(field);
  if (Number.isNaN(Date.parse(value))) fail(field);
  return value;
}

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/**
 * Optional JPEG photo, bounded by ENCODED size (base64 characters). The value
 * must be standard base64 whose leading bytes decode to the JPEG SOI marker
 * (FF D8 FF), checked on a small prefix so no large buffer is ever decoded.
 */
function optionalPhotoBase64Jpeg(value: unknown, field: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") fail(field);
  if (value.length === 0) fail(field);
  if (value.length > PHOTO_BASE64_MAX_CHARS) fail(field, 413);
  if (value.length % 4 !== 0 || !BASE64_PATTERN.test(value)) fail(field);
  const head = Buffer.from(value.slice(0, 8), "base64");
  if (head.length < 3 || head[0] !== 0xff || head[1] !== 0xd8 || head[2] !== 0xff) fail(field);
  return value;
}

// ─── POST /v1/recipes/generate ───────────────────────────────────────────────

export interface RecipeGenerationHttpRequest extends RecipeGenerationRequest {
  /**
   * Optional per packet003: ingredients the user wants to avoid. Accepted,
   * validated, and forwarded at the HTTP boundary; prompt-side use lands with
   * that packet.
   */
  avoidIngredients?: string[];
}

export function parseRecipeGenerationRequest(body: unknown): RecipeGenerationHttpRequest {
  const root = requireObject(body);

  const ingredientNames = boundedStringArray(root.ingredientNames, "ingredientNames", {
    minItems: 1,
    maxItems: INGREDIENT_NAMES_MAX_ITEMS,
    maxChars: NAME_MAX_CHARS
  });

  const dietaryRestrictions =
    root.dietaryRestrictions === undefined
      ? undefined
      : boundedStringArray(root.dietaryRestrictions, "dietaryRestrictions", {
          minItems: 0,
          maxItems: TAG_LIST_MAX_ITEMS,
          maxChars: NAME_MAX_CHARS
        });

  const avoidIngredients =
    root.avoidIngredients === undefined
      ? undefined
      : boundedStringArray(root.avoidIngredients, "avoidIngredients", {
          minItems: 0,
          maxItems: AVOID_LIST_MAX_ITEMS,
          maxChars: NAME_MAX_CHARS
        });

  const scanConfidenceScore = optionalFiniteNumber(root.scanConfidenceScore, "scanConfidenceScore", {
    min: SCORE_MIN,
    max: SCORE_MAX
  });

  const photoBase64JPEG = optionalPhotoBase64Jpeg(root.photoBase64JPEG, "photoBase64JPEG");

  return {
    ingredientNames,
    ...(dietaryRestrictions !== undefined ? { dietaryRestrictions } : {}),
    ...(avoidIngredients !== undefined ? { avoidIngredients } : {}),
    ...(scanConfidenceScore !== undefined ? { scanConfidenceScore } : {}),
    ...(photoBase64JPEG !== undefined ? { photoBase64JPEG } : {})
  };
}

// ─── POST /v1/reverse-scan/rank ──────────────────────────────────────────────

export function parseReverseScanRankRequest(body: unknown): ReverseScanRankRequest {
  const root = requireObject(body);

  if (!Array.isArray(root.detections)) fail("detections");
  if (root.detections.length > DETECTIONS_MAX_ITEMS) fail("detections");
  const detections = root.detections.map((item, index) => {
    if (!isPlainObject(item)) fail(`detections[${index}]`);
    return {
      label: boundedString(item.label, `detections[${index}].label`, {
        min: 1,
        max: NAME_MAX_CHARS
      }),
      confidence: finiteNumber(item.confidence, `detections[${index}].confidence`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      })
    };
  });

  if (!Array.isArray(root.candidates)) fail("candidates");
  if (root.candidates.length > CANDIDATES_MAX_ITEMS) fail("candidates");
  const candidates = root.candidates.map((item, index) => {
    if (!isPlainObject(item)) fail(`candidates[${index}]`);
    return {
      recipeId: intInRange(item.recipeId, `candidates[${index}].recipeId`, 0, Number.MAX_SAFE_INTEGER),
      title: boundedString(item.title, `candidates[${index}].title`, {
        min: 1,
        max: TITLE_MAX_CHARS
      }),
      localConfidence: finiteNumber(item.localConfidence, `candidates[${index}].localConfidence`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      }),
      missingRequiredCount: intInRange(
        item.missingRequiredCount,
        `candidates[${index}].missingRequiredCount`,
        0,
        COUNT_MAX
      )
    };
  });

  const photoBase64JPEG = optionalPhotoBase64Jpeg(root.photoBase64JPEG, "photoBase64JPEG");

  return {
    detections,
    candidates,
    ...(photoBase64JPEG !== undefined ? { photoBase64JPEG } : {})
  };
}

// ─── POST /v1/notifications/plan ─────────────────────────────────────────────

const RULE_KINDS = ["use_soon_alerts"] as const;
const INVENTORY_SOURCES = ["scan", "manual", "restock"] as const;

export function parseNotificationPlanRequest(body: unknown): NotificationPlanRequest {
  const root = requireObject(body);

  const installationId = boundedString(root.installationId, "installationId", {
    min: 1,
    max: ID_MAX_CHARS
  });

  const timezone = boundedString(root.timezone, "timezone", { min: 1, max: 64 });
  if (!isValidTimeZone(timezone)) fail("timezone");

  const locale = boundedString(root.locale, "locale", {
    min: 1,
    max: 35,
    pattern: LOCALE_PATTERN
  });

  const generatedAt = isoDate(root.generatedAt, "generatedAt", true) as string;

  if (!Array.isArray(root.rules)) fail("rules");
  if (root.rules.length > RULES_MAX_ITEMS) fail("rules");
  const rules = root.rules.map((item, index) => {
    if (!isPlainObject(item)) fail(`rules[${index}]`);
    if (typeof item.enabled !== "boolean") fail(`rules[${index}].enabled`);
    return {
      kind: enumValue(item.kind, `rules[${index}].kind`, RULE_KINDS),
      enabled: item.enabled,
      hour: intInRange(item.hour, `rules[${index}].hour`, 0, 23),
      minute: intInRange(item.minute, `rules[${index}].minute`, 0, 59),
      ...(item.pushToken !== undefined
        ? {
            pushToken: boundedString(item.pushToken, `rules[${index}].pushToken`, {
              min: 1,
              max: TOKEN_MAX_CHARS
            })
          }
        : {})
    };
  });

  if (!Array.isArray(root.inventorySnapshot)) fail("inventorySnapshot");
  if (root.inventorySnapshot.length > INVENTORY_MAX_ITEMS) fail("inventorySnapshot");
  const inventorySnapshot = root.inventorySnapshot.map((item, index) => {
    if (!isPlainObject(item)) fail(`inventorySnapshot[${index}]`);
    return {
      ...(item.ingredientId !== undefined
        ? {
            ingredientId: optionalIntInRange(
              item.ingredientId,
              `inventorySnapshot[${index}].ingredientId`,
              0,
              Number.MAX_SAFE_INTEGER
            )
          }
        : {}),
      ingredientName: boundedString(item.ingredientName, `inventorySnapshot[${index}].ingredientName`, {
        min: 1,
        max: NAME_MAX_CHARS
      }),
      quantityGrams: finiteNumber(item.quantityGrams, `inventorySnapshot[${index}].quantityGrams`, {
        min: 0,
        max: QUANTITY_MAX_GRAMS
      }),
      ...(isoDate(item.expiresAt, `inventorySnapshot[${index}].expiresAt`, false) !== undefined
        ? { expiresAt: item.expiresAt as string }
        : {}),
      ...(optionalFiniteNumber(item.confidenceScore, `inventorySnapshot[${index}].confidenceScore`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      }) !== undefined
        ? { confidenceScore: item.confidenceScore as number }
        : {}),
      ...(optionalEnumValue(item.source, `inventorySnapshot[${index}].source`, INVENTORY_SOURCES) !==
      undefined
        ? { source: item.source as (typeof INVENTORY_SOURCES)[number] }
        : {})
    };
  });

  return {
    installationId,
    timezone,
    locale,
    generatedAt,
    rules,
    inventorySnapshot
  };
}

// ─── Debug routes (ENABLE_DEBUG_ROUTES=1) ────────────────────────────────────

const CONFIDENCE_MODES = ["exact", "review_required", "estimate_only"] as const;

export function parseConfidenceAssessRequest(body: unknown): ConfidenceAssessRequest {
  const root = requireObject(body);

  if (!Array.isArray(root.signals)) fail("signals");
  if (root.signals.length > SIGNALS_MAX_ITEMS) fail("signals");
  const signals = root.signals.map((item, index) => {
    if (!isPlainObject(item)) fail(`signals[${index}]`);
    return {
      key: boundedString(item.key, `signals[${index}].key`, { min: 1, max: NAME_MAX_CHARS }),
      rawScore: finiteNumber(item.rawScore, `signals[${index}].rawScore`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      }),
      ...(optionalFiniteNumber(item.weight, `signals[${index}].weight`, {
        min: 0,
        max: 100
      }) !== undefined
        ? { weight: item.weight as number }
        : {}),
      ...(item.reason !== undefined
        ? {
            reason: boundedString(item.reason, `signals[${index}].reason`, {
              min: 1,
              max: REASON_MAX_CHARS
            })
          }
        : {})
    };
  });

  const hardFailReasons =
    root.hardFailReasons === undefined
      ? undefined
      : boundedStringArray(root.hardFailReasons, "hardFailReasons", {
          minItems: 0,
          maxItems: REASONS_MAX_ITEMS,
          maxChars: REASON_MAX_CHARS
        });

  return {
    signals,
    ...(hardFailReasons !== undefined ? { hardFailReasons } : {})
  };
}

export function parseConfidenceOutcomeRequest(body: unknown): ConfidenceOutcomeRequest {
  const root = requireObject(body);

  if (!isPlainObject(root.assessment)) fail("assessment");
  const assessmentRoot = root.assessment;

  if (!Array.isArray(assessmentRoot.signals)) fail("assessment.signals");
  if (assessmentRoot.signals.length > SIGNALS_MAX_ITEMS) fail("assessment.signals");
  const assessmentSignals = assessmentRoot.signals.map((item, index) => {
    if (!isPlainObject(item)) fail(`assessment.signals[${index}]`);
    return {
      key: boundedString(item.key, `assessment.signals[${index}].key`, {
        min: 1,
        max: NAME_MAX_CHARS
      }),
      rawScore: finiteNumber(item.rawScore, `assessment.signals[${index}].rawScore`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      }),
      adjustedScore: finiteNumber(
        item.adjustedScore,
        `assessment.signals[${index}].adjustedScore`,
        { min: SCORE_MIN, max: SCORE_MAX }
      ),
      trustMean: finiteNumber(item.trustMean, `assessment.signals[${index}].trustMean`, {
        min: SCORE_MIN,
        max: SCORE_MAX
      }),
      trustUncertainty: finiteNumber(
        item.trustUncertainty,
        `assessment.signals[${index}].trustUncertainty`,
        { min: 0, max: 1 }
      ),
      weight: finiteNumber(item.weight, `assessment.signals[${index}].weight`, {
        min: SCORE_MIN,
        max: 100
      }),
      ...(item.reason !== undefined
        ? {
            reason: boundedString(item.reason, `assessment.signals[${index}].reason`, {
              min: 1,
              max: REASON_MAX_CHARS
            })
          }
        : { reason: "" })
    };
  });

  const assessment = {
    mode: enumValue(assessmentRoot.mode, "assessment.mode", CONFIDENCE_MODES),
    overallScore: finiteNumber(assessmentRoot.overallScore, "assessment.overallScore", {
      min: SCORE_MIN,
      max: SCORE_MAX
    }),
    deterministicReady:
      typeof assessmentRoot.deterministicReady === "boolean"
        ? assessmentRoot.deterministicReady
        : fail("assessment.deterministicReady"),
    ...(Array.isArray(assessmentRoot.reasons) &&
    assessmentRoot.reasons.length <= REASONS_MAX_ITEMS
      ? {
          reasons: assessmentRoot.reasons.map((item, index) =>
            boundedString(item, `assessment.reasons[${index}]`, {
              min: 1,
              max: REASON_MAX_CHARS
            })
          )
        }
      : fail("assessment.reasons")),
    signals: assessmentSignals
  };

  const outcomeReward = finiteNumber(root.outcomeReward, "outcomeReward", {
    min: SCORE_MIN,
    max: SCORE_MAX
  });

  return {
    assessment,
    outcomeReward,
    ...(root.contextKey !== undefined
      ? {
          contextKey: boundedString(root.contextKey, "contextKey", {
            min: 1,
            max: NAME_MAX_CHARS
          })
        }
      : {}),
    ...(root.note !== undefined
      ? {
          note: boundedString(root.note, "note", { min: 1, max: REASON_MAX_CHARS })
        }
      : {})
  };
}
