/**
 * The contract round-trip suite on the production Firestore adapter, under the
 * emulator (integration tier — `bun run test:integration` with
 * FIRESTORE_EMULATOR_HOST pointed at a running emulator).
 */
import { runContractSuite } from "../contract/suite.js";

const projectId = "fridgeluck-contract-it";

runContractSuite(`firestore (${projectId})`, { kind: "firestore", projectId }, { skipUnlessEmulator: true });
