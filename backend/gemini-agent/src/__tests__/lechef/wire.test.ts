import { describe, it, expect } from "bun:test";
import { createHash } from "node:crypto";
import {
  canonicalWireJson,
  canonicalJsonString,
  payloadHash,
  serializeActionProposal,
  serializeActionReceipt,
  parseActionProposalWire,
  parseActionReceiptWire,
  WireParseError
} from "../../lechef/wire.js";

// Exact bytes from origin/overhaul/core-foundation
// packages/FridgeLuckCore/Fixtures/{action-proposal,action-receipt}.json —
// Swift JSONEncoder [.prettyPrinted, .sortedKeys], epoch-second timestamps,
// no trailing newline.
const PROPOSAL_FIXTURE_BYTES = `{
  "createdAt" : 813412800,
  "expiresAt" : 813415500,
  "id" : "proposal-fix-1",
  "payload" : {
    "kind" : "stepAdvance",
    "stepIndex" : 2
  },
  "payloadHash" : "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
  "snapshotRevision" : 3,
  "tool" : "proposeStepAdvance"
}`;

const RECEIPT_FIXTURE_BYTES = `{
  "payloadHash" : "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
  "proposalID" : "proposal-fix-1",
  "recordedAt" : 813414600,
  "snapshotRevision" : 3,
  "state" : "executed"
}`;

describe("wire: fixture round-trips are byte-identical", () => {
  it("round-trips action-proposal.json byte for byte", () => {
    const parsed = parseActionProposalWire(JSON.parse(PROPOSAL_FIXTURE_BYTES));
    expect(parsed.id).toBe("proposal-fix-1");
    expect(parsed.tool).toBe("proposeStepAdvance");
    expect(parsed.createdAt).toBe(813412800);
    expect(parsed.expiresAt).toBe(813415500);
    expect(parsed.snapshotRevision).toBe(3);
    // The frozen fixtures predate the additive fields: parsing must not invent them.
    expect(parsed.requiredApproval).toBeUndefined();
    expect(parsed.userInitiated).toBeUndefined();
    expect(serializeActionProposal(parsed)).toBe(PROPOSAL_FIXTURE_BYTES);
  });

  it("round-trips action-receipt.json byte for byte", () => {
    const parsed = parseActionReceiptWire(JSON.parse(RECEIPT_FIXTURE_BYTES));
    expect(parsed.proposalID).toBe("proposal-fix-1"); // capital ID, per fixture
    expect(parsed.state).toBe("executed");
    expect(parsed.recordedAt).toBe(813414600);
    expect(serializeActionReceipt(parsed)).toBe(RECEIPT_FIXTURE_BYTES);
  });

  it("emits additive fields only when set, keeping the seven-field fixture shape reachable", () => {
    const base = parseActionProposalWire(JSON.parse(PROPOSAL_FIXTURE_BYTES));
    const withAdditives = { ...base, requiredApproval: "explicit" as const, userInitiated: true };
    const bytes = serializeActionProposal(withAdditives);
    expect(bytes).toContain('"requiredApproval" : "explicit"');
    expect(bytes).toContain('"userInitiated" : true');
    expect(bytes).toContain('"tool" : "proposeStepAdvance"');
  });
});

describe("wire: payloadHash canonicalization", () => {
  it("is sha256 over compact, recursively key-sorted JSON", () => {
    expect(payloadHash({ kind: "stepAdvance", stepIndex: 2 })).toBe(
      createHash("sha256").update('{"kind":"stepAdvance","stepIndex":2}').digest("hex")
    );
  });

  it("is independent of key insertion order", () => {
    const a = payloadHash({ kind: "note", text: "hi", scope: "cook" });
    const b = payloadHash({ scope: "cook", text: "hi", kind: "note" });
    expect(a).toBe(b);
  });

  it("sorts nested objects recursively", () => {
    const a = payloadHash({ payload: { kind: "timerStart", label: "eggs", minutes: 6 }, tool: "proposeTimerStart" });
    const b = payloadHash({ tool: "proposeTimerStart", payload: { minutes: 6, label: "eggs", kind: "timerStart" } });
    expect(a).toBe(b);
    expect(canonicalJsonString({ b: 2, a: { d: 4, c: 3 } })).toBe('{"a":{"c":3,"d":4},"b":2}');
  });

  it("rejects non-finite and fractional numbers on the wire", () => {
    expect(() => canonicalWireJson({ x: 1.5 })).toThrow();
    expect(() => canonicalWireJson({ x: Number.NaN })).toThrow();
  });

  it("rejects malformed fixtures with a typed error", () => {
    expect(() => parseActionProposalWire('{"id":"x"}')).toThrow(WireParseError);
    expect(() => parseActionProposalWire({ ...JSON.parse(PROPOSAL_FIXTURE_BYTES), tool: "nope" })).toThrow(WireParseError);
    expect(() =>
      parseActionReceiptWire({ ...JSON.parse(RECEIPT_FIXTURE_BYTES), state: "weird" })
    ).toThrow(WireParseError);
  });
});
