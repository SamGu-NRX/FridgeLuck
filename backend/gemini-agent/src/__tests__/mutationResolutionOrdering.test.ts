import { describe, it, expect } from "bun:test";
import {
  MutationProposalStore,
  validateProposalArgs,
  type ValidatedProposal,
} from "../authority/mutationAuthority.js";

// Resolution-ordering proofs for the mutation execution gate.
//
// Invariant under test (the review finding on PR #94): the store marks an
// execution resolved — the point past which a repeated confirm is refused
// with already_resolved — ONLY after the apply callback commits the effect.
// An apply that throws must leave the execution unresolved (the client's
// confirm is not burned; the proposal stays pending and cancellable) and
// surface the original error to the caller.

const BASE_MS = Date.parse("2026-01-15T10:00:00.000Z");

function makeStore(): MutationProposalStore {
  let current = BASE_MS;
  return new MutationProposalStore({ now: () => current });
}

function validProposal(
  store: MutationProposalStore,
  sessionId = "session-1"
) {
  const validated: ValidatedProposal = validateProposalArgs({
    operation: "add",
    items: [{ ingredientName: "tomato", quantityGrams: 500, source: "scan" }],
  });
  const { proposal } = store.create(sessionId, validated);
  return proposal;
}

describe("mutation resolution ordering (resolution follows the committed effect)", () => {
  it("applies the operation first and marks the execution resolved only after the effect commits", () => {
    const store = makeStore();
    const proposal = validProposal(store);
    const order: string[] = [];

    const outcome = store.confirm("session-1", proposal.id, (p) => {
      // Observed DURING the apply: the proposal is still pending — the
      // execution is not yet resolved while the effect is being committed.
      order.push(`apply:pending=${store.pendingCount("session-1")}`);
      expect(p.id).toBe(proposal.id);
      return { committed: true };
    });
    order.push(`returned:pending=${store.pendingCount("session-1")}`);

    expect(outcome.ok).toBe(true);
    if (outcome.ok) {
      expect(outcome.applied).toEqual({ committed: true });
      expect(outcome.proposal.id).toBe(proposal.id);
    }
    // The apply observed an unresolved (pending) execution; by the time
    // confirm returned, the effect had committed and the execution resolved.
    expect(order).toEqual(["apply:pending=1", "returned:pending=0"]);

    // Resolved past this point: a further confirm is already_resolved and
    // never re-applies (its callback would throw if the store ran it).
    const again = store.confirm("session-1", proposal.id, () => {
      throw new Error("apply must not run for an already-resolved execution");
    });
    expect(again).toEqual({ ok: false, reason: "already_resolved" });
  });

  it("an apply failure leaves the execution unresolved and surfaces the error", () => {
    const store = makeStore();
    const proposal = validProposal(store);
    const boom = new Error("ledger write failed");

    let thrown: unknown;
    try {
      store.confirm("session-1", proposal.id, () => {
        throw boom;
      });
    } catch (err) {
      thrown = err;
    }
    // The ORIGINAL error surfaces to the caller — not a collapse, not a
    // rejection outcome.
    expect(thrown).toBe(boom);

    // Unresolved: still pending — not burned as executed, not unknown.
    expect(store.pendingCount("session-1")).toBe(1);

    // The client can confirm again; the retried apply commits.
    const retry = store.confirm("session-1", proposal.id, () => ({
      committed: true,
    }));
    expect(retry.ok).toBe(true);
    expect(store.pendingCount("session-1")).toBe(0);

    const repeat = store.confirm("session-1", proposal.id, () => {
      throw new Error("apply must not run for an already-resolved execution");
    });
    expect(repeat).toEqual({ ok: false, reason: "already_resolved" });
  });

  it("a failed apply restores the pre-confirm state exactly: the proposal is still cancellable", () => {
    const store = makeStore();
    const proposal = validProposal(store);

    expect(() =>
      store.confirm("session-1", proposal.id, () => {
        throw new Error("ledger write failed");
      })
    ).toThrow("ledger write failed");

    // The user changes their mind after the failed confirm: cancel works,
    // because the execution never resolved.
    const cancelled = store.cancel("session-1", proposal.id);
    expect(cancelled.ok).toBe(true);
    expect(store.pendingCount("session-1")).toBe(0);

    const after = store.confirm("session-1", proposal.id, () => {
      throw new Error("apply must not run for a cancelled proposal");
    });
    expect(after).toEqual({ ok: false, reason: "already_resolved" });
  });

  it("an idempotent re-run of a committed execution is refused without re-applying", () => {
    const store = makeStore();
    const proposal = validProposal(store);
    let applies = 0;

    const first = store.confirm("session-1", proposal.id, () => {
      applies += 1;
      return { committed: true };
    });
    expect(first.ok).toBe(true);

    // A duplicate envelope (crash, reconnect, retried confirm) — the safe
    // answer is the stable already_resolved refusal, not a second apply.
    const second = store.confirm("session-1", proposal.id, () => {
      applies += 1;
      return { committed: true };
    });
    expect(second).toEqual({ ok: false, reason: "already_resolved" });
    expect(applies).toBe(1);

    // Cancel cannot resurrect it either.
    const cancelled = store.cancel("session-1", proposal.id);
    expect(cancelled).toEqual({ ok: false, reason: "already_resolved" });
  });
});
