/**
 * Offline replay runner for the planner design.
 *
 * Replays every planner script through runDesignSession(script, PLANNER_DESIGN),
 * prints a per-script comparison summary (suppressed turns with reasons,
 * silenced suggestion types, tool-call statuses, proposal states, timer
 * states, usage totals), and exits nonzero on any unexpected result.
 *
 * Fully offline and deterministic: fake phone, fake model, manual clock.
 * Run from backend/gemini-agent:
 *
 *   bun run src/lechef/designs/planner/run.ts
 */

import type { RunRecord } from "../../run/harness.js";
import { gateScript, runDesignSession } from "../../run/designRunner.js";
import { plannerDesign as PLANNER_DESIGN, plannerSuggestionType } from "./design.js";
import { PLANNER_SCRIPTS } from "./scripts/index.js";
import type {
  ExpectedProposal,
  ExpectedTimer,
  ExpectedToolCall,
  PlannerScriptFixture
} from "./scripts/expectations.js";

interface Diff {
  readonly path: string;
  readonly expected: string;
  readonly actual: string;
}

function fmt(value: unknown): string {
  return typeof value === "string" ? value : JSON.stringify(value);
}

function compareExpectations(fixture: PlannerScriptFixture, gate: ReturnType<typeof gateScript>, record: RunRecord): Diff[] {
  const diffs: Diff[] = [];
  const fail = (path: string, expected: unknown, actual: unknown): void => {
    if (fmt(expected) !== fmt(actual)) diffs.push({ path, expected: fmt(expected), actual: fmt(actual) });
  };

  // 1. Gate: suppressed turns and reasons.
  const actualSuppressed = gate.suppressed.map((s) => `${s.turn}:${s.because}`).sort();
  const wantSuppressed = fixture.expect.suppressed.map((s) => `${s.turn}:${s.because}`).sort();
  fail("suppressed", wantSuppressed.join("|"), actualSuppressed.join("|"));

  // 2. Tool-call statuses (and the typed policy result for expected denials).
  const actualCalls = new Map(record.toolCalls.map((c) => [c.id, c]));
  for (const want of fixture.expect.toolCalls as readonly ExpectedToolCall[]) {
    const got = actualCalls.get(want.id);
    if (got === undefined) {
      diffs.push({ path: `toolCalls.${want.id}`, expected: `${want.name}:${want.status}`, actual: "missing" });
      continue;
    }
    fail(`toolCalls.${want.id}.name`, want.name, got.name);
    fail(`toolCalls.${want.id}.status`, want.status, got.status);
    if (want.result !== undefined) fail(`toolCalls.${want.id}.result`, want.result, got.result);
  }
  const wantIds = new Set(fixture.expect.toolCalls.map((c) => c.id));
  for (const got of record.toolCalls) {
    if (!wantIds.has(got.id)) diffs.push({ path: `toolCalls.${got.id}`, expected: "not expected", actual: `${got.name}:${got.status}` });
  }

  // 3. Proposal states — grouped per tool in expectation order (one row each).
  const unmatched = new Set(record.proposals.map((_, i) => i));
  for (const want of fixture.expect.proposals as readonly ExpectedProposal[]) {
    const idx = [...unmatched].find((i) => record.proposals[i].tool === want.tool);
    if (idx === undefined) {
      diffs.push({ path: `proposals[${want.tool}]`, expected: `${want.requiredApproval}:${want.state}`, actual: "missing" });
      continue;
    }
    unmatched.delete(idx);
    const got = record.proposals[idx];
    fail(`proposals[${want.tool}].requiredApproval`, want.requiredApproval, got.requiredApproval);
    fail(`proposals[${want.tool}].state`, want.state, got.state);
  }
  for (const idx of unmatched) {
    const got = record.proposals[idx];
    diffs.push({ path: `proposals[${got.id}]`, expected: "not expected", actual: `${got.tool}:${got.state}` });
  }

  // 4. Timer states — matched by label in expectation order.
  const timersLeft = new Set(record.timers.map((_, i) => i));
  for (const want of fixture.expect.timers as readonly ExpectedTimer[]) {
    const idx = [...timersLeft].find((i) => record.timers[i].label === want.label);
    if (idx === undefined) {
      diffs.push({ path: `timers[${want.label}]`, expected: `${want.minutes}m`, actual: "missing" });
      continue;
    }
    timersLeft.delete(idx);
    const got = record.timers[idx];
    fail(`timers[${want.label}].minutes`, want.minutes, got.minutes);
    fail(`timers[${want.label}].fired`, want.fired, got.firedAt !== undefined);
    fail(`timers[${want.label}].survivedKill`, want.survivedKill, got.survivedKill);
  }
  for (const idx of timersLeft) {
    const got = record.timers[idx];
    diffs.push({ path: `timers[${got.label}]`, expected: "not expected", actual: `${got.minutes}m` });
  }

  // 5. The record must be stamped with this design.
  fail("design", "planner", record.design);

  return diffs;
}

