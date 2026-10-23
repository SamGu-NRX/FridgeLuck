/**
 * Server-side deletion of a community account (SPEC §3.4).
 *
 * The run is a durable plan stored at communityDeletionRuns/{accountId} (one
 * per account lifetime: ids are never reused — re-signing in creates a fresh
 * account). Every step records its completion as it lands, so an interrupted
 * run resumes where it stopped, partial progress is observable at any moment,
 * and a replay — sequential or concurrent — converges on the same end state:
 *
 * 1. block-and-revoke (step "sessions", one transaction): the account doc is
 *    marked deleting (deletionStartedAtIso) and every live session is
 *    revoked in the same commit. Session issuance and rotation read that
 *    marker inside their own transactions (sessionCore), so the deleting
 *    account can neither sign in nor refresh from this moment on — before
 *    the plan finishes, not only after;
 * 2. each part removes or tombstones the account's records through its own
 *    contributor (the seam in shared/contracts.ts) — the safety part's
 *    contributor removes the block pairs, explore withdraws publications and
 *    strips cook-occurrence keys, tables removes memberships and dissolves
 *    owned tables, challenges tombstones entries. Content records are
 *    tombstoned, not erased, where the spec keeps records that moderation
 *    and abuse history depend on; directory entries (memberships, block
 *    pairs) go outright. Steps the plan already records done are skipped;
 *    a step that re-runs anyway stays convergent because contributors
 *    tombstone or delete by query, and every timestamp derives from the
 *    plan's startedAtIso — a retry writes identical values;
 * 3. the account document itself is tombstoned: deletedAtIso set, the Apple
 *    sub and email erased (PII goes with deletion; the record id and
 *    timestamps survive so moderation history and ids stay coherent);
 *    re-signing in creates a fresh account, never resurrects this one;
 * 4. the plan is finalized (status "completed") in a transaction, so two
 *    concurrent runs — or a call after completion — converge on one record
 *    with one deletionRunId.
 */
import type { AccountDeletionContribution, AccountDeletionContributor } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errNotFound } from "../shared/errors.js";
import { parseAccountId, parseDeletionRunId, type AccountId, type DeletionRunId } from "../shared/ids.js";
import { DELETED_AT_FIELD, DELETION_STARTED_AT_FIELD, type SessionService } from "../shared/sessionCore.js";
import type { DocumentSnapshot, Transaction } from "@google-cloud/firestore";

/**
 * One step of the durable plan. The union keeps an impossible state out of
 * the model: a pending step carries no completion data, a done step always
 * carries its effect report and completion time.
 */
export type DeletionStepState =
  | { readonly status: "pending"; readonly part: string }
  | {
      readonly status: "done";
      readonly part: string;
      readonly recordsTouched: number;
      readonly detail: string | null;
      readonly finishedAtIso: string;
    };

/** The durable plan, as stored at communityDeletionRuns/{accountId}. */
export interface StoredDeletionRun {
  readonly deletionRunId: DeletionRunId;
  readonly accountId: AccountId;
  readonly status: "running" | "completed";
  readonly startedAtIso: string;
  readonly finishedAtIso: string | null;
  readonly steps: Record<string, DeletionStepState>;
}

/** What a finished run reports (a run() call only ever returns completed plans). */
export interface DeletionRunRecord {
  readonly deletionRunId: DeletionRunId;
  readonly accountId: AccountId;
  readonly startedAtIso: string;
  readonly finishedAtIso: string;
  readonly sessionsRevoked: boolean;
  readonly contributions: readonly AccountDeletionContribution[];
}

export interface DeletionDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
  readonly sessions: SessionService;
  readonly contributors: readonly AccountDeletionContributor[];
}

export interface AccountDeletionService {
  run(accountId: AccountId): Promise<DeletionRunRecord>;
}

/** The two bookkeeping steps the coordinator itself owns, around the contributors. */
const SESSIONS_STEP = "sessions";
const ACCOUNT_STEP = "account";

/** Map key for a step: part names may carry "/" (e.g. "explore/publications"); step keys must not carry ".". */
function stepKey(part: string): string {
  return part.replace(/[^A-Za-z0-9_-]/g, "_");
}

/**
 * The run id is derived from the account id, so concurrent and resumed runs
 * land on one plan document (and one audit id) by construction. Account ids
 * are never reused, so one plan per account lifetime is exact.
 */
function deletionRunIdForAccount(accountId: AccountId): DeletionRunId {
  return parseDeletionRunId.parse(`del_${accountId.slice("acct_".length)}`, "derived deletion run id");
}

function pendingStep(part: string): DeletionStepState {
  return { status: "pending", part };
}

