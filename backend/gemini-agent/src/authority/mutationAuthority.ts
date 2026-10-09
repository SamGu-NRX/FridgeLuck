import { createHash, randomUUID } from "node:crypto";
import type { InventoryItem } from "../types/contracts.js";

// Authority boundary for inventory mutations.
//
// Before this module existed, the only thing standing between a model tool
// call and a ledger write was prompt text ("only call this AFTER the user has
// confirmed"). This module makes the boundary structural:
//
// 1. The model can only PROPOSE. `validateProposalArgs` reads operation and
//    items and nothing else — any field the model adds (`confirmed: true`,
//    `approved: "yes"`, `userConfirmation: …`) is dropped by construction and
//    can never influence execution.
// 2. Only the trusted client (the phone) can move a proposal forward, via the
//    session's own WebSocket: `confirm` / `cancel` envelopes. No model
//    argument and no HTTP route reaches these methods.
// 3. Execution uses the proposal id as the ledger idempotency key, so a
//    retried confirm (crash, reconnect, duplicate envelope) is a no-op, and
//    the audit trail ties one approval to at most one applied mutation.
//
// Identity model (deliberate): there is NO account system and NO app-embedded
// secret. The capability is the server-minted, unguessable session id issued
// on connect; a session's proposals are only reachable on that session's own
// WebSocket connection and via that session's scoped ledger. Anyone who can
// reach the server can create a NEW empty session (bounded, rate-limited);
// nobody can attach to a session they were not issued. This is documented as
// a residual-risk release decision in HARDENING.md, not hidden.

/** Operations a proposal may request. The model supplies this string. */
export type MutationOperation = "add" | "decrement";

export interface ValidatedMutationItem {
  ingredientName: string;
  quantityGrams: number;
  expiresAt?: string;
  source?: "scan" | "manual" | "restock";
}

export interface ValidatedProposal {
  operation: MutationOperation;
  items: ValidatedMutationItem[];
}

/**
 * A proposal-rejection reason. These are stable codes — the strings the
 * client and the model see — never provider text or payload echoes.
 */
export type ProposalRejectionReason =
  | "unknown_proposal"
  | "already_resolved"
  | "expired"
  | "cancelled";

export interface MutationProposal {
  readonly id: string;
  readonly sessionId: string;
  readonly operation: MutationOperation;
  readonly items: ValidatedMutationItem[];
  readonly payloadHash: string;
  readonly requestedAtMs: number;
  readonly expiresAtMs: number;
}

export interface ProposalCreateResult {
  proposal: MutationProposal;
  /** True when an identical pending proposal already existed (dedupe). */
  duplicate: boolean;
}

export type ProposalConfirmOutcome =
  | { ok: true; proposal: MutationProposal }
  | { ok: false; reason: ProposalRejectionReason };

export type ProposalCancelOutcome =
  | { ok: true; proposal: MutationProposal }
  | { ok: false; reason: ProposalRejectionReason };

// ─── Bounds (aligned with src/http/validate.ts) ─────────────────────────────

export const MUTATION_MAX_ITEMS = 25;
export const MUTATION_NAME_MAX_CHARS = 120;
export const MUTATION_QUANTITY_MAX_GRAMS = 1_000_000;
export const MUTATION_IDEMPOTENCY_KEY_MAX_CHARS = 256;
export const MUTATION_EXPIRY_MAX_CHARS = 40;

const MUTATION_SOURCES = new Set(["scan", "manual", "restock"]);

// ISO 8601: date-only ("2026-03-12") or full timestamp ("2026-03-12T06:00:00Z").
const ISO_DATE_PATTERN =
  /^\d{4}-\d{2}-\d{2}([Tt]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:?\d{2})?)?$/;

// C0 control characters, DEL, and Unicode line/paragraph separators.
const NO_CONTROL_CHARS = /^[^\u0000-\u001F\u007F-\u009F]*$/;

/**
 * Raised for malformed proposal payloads. The message is static, generated
 * from the validator's own text — never a echo of the offending value — so it
 * is safe to hand back to the model as a tool error.
 */
export class MutationProposalError extends Error {
  readonly field?: string;

  constructor(message: string, field?: string) {
    super(message);
    this.name = "MutationProposalError";
    this.field = field;
  }
}

function fail(field: string, requirement: string): never {
  throw new MutationProposalError(
    `mutate proposal rejected: ${field} ${requirement}`,
    field
  );
}

/**
 * Validates the args a model passed to the proposal tool. Everything not
 * recognized is DROPPED — including any confirmation-shaped field. A model
 * cannot approve its own mutation by adding arguments; this function is the
 * reason.
 */
