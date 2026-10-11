/**
 * LeChef shared tool layer — public surface.
 *
 * The later integration task wires this into server.ts by calling
 * createLeChefRuntime(deps) with {clock, phone, catalog, camera?} — see
 * README.md, "Wiring contract". The phone is authoritative; this layer only
 * reads bounded snapshots and proposes typed actions. Nothing here executes
 * an action, contacts a model API, or produces a safety verdict.
 *
 * Note: src/lechef/designs/ is reserved for later parts and is not part of
 * this surface.
 */

// Domain types, snapshots, proposals, receipts (fixture-shaped wire types).
export * from "./types.js";
// Canonical wire serialization/parsing of the ActionProposal/ActionReceipt fixtures.
export * from "./wire.js";
// Pantry-fit computation (complete bill, no percentages, no double counting).
export * from "./fit.js";
// All-eater, compound-aware allergen rechecks.
export * from "./allergens.js";
// Sourced FSIS doneness checks with rulebook override.
export * from "./foodSafety.js";
// Substitution lookup with explicit beyond-table unknowns.
export * from "./substitutions.js";
// Read tools (candidates, pantry, context, camera looks).
export * from "./reads.js";
// Proposal tools (proposals only; the phone executes).
export * from "./proposals.js";
// Phone-authoritative fake for offline evaluation.
export * from "./fakePhone.js";
// Scripted fake model provider.
export * from "./fakeModel.js";
// Runtime dispatch + createLeChefRuntime.
export * from "./runtime.js";
// Harness: RunRecord assembly for the Python scorer.
export { runSession, cannedCamera, type RunRecord } from "./run/harness.js";
// Deterministic clock for tests and harness runs.
export { ManualClock } from "./run/clock.js";
