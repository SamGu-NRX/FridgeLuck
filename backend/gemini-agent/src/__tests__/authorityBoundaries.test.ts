import { describe, expect, it } from "bun:test";
import {
  MutationProposalError,
  MutationProposalStore,
  validateProposalArgs,
  type ValidatedProposal,
} from "../authority/mutationAuthority.js";

// ─── Harness ─────────────────────────────────────────────────────────────────

const BASE_MS = Date.parse("2026-01-15T10:00:00.000Z");

function makeClock(startMs: number = BASE_MS) {
  let current = startMs;
  return {
    now: () => current,
    advance: (ms: number) => {
      current += ms;
    },
  };
}

function validArgs(): Record<string, unknown> {
  return {
    operation: "add",
    items: [{ ingredientName: "tomato", quantityGrams: 500, source: "scan" }],
  };
}

/**
 * Proof harness for backend/gemini-agent/docs/AUTHORITY.md. Each test maps to
 * a boundary row in that file and asserts the SPECIFIC refusal the boundary
 * produces — never a generic error.
 */
describe("authority boundaries (AUTHORITY.md proof)", () => {
  it("the model cannot approve its own mutation: confirmation-shaped fields are dropped from tool args", () => {
    const validated: ValidatedProposal = validateProposalArgs({
      ...validArgs(),
      confirmed: true,
      userApproved: true,
      executed: true,
      approvalReceipt: "forged-by-the-model",
      proposalId: "self-assigned",
    });

    // Only the validated operation/items survive; every confirmation claim
    // was dropped by never being copied.
    expect("confirmed" in validated).toBe(false);
    expect("userApproved" in validated).toBe(false);
    expect("executed" in validated).toBe(false);
    expect("approvalReceipt" in validated).toBe(false);
    expect("proposalId" in validated).toBe(false);
    expect(JSON.stringify(validated)).not.toContain("forged-by-the-model");
    expect(validated.operation).toBe("add");
    expect(validated.items).toHaveLength(1);
  });

  it("refuses malformed proposal args with a specific field, not a generic error", () => {
    const cases: Array<{ args: Record<string, unknown>; field: string }> = [
      { args: { ...validArgs(), operation: "delete" }, field: "operation" },
      { args: { operation: "add" }, field: "items" },
      {
        args: { operation: "add", items: [] },
        field: "items",
      },
      {
        args: {
          operation: "add",
          items: Array.from({ length: 26 }, (_, i) => ({
            ingredientName: `item-${i}`,
            quantityGrams: 1,
          })),
        },
        field: "items",
      },
      {
        args: { operation: "add", items: ["not-an-object"] },
        field: "items[0]",
      },
      {
        args: {
          operation: "add",
          items: [{ ingredientName: "tomato", quantityGrams: -5 }],
        },
        field: "items[0].quantityGrams",
      },
      {
        args: {
          operation: "add",
          items: [
            { ingredientName: "tomato", quantityGrams: 5, source: "cloud" },
          ],
        },
        field: "items[0].source",
      },
      {
        args: {
          operation: "add",
          items: [
            { ingredientName: "tomato", quantityGrams: 5, expiresAt: "12/03/2026" },
          ],
        },
        field: "items[0].expiresAt",
      },
    ];
    for (const { args, field } of cases) {
      let caught: unknown;
      try {
        validateProposalArgs(args);
      } catch (error) {
        caught = error;
      }
      expect(caught).toBeInstanceOf(MutationProposalError);
      const rejection = caught as MutationProposalError;
      // The specific, machine-checkable refusal: the field that failed.
      expect(rejection.field).toBe(field);
      // Static validator text only — never a value echo.
      expect(rejection.message.startsWith("mutate proposal rejected:")).toBe(true);
    }
  });

  it("confirm is refused with unknown_proposal for unknown ids and other sessions' proposals", () => {
    const clock = makeClock();
    const store = new MutationProposalStore({ now: clock.now });
    const { proposal } = store.create("session-1", validateProposalArgs(validArgs()));

    const otherSession = store.confirm("session-2", proposal.id);
    expect(otherSession).toEqual({ ok: false, reason: "unknown_proposal" });

    const wrongId = store.confirm("session-1", "not-a-real-proposal-id");
    expect(wrongId).toEqual({ ok: false, reason: "unknown_proposal" });
  });

  it("executes at most once: a second confirm is refused with already_resolved, and cancel closes the same door", () => {
    const clock = makeClock();
    const store = new MutationProposalStore({ now: clock.now });
    const { proposal } = store.create("session-1", validateProposalArgs(validArgs()));

    const first = store.confirm("session-1", proposal.id);
    expect(first.ok).toBe(true);

    const second = store.confirm("session-1", proposal.id);
    expect(second).toEqual({ ok: false, reason: "already_resolved" });

    const { proposal: cancelProposal } = store.create(
      "session-1",
      validateProposalArgs(validArgs())
    );
    const cancelled = store.cancel("session-1", cancelProposal.id);
    expect(cancelled.ok).toBe(true);
    const confirmAfterCancel = store.confirm("session-1", cancelProposal.id);
    expect(confirmAfterCancel).toEqual({ ok: false, reason: "already_resolved" });
  });

  it("an unconfirmed proposal dies at its TTL: confirm after expiry is refused", () => {
    const clock = makeClock();
    const store = new MutationProposalStore({ now: clock.now, ttlMs: 5 * 60 * 1000 });
    const { proposal } = store.create("session-1", validateProposalArgs(validArgs()));

    clock.advance(5 * 60 * 1000 + 1);
    const outcome = store.confirm("session-1", proposal.id);
    // Swept on the next resolve — the refusal is the safe direction, with a
    // stable code the client can act on.
    expect(outcome).toEqual({ ok: false, reason: "unknown_proposal" });
  });

  it("re-proposing an identical pending payload dedupes onto the same proposal (idempotent proposals)", () => {
    const clock = makeClock();
    const store = new MutationProposalStore({ now: clock.now });
    const first = store.create("session-1", validateProposalArgs(validArgs()));
    const second = store.create("session-1", validateProposalArgs(validArgs()));

    expect(second.duplicate).toBe(true);
    expect(second.proposal.id).toBe(first.proposal.id);
    // A different payload is a different proposal.
    const third = store.create(
      "session-1",
      validateProposalArgs({
        operation: "add",
        items: [{ ingredientName: "onion", quantityGrams: 100 }],
      })
    );
    expect(third.duplicate).toBe(false);
    expect(third.proposal.id).not.toBe(first.proposal.id);
  });
});
