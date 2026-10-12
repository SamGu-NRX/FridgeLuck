import { describe, it, expect } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
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

// ---------------------------------------------------------------------------
// REAL pinned fixture bytes.
//
// Vendored verbatim from origin/overhaul/core-foundation @
// c4d53c9cf09dbfd0827fcdac4d6a1961fff12b9e
// (packages/FridgeLuckCore/Fixtures/{action-proposal,action-receipt}.json).
// Provenance — source branch, commit, per-file SHA256:
// ./fixtures/core/fixture-provenance.json. These are the canonical bytes the
// Swift encoder produces: keys sorted, ` : ` separators, timestamps as ISO
// 8601 UTC strings with millisecond precision, no trailing newline.
//
// Review fix 5: the wire timestamps the core actually sends are ISO 8601
// strings ("2026-10-11T12:00:00.000Z"), not integer epochs. The epoch-second
// integer form the previous test file claimed was a hand-copied
// approximation (its "813412800" is 1995-10-11), not fixture bytes.
// ---------------------------------------------------------------------------

const FIXTURE_DIR = join(import.meta.dir, "fixtures", "core");
const PROPOSAL_BYTES = readFileSync(join(FIXTURE_DIR, "action-proposal.json"), "utf8");
const RECEIPT_BYTES = readFileSync(join(FIXTURE_DIR, "action-receipt.json"), "utf8");
const PROVENANCE = JSON.parse(
  readFileSync(join(FIXTURE_DIR, "fixture-provenance.json"), "utf8")
) as { files: Record<string, { sha256: string; bytes: number }> };

// Epoch literals for the pinned fixture timestamps (2026-10-11T12:00:00Z,
// 12:45:00Z and 12:30:00Z), asserted as numbers so the parse result is
// checked against an independent value, not against the serializer.
const PROPOSAL_CREATED_AT = 1791720000;
const PROPOSAL_EXPIRES_AT = 1791722700;
const RECORDED_AT = 1791721800;

describe("wire: pinned core fixtures are the real bytes", () => {
  it("vendored fixture files match the pinned provenance SHA256s", () => {
    for (const [name, expected] of Object.entries(PROVENANCE.files)) {
      const bytes = readFileSync(join(FIXTURE_DIR, name));
      expect(bytes.length).toBe(expected.bytes);
      expect(createHash("sha256").update(bytes).digest("hex")).toBe(expected.sha256);
    }
    // The wire fixtures carry ISO 8601 timestamp strings, not epoch integers.
    expect(PROPOSAL_BYTES).toContain('"createdAt" : "2026-10-11T12:00:00.000Z"');
    expect(RECEIPT_BYTES).toContain('"recordedAt" : "2026-10-11T12:30:00.000Z"');
  });
});

describe("wire: real-fixture round-trips are byte-identical", () => {
  it("round-trips action-proposal.json byte for byte", () => {
    const parsed = parseActionProposalWire(JSON.parse(PROPOSAL_BYTES));
    expect(parsed.id).toBe("proposal-fix-1");
    expect(parsed.tool).toBe("proposeStepAdvance");
    expect(parsed.createdAt).toBe(PROPOSAL_CREATED_AT);
    expect(parsed.expiresAt).toBe(PROPOSAL_EXPIRES_AT);
    expect(parsed.snapshotRevision).toBe(3);
    // The frozen fixtures predate the additive fields: parsing must not invent them.
    expect(parsed.requiredApproval).toBeUndefined();
    expect(parsed.userInitiated).toBeUndefined();
    expect(serializeActionProposal(parsed)).toBe(PROPOSAL_BYTES);
  });

  it("round-trips action-receipt.json byte for byte", () => {
    const parsed = parseActionReceiptWire(JSON.parse(RECEIPT_BYTES));
    expect(parsed.proposalID).toBe("proposal-fix-1"); // capital ID, per fixture
    expect(parsed.state).toBe("executed");
    expect(parsed.recordedAt).toBe(RECORDED_AT);
    expect(serializeActionReceipt(parsed)).toBe(RECEIPT_BYTES);
  });

  it("emits additive fields only when set, keeping the seven-field fixture shape reachable", () => {
    const base = parseActionProposalWire(JSON.parse(PROPOSAL_BYTES));
    const withAdditives = { ...base, requiredApproval: "explicit" as const, userInitiated: true };
    const bytes = serializeActionProposal(withAdditives);
    expect(bytes).toContain('"requiredApproval" : "explicit"');
    expect(bytes).toContain('"userInitiated" : true');
    expect(bytes).toContain('"tool" : "proposeStepAdvance"');
    expect(bytes).toContain('"createdAt" : "2026-10-11T12:00:00.000Z"');
  });
});

