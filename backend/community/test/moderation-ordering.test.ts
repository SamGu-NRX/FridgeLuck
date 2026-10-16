/**
 * The moderation decision-ordering suite on the in-memory store (unit tier —
 * `bun test test/`, no emulator needed). The test body lives in
 * moderation-ordering.suite.ts and runs unchanged against the Firestore
 * adapter under the emulator
 * (test/integration/moderation-ordering.firestore.test.ts).
 *
 * The frozen clock makes every decision land on the same millisecond, which
 * is where the old reader-side store-order tie-break decided the outcome:
 * memory's insertion order happened to favor the later review, Firestore's
 * document-id order flaked the same flow. The suite pins the writer-side
 * monotonic stamp that removes the tie entirely.
 */
import { describe } from "bun:test";
import { runModerationOrdering, type ModerationOrderingStoreFactory } from "./moderation-ordering.suite.js";
import { MemoryStore } from "../src/core/store/memory.js";

const makeStore: ModerationOrderingStoreFactory = async () => new MemoryStore();

describe("moderation ordering (memory tier)", () => {
  runModerationOrdering("memory", makeStore);
});