function initialSteps(contributors: readonly AccountDeletionContributor[]): Record<string, DeletionStepState> {
  const steps: Record<string, DeletionStepState> = {
    [SESSIONS_STEP]: pendingStep(SESSIONS_STEP),
    [ACCOUNT_STEP]: pendingStep(ACCOUNT_STEP),
  };
  for (const contributor of contributors) {
    steps[stepKey(contributor.part)] = pendingStep(contributor.part);
  }
  return steps;
}

function planString(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw new Error(`deletion plan field ${field} is missing or malformed`);
  }
  return value;
}

function planOptionalString(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== "string") {
    throw new Error(`deletion plan field ${field} is malformed`);
  }
  return value;
}

function parseStepState(raw: unknown, key: string): DeletionStepState {
  if (typeof raw !== "object" || raw === null) {
    throw new Error(`deletion plan step ${key} is malformed`);
  }
  const data = raw as Record<string, unknown>;
  const part = planString(data, "part");
  if (data["status"] === "pending") {
    return { status: "pending", part };
  }
  if (data["status"] === "done") {
    const recordsTouched = data["recordsTouched"];
    if (typeof recordsTouched !== "number") {
      throw new Error(`deletion plan step ${key} recordsTouched is malformed`);
    }
    return {
      status: "done",
      part,
      recordsTouched,
      detail: planOptionalString(data, "detail"),
      finishedAtIso: planString(data, "finishedAtIso"),
    };
  }
  throw new Error(`deletion plan step ${key} status is malformed`);
}

/** Firestore documents are read through validating parsers (the parseSessionDoc pattern). */
function parseStoredDeletionRun(snap: DocumentSnapshot): StoredDeletionRun {
  const data = snap.data() as Record<string, unknown> | undefined;
  if (data === undefined) {
    throw new Error("deletion plan document has no data");
  }
  const status = data["status"];
  if (status !== "running" && status !== "completed") {
    throw new Error(`deletion plan status is malformed: ${String(status)}`);
  }
  const stepsRaw = data["steps"];
  if (typeof stepsRaw !== "object" || stepsRaw === null) {
    throw new Error("deletion plan steps are missing");
  }
  const steps: Record<string, DeletionStepState> = {};
  for (const [key, raw] of Object.entries(stepsRaw as Record<string, unknown>)) {
    steps[key] = parseStepState(raw, key);
  }
  return {
    deletionRunId: parseDeletionRunId.parse(planString(data, "deletionRunId"), "deletion plan"),
    accountId: parseAccountId.parse(planString(data, "accountId"), "deletion plan"),
    status,
    startedAtIso: planString(data, "startedAtIso"),
    finishedAtIso: planOptionalString(data, "finishedAtIso"),
    steps,
  };
}

/**
 * Opens (or reopens) the durable plan. Concurrency-safe by the deterministic
 * document id: the loser of a create race resumes the winner's plan.
 */
async function openDeletionPlan(deps: DeletionDeps, accountId: AccountId): Promise<StoredDeletionRun> {
  const ref = deps.store.deletionRuns.doc(accountId);
  const existing = await ref.get();
  if (existing.exists) {
    return parseStoredDeletionRun(existing);
  }
  const plan: StoredDeletionRun = {
    deletionRunId: deletionRunIdForAccount(accountId),
    accountId,
    status: "running",
    startedAtIso: toIso(deps.clock.now()),
    finishedAtIso: null,
    steps: initialSteps(deps.contributors),
  };
  try {
    await ref.create(plan);
    return plan;
  } catch (error) {
    const winner = await ref.get();
    if (!winner.exists) {
      throw error;
    }
    return parseStoredDeletionRun(winner);
  }
}

/** Per-step completion write: dot-paths update one step's map entry without touching its siblings. */
async function markStepDone(deps: DeletionDeps, accountId: AccountId, key: string, step: DeletionStepState): Promise<void> {
  await deps.store.deletionRuns.doc(accountId).update({
    [`steps.${key}`]: step,
  } as Record<string, unknown>);
}

/** The report for a finished plan: contributions in contributor order, from the plan's recorded steps. */
function completedRecord(deps: DeletionDeps, plan: StoredDeletionRun): DeletionRunRecord {
  if (plan.finishedAtIso === null) {
    throw new Error("a completed deletion plan must carry finishedAtIso");
  }
  const contributions: AccountDeletionContribution[] = [];
  for (const contributor of deps.contributors) {
    const step = plan.steps[stepKey(contributor.part)];
    if (step !== undefined && step.status === "done") {
      contributions.push({ part: contributor.part, recordsTouched: step.recordsTouched, detail: step.detail });
    }
  }
  return {
    deletionRunId: plan.deletionRunId,
    accountId: plan.accountId,
    startedAtIso: plan.startedAtIso,
    finishedAtIso: plan.finishedAtIso,
    sessionsRevoked: plan.steps[SESSIONS_STEP]?.status === "done",
    contributions,
  };
}

