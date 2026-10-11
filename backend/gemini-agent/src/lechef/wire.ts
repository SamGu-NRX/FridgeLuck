/**
 * Wire canonicalization for the FLDomain fixture contract.
 *
 * The fixtures on origin/overhaul/core-foundation
 * (packages/FridgeLuckCore/Fixtures/action-proposal.json and
 * action-receipt.json) are the single source of truth for what these types
 * look like on the wire. Their canonical bytes are what Swift's
 * `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` produces:
 *
 * - keys sorted recursively, ascending byte order;
 * - two-space indent per level;
 * - ` : ` between key and value (space on both sides of the colon);
 * - timestamps as integer epoch seconds;
 * - file ends with `}` — no trailing newline.
 *
 * Decoding a fixture and re-encoding it must reproduce the file byte for
 * byte. Timestamps: the wire uses integer epoch seconds (see the fixtures);
 * ISO 8601 strings are used by the evaluation layer and reconciled in
 * lechef/README.md ("Timestamps").
 */

import { createHash } from "node:crypto";
import type { EpochSeconds } from "./types.js";
import { epochSecondsFromWire } from "./types.js";
import type { ProposalPayload, ProposalTool, RequiredApproval } from "./types.js";

// ---------------------------------------------------------------------------
// Canonical encoders
// ---------------------------------------------------------------------------

/** Canonical wire JSON: sorted keys, 2-space indent, ` : ` separators — the Swift encoder's shape. */
export function canonicalWireJson(value: unknown): string {
  return wireValue(value, 0);
}