export function validateProposalArgs(
  args: Record<string, unknown>
): ValidatedProposal {
  const operation = args.operation;
  if (operation !== "add" && operation !== "decrement") {
    fail("operation", "must be 'add' or 'decrement'.");
  }

  if (!Array.isArray(args.items) || args.items.length === 0) {
    fail("items", "must be a non-empty array.");
  }
  if (args.items.length > MUTATION_MAX_ITEMS) {
    fail("items", `must contain at most ${MUTATION_MAX_ITEMS} entries.`);
  }

  const items: ValidatedMutationItem[] = args.items.map(
    (raw, index): ValidatedMutationItem => {
      if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
        fail(`items[${index}]`, "must be an object.");
      }
      const entry = raw as Record<string, unknown>;

      const ingredientName = entry.ingredientName;
      if (
        typeof ingredientName !== "string" ||
        ingredientName.length === 0 ||
        ingredientName.length > MUTATION_NAME_MAX_CHARS ||
        !NO_CONTROL_CHARS.test(ingredientName)
      ) {
        fail(
          `items[${index}].ingredientName`,
          `must be a string of 1-${MUTATION_NAME_MAX_CHARS} characters without control characters.`
        );
      }

      const quantityGrams = entry.quantityGrams;
      if (
        typeof quantityGrams !== "number" ||
        !Number.isFinite(quantityGrams) ||
        quantityGrams < 0
      ) {
        fail(`items[${index}].quantityGrams`, "must be a finite number >= 0.");
      }
      if (quantityGrams > MUTATION_QUANTITY_MAX_GRAMS) {
        fail(
          `items[${index}].quantityGrams`,
          `must be at most ${MUTATION_QUANTITY_MAX_GRAMS}.`
        );
      }

      // Unknown fields (including confirmation claims) are not read — they
      // are dropped by simply never copying them.

      const validated: ValidatedMutationItem = {
        ingredientName: ingredientName as string,
        quantityGrams: quantityGrams as number
      };

      const expiresAt = entry.expiresAt;
      if (expiresAt !== undefined) {
        if (
          typeof expiresAt !== "string" ||
          expiresAt.length === 0 ||
          expiresAt.length > MUTATION_EXPIRY_MAX_CHARS ||
          !NO_CONTROL_CHARS.test(expiresAt) ||
          !ISO_DATE_PATTERN.test(expiresAt) ||
          // The pattern allows it; the calendar must agree.
          Number.isNaN(new Date(expiresAt).getTime())
        ) {
          fail(
            `items[${index}].expiresAt`,
            "must be an ISO 8601 date or timestamp."
          );
        }
        validated.expiresAt = expiresAt as string;
      }

      const source = entry.source;
      if (source !== undefined) {
        if (
          typeof source !== "string" ||
          !MUTATION_SOURCES.has(source)
        ) {
          fail(
            `items[${index}].source`,
            "must be one of 'scan', 'manual', 'restock'."
          );
        }
        validated.source = source as ValidatedMutationItem["source"];
      }

      return validated;
    }
  );

  return { operation, items };
}

/**
 * Deterministic hash of a validated proposal: operation + canonical JSON of
 * the items (sorted keys, array order preserved). Two model calls that ask
 * for the same mutation produce the same hash, which is how duplicate tool
 * calls dedupe onto one pending proposal instead of stacking approvals.
 */
export function proposalPayloadHash(
  operation: MutationOperation,
  items: ValidatedMutationItem[]
): string {
  const canonical = JSON.stringify(
    items.map((item) => ({
      expiresAt: item.expiresAt ?? null,
      ingredientName: item.ingredientName,
      quantityGrams: item.quantityGrams,
      source: item.source ?? null
    }))
  );
  return createHash("sha256")
    .update(`${operation}\n${canonical}`)
    .digest("hex");
}

interface ResolvedRecord {
  status: "executed" | "cancelled";
  resolvedAtMs: number;
  proposal: MutationProposal;
}

export interface MutationProposalStoreOptions {
  /** Proposal lifetime in ms. Default: 5 minutes. */
  ttlMs?: number;
  /** Maximum pending proposals kept per session. Default: 20. */
  maxPendingPerSession?: number;
  /** Maximum sessions with pending/resolved state. Default: 500. */
  maxSessions?: number;
  /** Clock source (ms). Tests inject a controllable clock. */
  now?: () => number;
}

export const PROPOSAL_TTL_MS_DEFAULT = 5 * 60 * 1000;
export const PROPOSALS_MAX_PENDING_PER_SESSION = 20;
export const PROPOSALS_MAX_SESSIONS = 500;

/**
 * In-memory, session-scoped proposal store. Memory-only BY DESIGN: a process
 * restart forgets pending proposals, and an unconfirmed proposal is by
 * definition nothing but a draft — forgetting it is the safe direction.
 * (Camera frames under PR packet026 made the same trade.)
 */
export class MutationProposalStore {
  private readonly pending = new Map<string, Map<string, MutationProposal>>();
  private readonly resolved = new Map<string, ResolvedRecord>();
  private readonly ttlMs: number;
  private readonly maxPendingPerSession: number;
  private readonly maxSessions: number;
  private readonly now: () => number;

