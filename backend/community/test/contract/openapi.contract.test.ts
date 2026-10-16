/**
 * The contract round-trip suite on the in-memory adapter (unit tier — runs in
 * plain `bun test test/`).
 */
import { runContractSuite } from "./suite.js";

runContractSuite("memory", { kind: "memory" });