function wireValue(value: unknown, depth: number): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return wireNumber(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    const inner = value.map((item) => `${"  ".repeat(depth + 1)}${wireValue(item, depth + 1)}`);
    return `[\n${inner.join(",\n")}\n${"  ".repeat(depth)}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    if (entries.length === 0) return "{}";
    const inner = entries.map(
      ([k, v]) => `${"  ".repeat(depth + 1)}${JSON.stringify(k)} : ${wireValue(v, depth + 1)}`
    );
    return `{\n${inner.join(",\n")}\n${"  ".repeat(depth)}}`;
  }
  throw new Error(`canonicalWireJson: unsupported value of type ${typeof value}`);
}

function wireNumber(n: number): string {
  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    throw new Error(`canonicalWireJson: only finite integers cross the wire, got ${n}`);
  }
  return String(n);
}

/** Compact canonical JSON for hashing: sorted keys recursively, no whitespace. */
export function canonicalJsonString(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return String(value);
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

/** payloadHash — sha256 over the compact canonical JSON of the payload. */
export function payloadHash(value: unknown): string {
  return createHash("sha256").update(canonicalJsonString(value)).digest("hex");
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

/** The exact FLDomain wire proposal (the seven fixture fields). */
export interface ActionProposalWire {
  readonly id: string;
  readonly tool: ProposalTool;
  readonly payload: ProposalPayload;
  readonly payloadHash: string;
  readonly snapshotRevision: number;
  readonly createdAt: EpochSeconds;
  readonly expiresAt: EpochSeconds;
  /** Additive fields the phone needs; present on module proposals, absent in the frozen fixtures. */
  readonly requiredApproval?: RequiredApproval;
  readonly userInitiated?: boolean;
}

/** The exact FLDomain wire receipt (the five fixture fields; note `proposalID`). */
export interface ActionReceiptWire {
  readonly proposalID: string;
  readonly payloadHash: string;
  readonly snapshotRevision: number;
  readonly state: "executed" | "rejected" | "expired" | "cancelled";
  readonly recordedAt: EpochSeconds;
}

/** Serialize a proposal to canonical wire bytes (additive fields emitted only when set). */
export function serializeActionProposal(proposal: ActionProposalWire): string {
  return canonicalWireJson({
    id: proposal.id,
    tool: proposal.tool,
    payload: proposal.payload,
    payloadHash: proposal.payloadHash,
    snapshotRevision: proposal.snapshotRevision,
    createdAt: proposal.createdAt,
    expiresAt: proposal.expiresAt,
    ...(proposal.requiredApproval !== undefined ? { requiredApproval: proposal.requiredApproval } : {}),
    ...(proposal.userInitiated !== undefined ? { userInitiated: proposal.userInitiated } : {})
  });
}

/** Serialize a receipt to canonical wire bytes. */
export function serializeActionReceipt(receipt: ActionReceiptWire): string {
  return canonicalWireJson({
    proposalID: receipt.proposalID,
    payloadHash: receipt.payloadHash,
    snapshotRevision: receipt.snapshotRevision,
    state: receipt.state,
    recordedAt: receipt.recordedAt
  });
}

// ---------------------------------------------------------------------------
// Boundary parsers — external JSON is unknown until parsed here
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const RECEIPT_STATES = ["executed", "rejected", "expired", "cancelled"] as const;

/** Parse an unknown value into an ActionReceiptWire, validating every field. */
export function parseActionReceiptWire(value: unknown): ActionReceiptWire {
  const ctx = issueList();
  if (!isRecord(value)) throw new WireParseError([{ path: "$", problem: "expected an object" }]);
  const proposalID = value["proposalID"];
  if (typeof proposalID !== "string") ctx.add("$.proposalID", "expected string");
  const payloadHash = value["payloadHash"];
  if (typeof payloadHash !== "string") ctx.add("$.payloadHash", "expected string");
  const snapshotRevision = value["snapshotRevision"];
  if (typeof snapshotRevision !== "number" || !Number.isInteger(snapshotRevision)) {
    ctx.add("$.snapshotRevision", "expected integer");
  }
  const state = value["state"];
  if (typeof state !== "string" || !RECEIPT_STATES.includes(state as never)) {
    ctx.add("$.state", `expected one of ${RECEIPT_STATES.join("|")}`);
  }
  const recordedAt = value["recordedAt"];
  if (typeof recordedAt !== "number" || !Number.isInteger(recordedAt)) {
    ctx.add("$.recordedAt", "expected integer epoch seconds");
  }
  if (ctx.any()) throw new WireParseError(ctx.issues);
  return {
    proposalID: proposalID as string,
    payloadHash: payloadHash as string,
    snapshotRevision: snapshotRevision as number,
    state: state as ActionReceiptWire["state"],
    recordedAt: epochSecondsFromWire(recordedAt as number)
  };
}

const PROPOSAL_TOOLS = [
  "proposeTimerStart",
  "proposeTimerAdjust",
  "proposeStepAdvance",
  "proposeInventoryCorrection",
  "proposeMealLog",
  "proposeSaveNote"
] as const;

/** Parse an unknown value into an ActionProposalWire, validating every field. */
export function parseActionProposalWire(value: unknown): ActionProposalWire {
  const ctx = issueList();
  if (!isRecord(value)) throw new WireParseError([{ path: "$", problem: "expected an object" }]);
  const id = value["id"];
  if (typeof id !== "string") ctx.add("$.id", "expected string");
  const tool = value["tool"];
  if (typeof tool !== "string" || !PROPOSAL_TOOLS.includes(tool as never)) {
    ctx.add("$.tool", `expected one of ${PROPOSAL_TOOLS.join("|")}`);
  }
  const payload = value["payload"];
  if (!isRecord(payload) || typeof payload["kind"] !== "string") {
    ctx.add("$.payload", "expected object with a kind discriminant");
  }
  const payloadHash = value["payloadHash"];
  if (typeof payloadHash !== "string") ctx.add("$.payloadHash", "expected string");
  const snapshotRevision = value["snapshotRevision"];
  if (typeof snapshotRevision !== "number" || !Number.isInteger(snapshotRevision)) {
    ctx.add("$.snapshotRevision", "expected integer");
  }
  const createdAt = value["createdAt"];
  if (typeof createdAt !== "number" || !Number.isInteger(createdAt)) {
    ctx.add("$.createdAt", "expected integer epoch seconds");
  }
  const expiresAt = value["expiresAt"];
  if (typeof expiresAt !== "number" || !Number.isInteger(expiresAt)) {
    ctx.add("$.expiresAt", "expected integer epoch seconds");
  }
  const requiredApproval = value["requiredApproval"];
  if (requiredApproval !== undefined && requiredApproval !== "device-auto" && requiredApproval !== "explicit") {
    ctx.add("$.requiredApproval", "expected device-auto or explicit");
  }
  const userInitiated = value["userInitiated"];
  if (userInitiated !== undefined && typeof userInitiated !== "boolean") {
    ctx.add("$.userInitiated", "expected boolean");
  }
  if (ctx.any()) throw new WireParseError(ctx.issues);
  return {
    id: id as string,
    tool: tool as ProposalTool,
    payload: payload as ProposalPayload,
    payloadHash: payloadHash as string,
    snapshotRevision: snapshotRevision as number,
    createdAt: epochSecondsFromWire(createdAt as number),
    expiresAt: epochSecondsFromWire(expiresAt as number),
    ...(requiredApproval === undefined ? {} : { requiredApproval: requiredApproval as RequiredApproval }),
    ...(typeof userInitiated === "boolean" ? { userInitiated } : {})
  };
}
