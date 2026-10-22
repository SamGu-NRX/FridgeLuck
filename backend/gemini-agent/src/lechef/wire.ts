/**
 * Wire canonicalization and parsing for the LeChef proposal/receipt contract.
 *
 * The source of truth is docs/spec/lechef/contracts/ (proposal.schema.json,
 * receipt.schema.json and their example fixtures) — SPEC §8 "adopts PR
 * #102's pinned wire contract verbatim and extends it in the same pattern".
 * This module is the TypeScript mirror of those schemas, re-cut from #102's
 * wire.ts where the contract canonized things differently:
 *
 * - timestamps are ISO-8601 strings with millisecond precision on the wire
 *   (the contract schemas' pattern); EpochSeconds is used only for
 *   phone-owned timer deadlines (types.ts ActiveTimer);
 * - the envelope carries `kind` (the nine registered payload kinds) at the
 *   top level, `rationale`, and `requiredApproval` — the derived audit
 *   annotation the model cannot control;
 * - payloadHash = "sha256:" + hex over COMPACT canonical JSON of the payload
 *   (recursively key-sorted, no whitespace) — byte-for-byte the same rule
 *   docs/spec/lechef/contracts/check.py's fixtures were hashed with, and the
 *   same canonicalization #102 pinned.
 *
 * Decoding a fixture and re-encoding it must reproduce the file's bytes
 * (modulo a single trailing newline); the round-trip test over every example
 * in contracts/examples/ is the authority.
 */

import { createHash } from "node:crypto";
import { PHONE_RESTRICTION_IDS } from "./allergens.js";
import type {
  ActionProposalWire,
  ActionReceiptWire,
  AllergenRecheck,
  CameraMode,
  CookSessionSnapshot,
  CookSessionState,
  Eater,
  ProposalKind,
  ProposalPayload,
  ProposalTool,
  RecipeRef,
  RequiredApproval,
  SwapRole
} from "./types.js";
import { PROPOSAL_KINDS, msFromIso } from "./types.js";

// ---------------------------------------------------------------------------
// Canonical JSON — compact, recursively key-sorted, no whitespace
// ---------------------------------------------------------------------------

/** Compact canonical JSON: sorted keys recursively, no whitespace. */
export function canonicalJsonString(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error(`canonicalJsonString: nonfinite number ${value}`);
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return `[${value.map(canonicalJsonString).join(",")}]`;
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJsonString(v)}`).join(",")}}`;
  }
  throw new Error(`canonicalJsonString: unsupported value of type ${typeof value}`);
}

/** payloadHash — "sha256:<hex>" over the compact canonical JSON of the payload. */
export function payloadHash(value: unknown): string {
  return `sha256:${createHash("sha256").update(canonicalJsonString(value)).digest("hex")}`;
}

// ---------------------------------------------------------------------------
// Kinds, tools and payload validation
// ---------------------------------------------------------------------------

const TOOL_FOR_KIND: Readonly<Record<ProposalKind, ProposalTool>> = {
  timer_start: "proposeTimerStart",
  timer_adjust: "proposeTimerAdjust",
  step_advance: "proposeStepAdvance",
  inventory_correction: "proposeInventoryCorrection",
  meal_log: "proposeMealLog",
  save_note: "proposeSaveNote",
  plan: "proposePlan",
  swap: "proposeSwap",
  adaptation: "proposeAdaptation"
};

export function toolForKind(kind: ProposalKind): ProposalTool {
  return TOOL_FOR_KIND[kind];
}

const KIND_FOR_TOOL: Readonly<Record<ProposalTool, ProposalKind>> = Object.fromEntries(
  Object.entries(TOOL_FOR_KIND).map(([k, t]) => [t, k])
) as Readonly<Record<ProposalTool, ProposalKind>>;

export function kindForTool(tool: ProposalTool): ProposalKind {
  return KIND_FOR_TOOL[tool];
}

const SWAP_ROLES: readonly SwapRole[] = [
  "acid",
  "aromatic",
  "binder",
  "fat",
  "garnish",
  "leavening",
  "liquid",
  "protein",
  "sweetener",
  "thickener",
  "umami"
];