function silencedSuggestionTypes(fixture: PlannerScriptFixture, gate: ReturnType<typeof gateScript>): readonly string[] {
  const byIndex = new Map(fixture.script.turns.map((t) => [t.i, t]));
  const types = new Set<string>();
  for (const s of gate.suppressed) {
    if (s.because !== "suggestion-type-silenced") continue;
    const turn = byIndex.get(s.turn);
    if (turn === undefined || turn.role !== "assistant") continue;
    const type = plannerSuggestionType(turn);
    if (type !== null) types.add(type);
  }
  return [...types].sort();
}

function printSummary(fixture: PlannerScriptFixture, gate: ReturnType<typeof gateScript>, record: RunRecord, diffs: readonly Diff[]): void {
  const mark = diffs.length === 0 ? "✅" : "❌";
  console.log(`\n${mark} ${fixture.name}`);
  console.log(`   ${fixture.blurb}`);
  const turnsIn = fixture.script.turns.length;
  const turnsKept = record.turns.length;
  console.log(`   turns: ${turnsIn} scripted → ${turnsKept} kept, ${gate.suppressed.length} suppressed, actions remapped ${gate.remappedActions.length}, dropped ${gate.droppedActions.length}`);
  if (gate.suppressed.length > 0) {
    console.log(`   suppressed: ${gate.suppressed.map((s) => `turn ${s.turn} (${s.because})`).join(", ")}`);
    const silenced = silencedSuggestionTypes(fixture, gate);
    if (silenced.length > 0) console.log(`   silenced suggestion types: ${silenced.join(", ")}`);
  }
  const calls = record.toolCalls.map((c) => `${c.name}:${c.status}${c.dupOf !== undefined ? " (dup)" : ""}`);
  console.log(`   tool calls (${record.toolCalls.length}): ${calls.length > 0 ? calls.join(", ") : "none"}`);
  const props = record.proposals.map((p) => `${p.tool}→${p.requiredApproval}/${p.state}`);
  console.log(`   proposals (${record.proposals.length}): ${props.length > 0 ? props.join(", ") : "none"}`);
  const timers = record.timers.map((t) => `${t.label} ${t.minutes}m${t.firedAt !== undefined ? " FIRED" : ""}${t.survivedKill ? " survived-kill" : ""}`);
  console.log(`   timers (${record.timers.length}): ${timers.length > 0 ? timers.join(", ") : "none"}`);
  const u = record.usage;
  console.log(`   usage: turns ${u.turns}, text in ${u.textTokensIn} tok, out ${u.textTokensOut} tok, audio ${u.audioSeconds}s, frames ${u.framesSent}, connected ${u.connectedSeconds}s`);
  for (const d of diffs) console.log(`   MISMATCH ${d.path}: expected ${d.expected}, got ${d.actual}`);
}

function main(): number {
  console.log(`planner design replay — ${PLANNER_SCRIPTS.length} scripts, design "${PLANNER_DESIGN.id}"`);
  console.log(`budget: ${PLANNER_DESIGN.turnBudget.maxUnpromptedTurns} unprompted turns, min gap ${PLANNER_DESIGN.turnBudget.minGapTurns}`);

  let failed = 0;
  for (const fixture of PLANNER_SCRIPTS) {
    const gate = gateScript(fixture.script, PLANNER_DESIGN);
    const record = runDesignSession(fixture.script, PLANNER_DESIGN);
    const diffs = compareExpectations(fixture, gate, record);
    if (diffs.length > 0) failed += 1;
    printSummary(fixture, gate, record, diffs);
  }

  console.log(`\n${PLANNER_SCRIPTS.length - failed}/${PLANNER_SCRIPTS.length} scripts matched their expected shape${failed > 0 ? ` — ${failed} MISMATCHED` : ""}`);
  return failed === 0 ? 0 : 1;
}

process.exit(main());
