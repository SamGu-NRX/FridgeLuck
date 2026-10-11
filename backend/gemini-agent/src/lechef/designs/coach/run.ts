/**
 * Coach-design replay runner — loads the design's focused scripts, runs
 * each through runDesignSession(script, coachDesign), prints a per-script
 * comparison summary (suppressed turns with reasons, silenced suggestion
 * types, tool-call statuses, proposal states, usage totals), and exits
 * nonzero when any script's replay does not match its expected shape.
 *
 *   bun run src/lechef/designs/coach/run.ts
 *
 * Fully offline: fake provider + fake phone on a manual clock, no network,
 * no model API, no scoring — the raw RunRecord stays exactly the pinned
 * shape the plain harness emits.
 */

import { runDesignSession, gateScript, type GateResult } from "../../run/designRunner.js";
import { parseSessionScript } from "../../fakeModel.js";
import type { SessionScript } from "../../fakeModel.js";
import type { RunRecord } from "../../run/harness.js";
import { coachDesign, coachSuggestionType } from "./design.js";
import { COACH_SCRIPTS } from "./scripts/index.js";
import type { CoachCase } from "./scripts/types.js";

interface CaseReport {
  readonly name: string;
  readonly focus: string;
  readonly gated: GateResult;
  readonly record: RunRecord;
  /** Suggestion types silenced this session, derived from the SOURCE script (suppressed turns are absent from the record). */
  readonly silencedTypes: readonly string[];
  readonly failures: readonly string[];
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function isPolicyDenial(result: unknown): boolean {
  return typeof result === "object" && result !== null && (result as { error?: unknown }).error === "policy-denied";
}

/** The suggestion types silenced by a gate result, classified from the source turns. */
function silencedTypesOf(source: SessionScript, gated: GateResult): readonly string[] {
  return [
    ...new Set(
      gated.suppressed
        .filter((s) => s.because === "suggestion-type-silenced")
        .map((s) => {
          const sourceTurn = source.turns.find((t) => t.i === s.turn);
          return sourceTurn ? coachSuggestionType(sourceTurn) : null;
        })
        .filter((t): t is string => t !== null)
    )
  ].sort();
}

/** Assert one case's expectations against its gate result and replay record. */
function checkCase(c: CoachCase): CaseReport {
  const failures: string[] = [];
  const fail = (detail: string): void => {
    failures.push(detail);
  };

  // Loud validation even for TS-authored scripts — the pinned parser is the
  // same one the harness CLI applies to JSON sessions.
  const parsed = parseSessionScript(c.script);
  const gated = gateScript(parsed, coachDesign);
  const record = runDesignSession(parsed, coachDesign);
  const expect = c.expect;

  if (!sameJson(gated.suppressed, expect.suppressed)) {
    fail(`suppressed: expected ${JSON.stringify(expect.suppressed)}, got ${JSON.stringify(gated.suppressed)}`);
  }
  const kept = gated.script.turns.map((t) => t.i);
  if (!sameJson(kept, expect.keptTurns)) {
    fail(`kept turns: expected [${expect.keptTurns.join(",")}], got [${kept.join(",")}]`);
  }
  if (expect.remappedActions !== undefined && !sameJson(gated.remappedActions, expect.remappedActions)) {
    fail(
      `remapped actions: expected ${JSON.stringify(expect.remappedActions)}, got ${JSON.stringify(gated.remappedActions)}`
    );
  }
  if (expect.droppedActions !== undefined && gated.droppedActions.length !== expect.droppedActions) {
    fail(`dropped actions: expected ${expect.droppedActions}, got ${gated.droppedActions.length}`);
  }

  if (record.toolCalls.length !== expect.toolStatus.length) {
    fail(`tool calls: expected ${expect.toolStatus.length}, got ${record.toolCalls.length}`);
  }
  for (const ts of expect.toolStatus) {
    const recordCall = record.toolCalls.find((x) => x.id === ts.id);
    if (!recordCall) {
      fail(`tool call ${ts.id}: missing from the record`);
      continue;
    }
    if (recordCall.status !== ts.status) {
      fail(`tool call ${ts.id}: expected status ${ts.status}, got ${recordCall.status}`);
    }
    const denied = isPolicyDenial(recordCall.result);
    if (ts.policyDenied === true && !denied) {
      fail(`tool call ${ts.id}: expected a policy denial, got ${JSON.stringify(recordCall.result)}`);
    }
    if (ts.policyDenied !== true && denied) {
      fail(`tool call ${ts.id}: unexpected policy denial`);
    }
    if (denied && ts.policyDenied === true) {
      const reason = (recordCall.result as { reason?: unknown }).reason;
      const expectedReason = expect.denialReasons?.[ts.id];
      if (typeof reason !== "string" || (expectedReason !== undefined && reason !== expectedReason)) {
        fail(`tool call ${ts.id}: denial reason "${String(reason)}" does not match the expected rule`);
      }
    }
  }

  const proposalShapes = record.proposals.map((p) => ({
    tool: p.tool,
    requiredApproval: p.requiredApproval,
    state: p.state
  }));
  if (expect.proposals !== undefined) {
    if (!sameJson(proposalShapes, expect.proposals)) {
      fail(`proposals: expected ${JSON.stringify(expect.proposals)}, got ${JSON.stringify(proposalShapes)}`);
    }
  } else if (proposalShapes.length !== 0) {
    fail(`proposals: expected none, got ${JSON.stringify(proposalShapes)}`);
  }

  if (expect.receiptStates !== undefined && !sameJson(record.receipts.map((r) => r.state), expect.receiptStates)) {
    fail(
      `receipts: expected [${expect.receiptStates.join(",")}], got [${record.receipts.map((r) => r.state).join(",")}]`
    );
  }
  if (expect.timerLabels !== undefined && !sameJson(record.timers.map((t) => t.label), expect.timerLabels)) {
    fail(`timers: expected [${expect.timerLabels.join(",")}], got [${record.timers.map((t) => t.label).join(",")}]`);
  }
  if (expect.cameraLooks !== undefined && record.camera.length !== expect.cameraLooks) {
    fail(`camera looks: expected ${expect.cameraLooks}, got ${record.camera.length}`);
  }
  if (expect.framesSent !== undefined && record.usage.framesSent !== expect.framesSent) {
    fail(`frames sent: expected ${expect.framesSent}, got ${record.usage.framesSent}`);
  }
  if (expect.donenessTemps !== undefined) {
    const temps = record.answers
      .filter((a) => a.type === "doneness" && a.sourcedCheck !== null)
      .map((a) => a.sourcedCheck?.temperatureC);
    if (!sameJson(temps, expect.donenessTemps)) {
      fail(`doneness answers: expected temperatures [${expect.donenessTemps.join(",")}], got [${temps.join(",")}]`);
    }
  }
  if (expect.otherAnswers !== undefined) {
    const others = record.answers.filter((a) => a.type === "other").length;
    if (others !== expect.otherAnswers) {
      fail(`other answers: expected ${expect.otherAnswers}, got ${others}`);
    }
  }
  const silencedTypes = silencedTypesOf(parsed, gated);
  if (expect.silencedTypes !== undefined && !sameJson(silencedTypes, expect.silencedTypes)) {
    fail(`silenced types: expected [${expect.silencedTypes.join(",")}], got [${silencedTypes.join(",")}]`);
  }
  if (record.usage.turns !== expect.usageTurns) {
    fail(`usage turns: expected ${expect.usageTurns}, got ${record.usage.turns}`);
  }

  return { name: c.name, focus: c.focus, gated, record, silencedTypes, failures };
}

function suppressedLabel(gated: GateResult): string {
  if (gated.suppressed.length === 0) return "—";
  return gated.suppressed.map((s) => `t${s.turn}:${s.because}`).join(", ");
}

/** Print the per-script comparison summary; exit nonzero on any mismatch. */
export function main(): number {
  console.log(`coach design replay — ${COACH_SCRIPTS.length} scripts, design "${coachDesign.id}"`);
  console.log(`budget ${JSON.stringify(coachDesign.turnBudget)}, policy rules ${coachDesign.toolPolicy.length}`);
  console.log("");

  const reports = COACH_SCRIPTS.map(checkCase);

  for (const r of reports) {
    const statuses = r.record.toolCalls.map((c) => c.status);
    const okCount = statuses.filter((s) => s === "ok").length;
    const denied = r.record.toolCalls.filter((c) => isPolicyDenial(c.result));
    const u = r.record.usage;
    console.log(`${r.name}`);
    console.log(`  focus:     ${r.focus}`);
    console.log(
      `  turns:     kept ${u.turns}/${u.turns + r.gated.suppressed.length}` +
        `, suppressed ${suppressedLabel(r.gated)}` +
        (r.silencedTypes.length > 0 ? `, silenced types: ${r.silencedTypes.join(", ")}` : "")
    );
    console.log(
      `  calls:     ok=${okCount} other=${statuses.length - okCount}` +
        (denied.length > 0 ? ` (policy-denied: ${denied.map((c) => c.id).join(", ")})` : "") +
        `, proposals=${r.record.proposals.map((p) => `${p.tool}/${p.requiredApproval}/${p.state}`).join(", ") || "none"}` +
        (r.record.timers.length > 0 ? `, timers=${r.record.timers.map((t) => t.label).join(", ")}` : "")
    );
    console.log(
      `  usage:     tokensIn=${u.textTokensIn} tokensOut=${u.textTokensOut} audioSec=${u.audioSeconds}` +
        ` frames=${u.framesSent} connectedSec=${u.connectedSeconds}`
    );
    if (r.failures.length > 0) {
      for (const f of r.failures) console.log(`  MISMATCH:  ${f}`);
    } else {
      console.log(`  result:    all expectations met`);
    }
    console.log("");
  }

  const totalFailures = reports.reduce((n, r) => n + r.failures.length, 0);
  console.log(
    totalFailures === 0
      ? `all ${reports.length} scripts match their expected shapes`
      : `${totalFailures} expectation mismatch(es) across ${reports.length} scripts`
  );
  return totalFailures === 0 ? 0 : 1;
}

if (import.meta.main) {
  process.exit(main());
}