describe("wire: timestamps decode from any ISO 8601 producer and encode canonically", () => {
  function proposalWith(overrides: Record<string, unknown>): Record<string, unknown> {
    const base = JSON.parse(PROPOSAL_BYTES) as Record<string, unknown>;
    return { ...base, ...overrides };
  }

  it("decodes a Z form without fractional seconds", () => {
    const parsed = parseActionProposalWire(proposalWith({ createdAt: "2026-10-11T12:00:00Z" }));
    expect(parsed.createdAt).toBe(PROPOSAL_CREATED_AT);
  });

  it("decodes numeric UTC offsets, with and without a colon in the offset", () => {
    // 14:00+02:00 and 06:30-05:30 are both 12:00 UTC.
    expect(parseActionProposalWire(proposalWith({ createdAt: "2026-10-11T14:00:00+02:00" })).createdAt).toBe(
      PROPOSAL_CREATED_AT
    );
    expect(parseActionProposalWire(proposalWith({ expiresAt: "2026-10-11T144500+0200" })).expiresAt).toBe(
      PROPOSAL_EXPIRES_AT
    );
    expect(
      parseActionReceiptWire({
        ...JSON.parse(RECEIPT_BYTES),
        recordedAt: "2026-10-11T06:30:00-05:30"
      }).recordedAt
    ).toBe(RECORDED_AT);
  });

  it("decodes fractional seconds (dot and comma) down to whole seconds", () => {
    expect(parseActionProposalWire(proposalWith({ createdAt: "2026-10-11T12:00:00.5Z" })).createdAt).toBe(
      PROPOSAL_CREATED_AT
    );
    expect(parseActionProposalWire(proposalWith({ createdAt: "2026-10-11T12:00:00,250Z" })).createdAt).toBe(
      PROPOSAL_CREATED_AT
    );
  });

  it("still accepts integer epoch seconds (the evaluation layer's form)", () => {
    const parsed = parseActionProposalWire(proposalWith({ createdAt: PROPOSAL_CREATED_AT }));
    expect(parsed.createdAt).toBe(PROPOSAL_CREATED_AT);
  });

  it("re-encodes timestamps into the fixture's canonical millisecond UTC form", () => {
    const parsed = parseActionProposalWire(proposalWith({ createdAt: "2026-10-11T14:00:00+02:00" }));
    expect(serializeActionProposal(parsed)).toContain('"createdAt" : "2026-10-11T12:00:00.000Z"');
  });

  it("rejects genuinely malformed timestamps", () => {
    const malformed = [
      "not-a-timestamp",
      "2026-10-11", // date only — not an instant
      "2026-10-11 12:00:00Z", // space instead of T
      "2026-13-01T12:00:00Z", // month out of range
      "2026-02-30T12:00:00Z", // calendar rollover
      "2026-10-11T25:00:00Z", // hour out of range
      "2026-10-11T12:60:00Z", // minute out of range
      "2026-10-11T12:00:00+25:00", // offset out of range
      "1791720000", // epoch seconds as a string is not an ISO 8601 instant
      ""
    ];
    for (const bad of malformed) {
      expect(() => parseActionProposalWire(proposalWith({ createdAt: bad }))).toThrow(WireParseError);
    }
    expect(() =>
      parseActionProposalWire(proposalWith({ createdAt: 1791720000.5 })) // fractional epoch
    ).toThrow(WireParseError);
    expect(() => parseActionReceiptWire({ ...JSON.parse(RECEIPT_BYTES), recordedAt: "yesterday" })).toThrow(
      WireParseError
    );
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
    expect(() => parseActionProposalWire({ ...JSON.parse(PROPOSAL_BYTES), tool: "nope" })).toThrow(WireParseError);
    expect(() => parseActionReceiptWire({ ...JSON.parse(RECEIPT_BYTES), state: "weird" })).toThrow(WireParseError);
  });
});
