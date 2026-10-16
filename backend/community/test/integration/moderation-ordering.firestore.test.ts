/**
 * The moderation decision-ordering suite on the production Firestore adapter,
 * under the emulator (integration tier — `bun run test:integration` with
 * FIRESTORE_EMULATOR_HOST pointed at a running emulator). Same body as the
 * memory tier: the store seam is the only thing the tests touch.
 *
 * This tier is where the defect lived: Firestore orders equality-query
 * results by document id, so the pre-fix hide-then-dismiss flow restored the
 * card only when the arbitrary id order happened to favor the later review
 * (observed 2 of 5 runs restored, 3 left hidden). The same-tick stamp bump
 * makes the outcome deterministic here. Subs get a per-run prefix: the
 * emulator persists data, and fresh accounts keep daily rate-limit counters
 * independent of earlier runs.
 */
import { describe } from "bun:test";
import { openFirestoreStore } from "../../src/core/store/firestore.js";
import { runModerationOrdering, type ModerationOrderingStoreFactory } from "../moderation-ordering.suite.js";

const projectId = `fridgeluck-mo-it-${Date.now().toString(36)}`;
const configured = process.env.FIRESTORE_EMULATOR_HOST !== undefined;

(configured ? describe : describe.skip)(`firestore tier (${projectId})`, () => {
  const makeStore: ModerationOrderingStoreFactory = async () => openFirestoreStore(projectId);
  runModerationOrdering(`firestore (${projectId})`, makeStore, { subPrefix: `mo-${Date.now().toString(36)}-` });
});