  constructor(options: MutationProposalStoreOptions = {}) {
    this.ttlMs = options.ttlMs ?? PROPOSAL_TTL_MS_DEFAULT;
    this.maxPendingPerSession =
      options.maxPendingPerSession ?? PROPOSALS_MAX_PENDING_PER_SESSION;
    this.maxSessions = options.maxSessions ?? PROPOSALS_MAX_SESSIONS;
    this.now = options.now ?? Date.now;
  }

  /**
   * Registers (or dedupes onto) a pending proposal for this session.
   * Validated items only — callers must have run validateProposalArgs.
   */
  create(
    sessionId: string,
    validated: ValidatedProposal
  ): ProposalCreateResult {
    this.sweep();

    const payloadHash = proposalPayloadHash(validated.operation, validated.items);
    const sessionPending = this.pending.get(sessionId);

    if (sessionPending) {
      for (const existing of sessionPending.values()) {
        if (existing.payloadHash === payloadHash) {
          return { proposal: existing, duplicate: true };
        }
      }
    }

    const nowMs = this.now();
    const proposal: MutationProposal = {
      id: randomUUID(),
      sessionId,
      operation: validated.operation,
      items: validated.items,
      payloadHash,
      requestedAtMs: nowMs,
      expiresAtMs: nowMs + this.ttlMs
    };

    if (!sessionPending) {
      if (this.pending.size >= this.maxSessions) {
        this.evictOldestSession();
      }
      this.pending.set(sessionId, new Map());
    }

    const bucket = this.pending.get(sessionId)!;
    if (bucket.size >= this.maxPendingPerSession) {
      // Drop the soonest-to-expire pending proposal to make room: the model
      // can re-propose, and an old unconfirmed draft is worthless.
      let oldestId: string | undefined;
      let oldestExpiry = Number.POSITIVE_INFINITY;
      for (const [id, candidate] of bucket) {
        if (candidate.expiresAtMs < oldestExpiry) {
          oldestExpiry = candidate.expiresAtMs;
          oldestId = id;
        }
      }
      if (oldestId !== undefined) bucket.delete(oldestId);
    }
    bucket.set(proposal.id, proposal);

    return { proposal, duplicate: false };
  }

  /** Client approval for a pending proposal (the only execution gate). */
  confirm(sessionId: string, proposalId: string): ProposalConfirmOutcome {
    return this.resolve(sessionId, proposalId, "executed");
  }

  /** Client cancellation of a pending proposal. */
  cancel(sessionId: string, proposalId: string): ProposalCancelOutcome {
    return this.resolve(sessionId, proposalId, "cancelled");
  }

  private resolve(
    sessionId: string,
    proposalId: string,
    outcome: "executed" | "cancelled"
  ): ProposalConfirmOutcome {
    this.sweep();

    const proposal = this.pending.get(sessionId)?.get(proposalId);
    if (proposal) {
      this.pending.get(sessionId)!.delete(proposalId);
      this.rememberResolved(proposal, outcome);
      return { ok: true, proposal };
    }

    // Not pending. Distinguish the reasons the client can act on.
    if (this.resolved.has(proposalId)) {
      return { ok: false, reason: "already_resolved" };
    }
    return { ok: false, reason: "unknown_proposal" };
  }

  private rememberResolved(
    proposal: MutationProposal,
    status: "executed" | "cancelled"
  ): void {
    if (this.resolved.size >= this.maxSessions * 2) {
      // Bound the ledger of resolved ids; drop the oldest entry.
      const oldest = this.resolved.keys().next().value;
      if (oldest !== undefined) this.resolved.delete(oldest);
    }
    this.resolved.set(proposal.id, {
      status,
      resolvedAtMs: this.now(),
      proposal
    });
  }

  pendingCount(sessionId?: string): number {
    if (sessionId !== undefined) {
      return this.pending.get(sessionId)?.size ?? 0;
    }
    let total = 0;
    for (const bucket of this.pending.values()) total += bucket.size;
    return total;
  }

  size(): number {
    return this.pending.size;
  }

  /** Drops expired pending proposals and stale resolved records. */
  sweep(): void {
    const nowMs = this.now();

    for (const [sessionId, bucket] of this.pending) {
      for (const [id, proposal] of bucket) {
        if (proposal.expiresAtMs <= nowMs) {
          bucket.delete(id);
        }
      }
      if (bucket.size === 0) this.pending.delete(sessionId);
    }

    for (const [id, record] of this.resolved) {
      if (nowMs - record.resolvedAtMs > this.ttlMs * 2) {
        this.resolved.delete(id);
      }
    }
  }

  private evictOldestSession(): void {
    let oldestId: string | undefined;
    let oldestActivity = Number.POSITIVE_INFINITY;
    for (const [sessionId, bucket] of this.pending) {
      let newestExpiry = 0;
      for (const proposal of bucket.values()) {
        newestExpiry = Math.max(newestExpiry, proposal.expiresAtMs);
      }
      if (newestExpiry < oldestActivity) {
        oldestActivity = newestExpiry;
        oldestId = sessionId;
      }
    }
    if (oldestId !== undefined) this.pending.delete(oldestId);
  }
}
