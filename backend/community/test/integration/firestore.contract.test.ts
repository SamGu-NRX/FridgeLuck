/**
 * The contract round-trip suite on the production Firestore adapter, under the
 * emulator (integration tier — `bun run test:integration` with
 * FIRESTORE_EMULATOR_HOST pointed at a running emulator).
 */
import { runContractSuite } from "../contract/suite.js";

// A fresh project id per run: the emulator persists data across runs, and the
// suite's rate-limit scenarios need an empty store (CI gets that for free; a
// long-lived local emulator would otherwise serve stale counters).
const projectId = `fridgeluck-contract-it-${Date.now().toString(36)}`;

runContractSuite(`firestore (${projectId})`, { kind: "firestore", projectId }, { skipUnlessEmulator: true });
