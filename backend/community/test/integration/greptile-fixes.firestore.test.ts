/**
 * The Greptile PR #166 findings suite on the production Firestore adapter,
 * under the emulator (integration tier — `bun run test:integration` with
 * FIRESTORE_EMULATOR_HOST pointed at a running emulator). Same bodies as the
 * memory tier: the store seam is the only thing the tests touch.
 *
 * The race tests overlap for real here — two HTTP/in-process requests hit the
 * emulator concurrently, and the single-outcome assertions (one 202 invite
 * claim, one card per operationId, one active entry) hold through Firestore
 * transaction retries instead of a test-injected jitter. Subs get a per-run
 * prefix: the emulator persists data, and fresh accounts keep daily
 * rate-limit counters independent of earlier runs.
 */
import { describe } from "bun:test";
import { openFirestoreStore } from "../../src/core/store/firestore.js";
import { runGreptileFixes } from "../greptile-fixes.suite.js";

const projectId = `fridgeluck-fixes-it-${Date.now().toString(36)}`;
const configured = process.env.FIRESTORE_EMULATOR_HOST !== undefined;

(configured ? describe : describe.skip)(`firestore tier (${projectId})`, () => {
  runGreptileFixes(`firestore (${projectId})`, () => openFirestoreStore(projectId), { subPrefix: `fs-${Date.now().toString(36)}-` });
});