const RECIPE_SOURCES: readonly RecipeRef["source"][] = ["catalog", "user", "community", "generated"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Validate a payload against the branch its kind names (proposal.schema.json's
 * oneOf, with the kind discriminant this layer pairs with the envelope).
 * Strict: unknown keys reject (the schema's additionalProperties: false).
 * Returns an issue list — empty when valid.
 */
export function payloadIssues(kind: ProposalKind, payload: unknown): string[] {
  const at = "$.payload";
  if (!isRecord(payload)) return [`${at}: expected an object`];
  const issues: string[] = [];
  const keys = Object.keys(payload).sort();
  const has = (k: string): boolean => keys.includes(k);
  const num = (k: string): number =>
    typeof payload[k] === "number" && Number.isFinite(payload[k]) ? (payload[k] as number) : NaN;
  const str = (k: string): string => (typeof payload[k] === "string" ? (payload[k] as string) : "");
  const isInt = (v: number, min: number, max?: number): boolean =>
    Number.isInteger(v) && v >= min && (max === undefined || v <= max);

  switch (kind) {
    case "timer_start": {
      const d = num("durationMinutes");
      if (!(d > 0) || d > 180) issues.push(`${at}.durationMinutes: expected number (0, 180]`);
      if (has("label") && (typeof payload["label"] !== "string" || str("label").length > 40)) {
        issues.push(`${at}.label: expected string of at most 40 chars`);
      }
      for (const k of keys) if (k !== "durationMinutes" && k !== "label") issues.push(`${at}.${k}: not allowed for timer_start`);
      break;
    }
    case "timer_adjust": {
      if (!has("timerId") || typeof payload["timerId"] !== "string") issues.push(`${at}.timerId: expected string`);
      if (has("newDurationMinutes")) {
        const d = num("newDurationMinutes");
        if (!(d > 0) || d > 180) issues.push(`${at}.newDurationMinutes: expected number (0, 180]`);
      }
      for (const k of keys) if (k !== "timerId" && k !== "newDurationMinutes") issues.push(`${at}.${k}: not allowed for timer_adjust`);
      break;
    }
    case "step_advance": {
      if (!has("stepIndex") || !isInt(num("stepIndex"), 0)) issues.push(`${at}.stepIndex: expected integer >= 0`);
      for (const k of keys) if (k !== "stepIndex") issues.push(`${at}.${k}: not allowed for step_advance`);
      break;
    }
    case "inventory_correction": {
      if (!has("ingredientId") || !isInt(num("ingredientId"), -Infinity)) issues.push(`${at}.ingredientId: expected integer`);
      if (!has("correction") || typeof payload["correction"] !== "string" || str("correction").length > 120) {
        issues.push(`${at}.correction: expected string of at most 120 chars`);
      }
      for (const k of keys) if (k !== "ingredientId" && k !== "correction") issues.push(`${at}.${k}: not allowed for inventory_correction`);
      break;
    }
    case "meal_log": {
      const r = payload["recipe"];
      if (
        !isRecord(r) ||
        !RECIPE_SOURCES.includes(r["source"] as never) ||
        typeof r["id"] !== "string" ||
        !Number.isInteger(r["revision"]) ||
        (r["revision"] as number) < 1 ||
        Object.keys(r).some((k) => k !== "source" && k !== "id" && k !== "revision")
      ) {
        issues.push(`${at}.recipe: expected { source, id, revision }`);
      }
      for (const k of keys) if (k !== "recipe") issues.push(`${at}.${k}: not allowed for meal_log`);
      break;
    }
    case "save_note": {
      if (has("prompt") && (typeof payload["prompt"] !== "string" || str("prompt").length > 120)) {
        issues.push(`${at}.prompt: expected string of at most 120 chars`);
      }
      if (has("noteSavedMarker") && typeof payload["noteSavedMarker"] !== "boolean") {
        issues.push(`${at}.noteSavedMarker: expected boolean`);
      }
      for (const k of keys) if (k !== "prompt" && k !== "noteSavedMarker") issues.push(`${at}.${k}: not allowed for save_note — note text never leaves the phone`);
      break;
    }
    case "plan": {
      if (!has("dinnerCount") || !isInt(num("dinnerCount"), 1, 7)) issues.push(`${at}.dinnerCount: expected integer 1..7`);
      if (has("constraints")) {
        const c = payload["constraints"];
        if (!Array.isArray(c) || c.some((x) => typeof x !== "string")) issues.push(`${at}.constraints: expected array of strings`);
      }
      for (const k of keys) if (k !== "dinnerCount" && k !== "constraints") issues.push(`${at}.${k}: not allowed for plan`);
      break;
    }
    case "swap": {
      if (!has("originalIngredientId") || !isInt(num("originalIngredientId"), -Infinity)) issues.push(`${at}.originalIngredientId: expected integer`);
      if (!has("substituteIngredientId") || !isInt(num("substituteIngredientId"), -Infinity)) issues.push(`${at}.substituteIngredientId: expected integer`);
      if (!has("role") || !SWAP_ROLES.includes(payload["role"] as never)) issues.push(`${at}.role: expected one of the eleven reviewed roles`);
      for (const k of keys) if (k !== "originalIngredientId" && k !== "substituteIngredientId" && k !== "role") issues.push(`${at}.${k}: not allowed for swap`);
      break;
    }
    case "adaptation": {
      if (has("servings") && !isInt(num("servings"), 1, 12)) issues.push(`${at}.servings: expected integer 1..12`);
      if (!has("change") || typeof payload["change"] !== "string" || str("change").length > 120) {
        issues.push(`${at}.change: expected string of at most 120 chars`);
      }
      for (const k of keys) if (k !== "servings" && k !== "change") issues.push(`${at}.${k}: not allowed for adaptation`);
      break;
    }
  }
  if (keys.length === 0 && kind !== "meal_log" && kind !== "save_note") {
    issues.push(`${at}: empty payload does not match the ${kind} branch`);
  }
  return issues;
}

// ---------------------------------------------------------------------------
// Parse issues
// ---------------------------------------------------------------------------

export interface ParseIssue {
  readonly path: string;
  readonly problem: string;
}

export class WireParseError extends Error {
  readonly issues: readonly ParseIssue[];
  constructor(issues: readonly ParseIssue[]) {
    super(`wire parse failed: ${issues.map((i) => `${i.path}: ${i.problem}`).join("; ")}`);
    this.name = "WireParseError";
    this.issues = issues;
  }
}

function issueList(): { issues: ParseIssue[]; add(path: string, problem: string): void; any(): boolean } {
  const issues: ParseIssue[] = [];
  return { issues, add: (path, problem) => issues.push({ path, problem }), any: () => issues.length > 0 };
}

const PROPOSAL_ID_RE = /^prop_[A-Za-z0-9]+$/;
const PAYLOAD_HASH_RE = /^sha256:[0-9a-f]{64}$/;

// ---------------------------------------------------------------------------
// Proposal wire — parse and serialize
// ---------------------------------------------------------------------------

/** Canonical wire bytes for a proposal: the example fixtures' own 2-space JSON form. */
export function serializeProposal(proposal: ActionProposalWire): string {
  return JSON.stringify(
    {
      proposalID: proposal.proposalID,
      createdAt: proposal.createdAt,
      expiresAt: proposal.expiresAt,
      payloadHash: proposal.payloadHash,
      kind: proposal.kind,
      payload: proposal.payload,
      rationale: proposal.rationale,
      requiredApproval: proposal.requiredApproval
    },
    null,
    2
  );
}

/** Canonical wire bytes for a receipt (allergenRecheck and reason emitted only when present). */
export function serializeReceipt(receipt: ActionReceiptWire): string {
  return JSON.stringify(
    {
      proposalID: receipt.proposalID,
      payloadHash: receipt.payloadHash,
      snapshotRevision: receipt.snapshotRevision,
      state: receipt.state,
      recordedAt: receipt.recordedAt,
      ...(receipt.reason !== undefined ? { reason: receipt.reason } : {}),
      ...(receipt.allergenRecheck !== undefined ? { allergenRecheck: receipt.allergenRecheck } : {})
    },
    null,
    2
  );
}

/** Parse an unknown value into an ActionProposalWire, validating every field (SPEC §8.1). */
export function parseProposal(value: unknown): ActionProposalWire {
  const ctx = issueList();
  if (!isRecord(value)) throw new WireParseError([{ path: "$", problem: "expected an object" }]);

  const proposalID = value["proposalID"];
  if (typeof proposalID !== "string" || !PROPOSAL_ID_RE.test(proposalID)) {
    ctx.add("$.proposalID", "expected prop_<alnum>");
  }
  const createdAtMs = msFromIso(value["createdAt"]);
  if (createdAtMs === null) ctx.add("$.createdAt", "expected ISO-8601 ms timestamp");
  const expiresAtMs = msFromIso(value["expiresAt"]);
  if (expiresAtMs === null) ctx.add("$.expiresAt", "expected ISO-8601 ms timestamp");
  const payloadHashValue = value["payloadHash"];
  if (typeof payloadHashValue !== "string" || !PAYLOAD_HASH_RE.test(payloadHashValue)) {
    ctx.add("$.payloadHash", "expected sha256:<64 hex>");
  }
  const kind = value["kind"];
  if (typeof kind !== "string" || !PROPOSAL_KINDS.includes(kind as never)) {
    ctx.add("$.kind", `expected one of ${PROPOSAL_KINDS.join("|")}`);
  }
  const rationale = value["rationale"];
  if (typeof rationale !== "string" || rationale.length > 280) {
    ctx.add("$.rationale", "expected string of at most 280 chars");
  }
  const requiredApproval = value["requiredApproval"];
  if (requiredApproval !== "explicit" && requiredApproval !== "device-auto") {
    ctx.add("$.requiredApproval", "expected explicit or device-auto");
  }
  const payload = value["payload"];
  if (typeof kind === "string" && PROPOSAL_KINDS.includes(kind as never)) {
    for (const problem of payloadIssues(kind as ProposalKind, payload)) ctx.add(problem, "");
  }
  if (
    createdAtMs !== null &&
    expiresAtMs !== null &&
    expiresAtMs - createdAtMs !== 300_000
  ) {
    ctx.add("$.expiresAt", "expected createdAt + 300 s (the pinned TTL)");
  }
  if (ctx.any()) throw new WireParseError(ctx.issues.filter((i) => i.problem !== "" || i.path.startsWith("$.payload")));

  return {
    proposalID: proposalID as string,
    createdAt: value["createdAt"] as string,
    expiresAt: value["expiresAt"] as string,
    payloadHash: payloadHashValue as string,
    kind: kind as ProposalKind,
    payload: payload as ProposalPayload,
    rationale: rationale as string,
    requiredApproval: requiredApproval as RequiredApproval
  };
}

const RECEIPT_STATES: readonly ActionReceiptWire["state"][] = ["executed", "rejected", "expired", "cancelled"];
const RECHECK_VERDICTS: readonly AllergenRecheck["verdict"][] = ["verified", "plausible", "unknown", "unsupported"];

function recheckIssues(value: unknown, at: string): string[] {
  const issues: string[] = [];
  if (!isRecord(value)) return [`${at}: expected an object`];
  if (!RECHECK_VERDICTS.includes(value["verdict"] as never)) issues.push(`${at}.verdict: expected verified|plausible|unknown|unsupported`);
  if (!Array.isArray(value["eaters"]) || value["eaters"].some((e) => typeof e !== "string")) {
    issues.push(`${at}.eaters: expected array of strings`);
  }
  if (value["blockedPath"] !== undefined && value["blockedPath"] !== null && typeof value["blockedPath"] !== "string") {
    issues.push(`${at}.blockedPath: expected string or null`);
  }
  for (const k of Object.keys(value)) if (k !== "verdict" && k !== "eaters" && k !== "blockedPath") issues.push(`${at}.${k}: not allowed`);
  return issues;
}

/** Parse an unknown value into an ActionReceiptWire, validating every field (SPEC §8.2). */
export function parseReceipt(value: unknown): ActionReceiptWire {
  const ctx = issueList();
  if (!isRecord(value)) throw new WireParseError([{ path: "$", problem: "expected an object" }]);

  const proposalID = value["proposalID"];
  if (typeof proposalID !== "string" || !PROPOSAL_ID_RE.test(proposalID)) {
    ctx.add("$.proposalID", "expected prop_<alnum>");
  }
  const payloadHashValue = value["payloadHash"];
  if (typeof payloadHashValue !== "string" || !PAYLOAD_HASH_RE.test(payloadHashValue)) {
    ctx.add("$.payloadHash", "expected sha256:<64 hex>");
  }
  const revision = value["snapshotRevision"];
  if (typeof revision !== "number" || !Number.isInteger(revision) || revision < 1) {
    ctx.add("$.snapshotRevision", "expected integer >= 1");
  }
  const state = value["state"];
  if (typeof state !== "string" || !RECEIPT_STATES.includes(state as never)) {
    ctx.add("$.state", `expected one of ${RECEIPT_STATES.join("|")}`);
  }
  if (msFromIso(value["recordedAt"]) === null) ctx.add("$.recordedAt", "expected ISO-8601 ms timestamp");
  if (value["reason"] !== undefined && (typeof value["reason"] !== "string" || (value["reason"] as string).length > 200)) {
    ctx.add("$.reason", "expected string of at most 200 chars");
  }
  for (const problem of value["allergenRecheck"] !== undefined ? recheckIssues(value["allergenRecheck"], "$.allergenRecheck") : []) {
    ctx.add(problem, "");
  }
  if (ctx.any()) throw new WireParseError(ctx.issues.filter((i) => i.problem !== "" || i.path.startsWith("$.allergenRecheck")));

  return {
    proposalID: proposalID as string,
    payloadHash: payloadHashValue as string,
    snapshotRevision: revision as number,
    state: state as ActionReceiptWire["state"],
    recordedAt: value["recordedAt"] as string,
    ...(value["reason"] !== undefined ? { reason: value["reason"] as string } : {}),
    ...(value["allergenRecheck"] !== undefined ? { allergenRecheck: value["allergenRecheck"] as AllergenRecheck } : {})
  };
}

// ---------------------------------------------------------------------------
// Cook session snapshot (session_context.cookSession)
// ---------------------------------------------------------------------------

const COOK_SESSION_STATES: readonly CookSessionState[] = ["planning", "cooking", "paused", "done"];
const CAMERA_MODES: readonly CameraMode[] = ["push-to-look", "continuous"];

/**
 * Parse the phone's cook session snapshot. Substitution, plan and proposal
 * screening read `eaters`, so a list the screen cannot trust throws instead
 * of becoming an unrestricted household: at least one eater, each exactly
 * { name?: string, restrictions: string[] }, every restriction one of
 * PHONE_RESTRICTION_IDS. The other fields are checked for type only; the
 * optional histories (stepHistory, deviceEvents) pass through unchecked.
 */
export function parseCookSession(value: unknown): CookSessionSnapshot {
  if (!isRecord(value)) throw new WireParseError([{ path: "$", problem: "expected an object" }]);
  const ctx = issueList();

  if (!COOK_SESSION_STATES.includes(value["state"] as never)) {
    ctx.add("$.state", `expected one of ${COOK_SESSION_STATES.join("|")}`);
  }
  const stepIndex = value["currentStepIndex"];
  if (typeof stepIndex !== "number" || !Number.isInteger(stepIndex) || stepIndex < 0) {
    ctx.add("$.currentStepIndex", "expected integer >= 0");
  }
  if (!Array.isArray(value["activeTimers"])) ctx.add("$.activeTimers", "expected an array");
  if (!CAMERA_MODES.includes(value["cameraMode"] as never)) {
    ctx.add("$.cameraMode", `expected one of ${CAMERA_MODES.join("|")}`);
  }

  const eaters: Eater[] = [];
  const rawEaters = value["eaters"];
  if (!Array.isArray(rawEaters) || rawEaters.length === 0) {
    ctx.add("$.eaters", "expected a non-empty array of eaters");
  } else {
    rawEaters.forEach((eater, i) => {
      const at = `$.eaters[${i}]`;
      if (!isRecord(eater)) {
        ctx.add(at, "expected an object");
        return;
      }
      for (const k of Object.keys(eater)) if (k !== "name" && k !== "restrictions") ctx.add(`${at}.${k}`, "not allowed");
      const name = eater["name"];
      if (name !== undefined && typeof name !== "string") ctx.add(`${at}.name`, "expected a string");
      const restrictions = eater["restrictions"];
      if (!Array.isArray(restrictions)) {
        ctx.add(`${at}.restrictions`, "expected an array of restriction ids");
        return;
      }
      restrictions.forEach((r, j) => {
        if (typeof r !== "string" || !PHONE_RESTRICTION_IDS.includes(r)) {
          ctx.add(`${at}.restrictions[${j}]`, `unknown restriction id ${JSON.stringify(r)}; expected one of ${PHONE_RESTRICTION_IDS.join("|")}`);
        }
      });
      eaters.push({ ...(typeof name === "string" ? { name } : {}), restrictions: restrictions as string[] });
    });
  }
  if (ctx.any()) throw new WireParseError(ctx.issues);

  return { ...(value as unknown as CookSessionSnapshot), eaters };
}

/** The proposal's payload hash, recomputed — an approval with a mismatching hash is rejected. */
export function verifyProposalHash(proposal: ActionProposalWire): boolean {
  return payloadHash(proposal.payload) === proposal.payloadHash;
}
