import type { ConfidenceAssessRequest, ConfidenceMode } from "../types/contracts.js";

export type Mode = ConfidenceMode;
export const MODES = ["exact", "review_required", "estimate_only"] as const;
export interface RoutingRequest extends ConfidenceAssessRequest {
  signals: Array<{ key: string; rawScore: number; weight: number; reason: string }>;
  hardFailReasons: string[];
}
export interface RoutingRow { case_id: string; request: RoutingRequest }

export function exactObject(value: unknown, fields: string[], path: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) {
    throw new Error(`${path}: expected plain object`);
  }
  const keys = Reflect.ownKeys(value);
  if (keys.length !== fields.length || !fields.every(k => keys.includes(k))) {
    throw new Error(`${path}: expected exactly fields ${fields.join(", ")}`);
  }
  return value as Record<string, unknown>;
}
export function nonemptyString(value: unknown, path: string): asserts value is string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${path}: expected nonempty string`);
}
export function validateRequest(value: unknown): asserts value is RoutingRequest {
  const request = exactObject(value, ["signals", "hardFailReasons"], "request");
  if (!Array.isArray(request.signals)) throw new Error("request.signals: expected array");
  if (!Array.isArray(request.hardFailReasons)) throw new Error("request.hardFailReasons: expected array");
  request.hardFailReasons.forEach((v, i) => nonemptyString(v, `request.hardFailReasons[${i}]`));
  request.signals.forEach((v, i) => {
    const path = `request.signals[${i}]`;
    const signal = exactObject(v, ["key", "rawScore", "weight", "reason"], path);
    nonemptyString(signal.key, `${path}.key`);
    nonemptyString(signal.reason, `${path}.reason`);
    if (typeof signal.rawScore !== "number" || !Number.isFinite(signal.rawScore) || signal.rawScore < 0 || signal.rawScore > 1) {
      throw new Error(`${path}.rawScore: expected finite number in [0,1]`);
    }
    if (typeof signal.weight !== "number" || !Number.isFinite(signal.weight) || signal.weight <= 0) {
      throw new Error(`${path}.weight: expected finite number > 0`);
    }
  });
}
export function validateRoutingRow(value: unknown): asserts value is RoutingRow {
  const row = exactObject(value, ["case_id", "request"], "row");
  nonemptyString(row.case_id, "row.case_id");
  validateRequest(row.request);
}