async function finalizeDeletionPlan(deps: DeletionDeps, accountId: AccountId): Promise<DeletionRunRecord> {
  const finishedAtIso = toIso(deps.clock.now());
  const plan = await deps.store.firestore.runTransaction(async (tx: Transaction): Promise<StoredDeletionRun> => {
    const ref = deps.store.deletionRuns.doc(accountId);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new Error("deletion plan vanished before finalization");
    }
    const current = parseStoredDeletionRun(snap);
    if (current.status === "completed") {
      return current;
    }
    tx.update(ref, { status: "completed", finishedAtIso });
    return { ...current, status: "completed", finishedAtIso };
  });
  return completedRecord(deps, plan);
}

/** Partial progress is observable: the durable plan as stored, or null when no deletion ever started. */
export async function readDeletionRunRecord(store: CommunityStore, accountId: AccountId): Promise<StoredDeletionRun | null> {
  const snap = await store.deletionRuns.doc(accountId).get();
  return snap.exists ? parseStoredDeletionRun(snap) : null;
}

export async function runAccountDeletion(deps: DeletionDeps, accountId: AccountId): Promise<DeletionRunRecord> {
  const parsedId = parseAccountId.parse(accountId, "account id");
  const plan = await openDeletionPlan(deps, parsedId);
  if (plan.status === "completed") {
    // Replay after completion: the plan is the record; no step re-runs and
    // no tombstone is re-stamped.
    return completedRecord(deps, plan);
  }

  // 1. Lock the account out first: the marker and the revocations commit
  //    together, so nothing below can be exercised by the deleted account.
  if (plan.steps[SESSIONS_STEP]?.status !== "done") {
    const revoked = await deps.sessions.blockForDeletion(parsedId, plan.startedAtIso);
    await markStepDone(deps, parsedId, SESSIONS_STEP, {
      status: "done",
      part: SESSIONS_STEP,
      recordsTouched: revoked,
      detail: `${revoked} sessions revoked; account blocked from new sessions`,
      finishedAtIso: toIso(deps.clock.now()),
    });
  }

  // 2. Each part tombstones (or removes) its records. Already-done parts
  //    keep their recorded contribution — the resume never double-applies.
  for (const contributor of deps.contributors) {
    const key = stepKey(contributor.part);
    if (plan.steps[key]?.status === "done") {
      continue;
    }
    const contribution = await contributor.run(parsedId, plan.startedAtIso);
    await markStepDone(deps, parsedId, key, {
      status: "done",
      part: contributor.part,
      recordsTouched: contribution.recordsTouched,
      detail: contribution.detail,
      finishedAtIso: toIso(deps.clock.now()),
    });
  }

  // 3. The account document itself is tombstoned. Rewriting the same values
  //    is the convergence guarantee: a resumed run stamps the plan's start,
  //    never a fresh timestamp.
  const accountKey = plan.steps[ACCOUNT_STEP];
  if (accountKey?.status !== "done") {
    const accountDoc = deps.store.accounts.doc(parsedId);
    const accountSnap = await accountDoc.get();
    if (!accountSnap.exists) {
      throw errNotFound("account not found");
    }
    await accountDoc.update({
      [DELETION_STARTED_AT_FIELD]: plan.startedAtIso,
      [DELETED_AT_FIELD]: plan.startedAtIso,
      appleSub: null,
      email: null,
      displayName: null,
    });
    await markStepDone(deps, parsedId, ACCOUNT_STEP, {
      status: "done",
      part: ACCOUNT_STEP,
      recordsTouched: 1,
      detail: "account tombstoned; PII erased",
      finishedAtIso: toIso(deps.clock.now()),
    });
  }

  // 4. Finalize transactionally: exactly one run stamps the finish.
  return finalizeDeletionPlan(deps, parsedId);
}

/** The safety part's own share of the deletion: block pairs are removed. */
export function blockDirectoryCleanupContributor(store: CommunityStore): AccountDeletionContributor {
  return {
    part: "safety/blocks",
    async run(accountId: AccountId): Promise<AccountDeletionContribution> {
      const [asA, asB] = await Promise.all([
        store.blocks.where("a", "==", accountId).get(),
        store.blocks.where("b", "==", accountId).get(),
      ]);
      const docs = [...asA.docs, ...asB.docs];
      for (const doc of docs) {
        await doc.ref.delete();
      }
      return { part: "safety/blocks", recordsTouched: docs.length, detail: "block pairs removed" };
    },
  };
}

export function createAccountDeletionService(deps: DeletionDeps): AccountDeletionService {
  return { run: (accountId) => runAccountDeletion(deps, accountId) };
}
