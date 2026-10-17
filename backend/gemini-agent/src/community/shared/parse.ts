/**
 * Boundary parsers: every value entering the community module from a request
 * body or query is `unknown` until one of these accepts it. Business logic
 * never re-validates — trust the parsed types.
 */
import { errValidation } from "./errors.js";

export function expectString(raw: unknown, field: string, bounds?: { min?: number; max?: number }): string {
  if (typeof raw !== "string") {
    throw errValidation(`${field} must be a string`);
  }
  if (bounds) {
    if (bounds.min !== undefined && raw.length < bounds.min) {
      throw errValidation(`${field} must be at least ${bounds.min} characters`);
    }
    if (bounds.max !== undefined && raw.length > bounds.max) {
      throw errValidation(`${field} must be at most ${bounds.max} characters`);
    }
  }
  return raw;
}

export function expectOptionalString(raw: unknown, field: string, bounds?: { min?: number; max?: number }): string | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  return expectString(raw, field, bounds);
}

export function expectInt(raw: unknown, field: string, bounds?: { min?: number; max?: number }): number {
  if (typeof raw !== "number" || !Number.isInteger(raw)) {
    throw errValidation(`${field} must be an integer`);
  }
  if (bounds) {
    if (bounds.min !== undefined && raw < bounds.min) {
      throw errValidation(`${field} must be at least ${bounds.min}`);
    }
    if (bounds.max !== undefined && raw > bounds.max) {
      throw errValidation(`${field} must be at most ${bounds.max}`);
    }
  }
  return raw;
}

export function expectOptionalInt(raw: unknown, field: string, bounds?: { min?: number; max?: number }): number | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  return expectInt(raw, field, bounds);
}

export function expectBoolean(raw: unknown, field: string): boolean {
  if (typeof raw !== "boolean") {
    throw errValidation(`${field} must be a boolean`);
  }
  return raw;
}

export function expectArray(raw: unknown, field: string, bounds?: { max?: number }): unknown[] {
  if (!Array.isArray(raw)) {
    throw errValidation(`${field} must be an array`);
  }
  if (bounds?.max !== undefined && raw.length > bounds.max) {
    throw errValidation(`${field} must have at most ${bounds.max} items`);
  }
  return raw;
}

export function expectOneOf<L extends string>(raw: unknown, field: string, literals: readonly L[]): L {
  if (typeof raw !== "string") {
    throw errValidation(`${field} must be one of: ${literals.join(", ")}`);
  }
  const found = literals.find((l) => l === raw);
  if (found === undefined) {
    throw errValidation(`${field} must be one of: ${literals.join(", ")}`);
  }
  return found;
}

/** Parses an ISO-8601 timestamp the client may not have faked into the future beyond tolerance. */
export function expectIsoDate(raw: unknown, field: string): string {
  const s = expectString(raw, field);
  const t = Date.parse(s);
  if (Number.isNaN(t)) {
    throw errValidation(`${field} must be an ISO-8601 timestamp`);
  }
  return new Date(t).toISOString();
}
