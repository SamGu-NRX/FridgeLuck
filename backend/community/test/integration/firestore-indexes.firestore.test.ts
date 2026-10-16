/**
 * Firestore composite-index manifest coverage (integration tier —
 * `bun run test:integration` with FIRESTORE_EMULATOR_HOST pointed at a running
 * emulator).
 *
 * The store seam compiles every `where(field, value)` pair to `==` filters,
 * and Firestore serves multi-field equality queries with composite indexes
 * that must be declared in firestore.indexes.json before production deploy —
 * the emulator provisions them implicitly, so nothing upstream fails when the
 * manifest drifts. This test is the drift guard plus a live execution check:
 *
 *  1. every inventoried multi-field query shape in src/ has a matching
 *     manifest entry (same collection group, same field paths in order), and
 *  2. each shape actually executes against the adapter under the emulator and
 *     returns the matching document.
 *
 * The inventory below mirrors the current query shapes (update both together):
 *  - sessions: accountId + revokedAt (core/sessionCore.ts list + rotation tx)
 *  - tableInvites: tableId + state, "pending" (modules/tables/index.ts approve list)
 *  - cases: targetId + state, "queued" (modules/moderation/index.ts reports tx,
 *    modules/challenges/webPage.ts visible-entry check)
 */
import { describe, expect, test } from "bun:test";
import { openFirestoreStore } from "../../src/core/store/firestore.js";
import type { DocumentStore } from "../../src/core/store/documentStore.js";

const projectId = `fridgeluck-idx-it-${Date.now().toString(36)}`;
const configured = process.env.FIRESTORE_EMULATOR_HOST !== undefined;

interface IndexedField {
  fieldPath: string;
  order: string;
}
interface CompositeIndex {
  collectionGroup: string;
  queryScope: string;
  fields: IndexedField[];
}

/** The multi-field equality query shapes the code runs, in manifest terms. */
const REQUIRED_INDEXES: CompositeIndex[] = [
  {
    collectionGroup: "sessions",
    queryScope: "COLLECTION",
    fields: [
      { fieldPath: "accountId", order: "ASCENDING" },
      { fieldPath: "revokedAt", order: "ASCENDING" },
    ],
  },
  {
    collectionGroup: "tableInvites",
    queryScope: "COLLECTION",
    fields: [
      { fieldPath: "tableId", order: "ASCENDING" },
      { fieldPath: "state", order: "ASCENDING" },
    ],
  },
  {
    collectionGroup: "cases",
    queryScope: "COLLECTION",
    fields: [
      { fieldPath: "targetId", order: "ASCENDING" },
      { fieldPath: "state", order: "ASCENDING" },
    ],
  },
];

const manifestToKey = (index: CompositeIndex): string =>
  `${index.collectionGroup}#${index.fields.map((f) => f.fieldPath).join("+")}`;

(configured ? describe : describe.skip)(`firestore index manifest (${projectId})`, () => {
  test("the manifest covers every inventoried multi-field query shape", async () => {
    const manifest = (await Bun.file(new URL("../../firestore.indexes.json", import.meta.url)).json()) as {
      indexes?: CompositeIndex[];
    };
    const declared = (manifest.indexes ?? []).filter((index) => index.queryScope === "COLLECTION").map(manifestToKey);
    for (const required of REQUIRED_INDEXES) {
      expect(declared).toContain(manifestToKey(required));
    }
  });

  test("each inventoried shape executes on the adapter and returns the matching document", async () => {
    const store: DocumentStore = await openFirestoreStore(projectId);
    const now = new Date().toISOString();

    const shapes: { collection: string; docId: string; doc: Record<string, unknown>; match: [[string, unknown], [string, unknown]] }[] = [
      {
        // sessionCore rotation listing: live sessions for one account
        collection: "sessions",
        docId: "idx-sess-1",
        doc: { sessionId: "idx-sess-1", accountId: "acct_idx", revokedAt: null, createdAt: now },
        match: [["accountId", "acct_idx"], ["revokedAt", null]],
      },
      {
        // tables approve list: pending invites for one table
        collection: "tableInvites",
        docId: "idx-inv-1",
        doc: { inviteId: "idx-inv-1", tableId: "tbl_idx", state: "pending", createdAt: now },
        match: [["tableId", "tbl_idx"], ["state", "pending"]],
      },
      {
        // moderation reports tx + challenge web page: queued cases for one target
        collection: "cases",
        docId: "idx-case-1",
        doc: { caseId: "idx-case-1", targetId: "tgt_idx", state: "queued", createdAt: now },
        match: [["targetId", "tgt_idx"], ["state", "queued"]],
      },
    ];

    for (const shape of shapes) {
      await store.collection(shape.collection).doc(shape.docId).set(shape.doc);
      const docs = await store
        .collection(shape.collection)
        .where(shape.match[0][0], shape.match[0][1])
        .where(shape.match[1][0], shape.match[1][1])
        .get();
      expect(docs.map((d) => d.id)).toContain(shape.docId);
    }
  });
});
