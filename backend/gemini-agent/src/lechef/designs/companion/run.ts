/**
 * Companion design replay runner — loads THIS design's session scripts,
 * gates each through the Companion design via runDesignSession, prints a
 * per-script comparison summary, and exits nonzero on any unexpected
 * result. Runs entirely offline: fake provider + fake phone, no network.
 *
 *   bun src/lechef/designs/companion/run.ts
 *
 * The expectations table below IS the design's contract with its scripts:
 * each entry asserts the script's expected shape — suppressed turns with
 * reasons, policy-denied call ids, proposal lifecycle states, and (where
 * relevant) answer/camera event counts. A script that stops matching its
 * expectation is a design regression, not a scorer question.
 */

import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseSessionScript, type SessionScript } from "../../fakeModel.js";
import { gateScript, runDesignSession } from "../../run/designRunner.js";
import type { RunRecord } from "../../run/harness.js";
import { companionDesign } from "./design.js";

// ---------------------------------------------------------------------------
// Expectations — one entry per script in ./scripts (keyed by file name)
// ---------------------------------------------------------------------------

interface ScriptExpectation {
  /** What this script probes, printed as the script's headline. */
  readonly probes: string;
  /** Exact gate output: suppressed source turns in order, with reasons. */
  readonly suppressed: readonly { readonly turn: number; readonly because: string }[];
  /** Tool-call ids that must come back policy-denied. */
  readonly deniedCallIds: readonly string[];
  /** Proposal lifecycles in creation order: tool + final state. */
  readonly proposalStates: readonly { readonly tool: string; readonly state: string }[];
  readonly cameraEvents?: number;
  readonly answers?: number;
}

const EXPECTATIONS: Record<string, ScriptExpectation> = {
  "control-prompted-only.json": {
    probes: "prompted-only control — nothing gated, nothing denied (equivalence baseline)",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: [{ tool: "proposeTimerStart", state: "executed" }],
    answers: 1
  },
  "budget-exhaustion.json": {
    probes: "fourth unprompted turn hits the budget; three well-spaced check-ins survive",
    suppressed: [{ turn: 9, because: "budget-exhausted" }],
    deniedCallIds: [],
    proposalStates: []
  },
  "checkin-run-collapse.json": {
    probes: "a run of consecutive check-ins collapses to its first turn (min-gap)",
    suppressed: [
      { turn: 1, because: "min-gap" },
      { turn: 2, because: "min-gap" },
      { turn: 3, because: "min-gap" }
    ],
    deniedCallIds: [],
    proposalStates: []
  },
  "use-soon-silence.json": {
    probes: "third use-soon after two rejections is silenced; check-ins unaffected",
    suppressed: [{ turn: 5, because: "suggestion-type-silenced" }],
    deniedCallIds: [],
    proposalStates: []
  },
  "proposal-gating.json": {
    probes: "proactive meal-log/note denied with reasons; the same asks prompted pass and execute",
    suppressed: [],
    deniedCallIds: ["g-ml1", "g-nt1"],
    proposalStates: [
      { tool: "proposeMealLog", state: "executed" },
      { tool: "proposeSaveNote", state: "proposed" }
    ]
  },
  "timer-allowance.json": {
    probes: "proactive timer offer allowed — the proposal IS the ask, approval executes it",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: [{ tool: "proposeTimerStart", state: "executed" }]
  },
  "inventory-correction-proactive.json": {
    probes: "proactive pantry correction denied; the cook's own report passes",
    suppressed: [],
    deniedCallIds: ["ic1"],
    proposalStates: [{ tool: "proposeInventoryCorrection", state: "proposed" }]
  },
  "burnt-smell-empathy.json": {
    probes: "failure response: empathy, camera look with no verdict, honest unknown from the rulebook",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: [],
    cameraEvents: 1,
    answers: 1
  },
  "use-soon-reminder.json": {
    probes: "accepted use-soon nudge flows into a read-only suggestion",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: []
  },
  "step-advance-allowance.json": {
    probes: "proactive step-offer allowed; explicit approval advances the session",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: [{ tool: "proposeStepAdvance", state: "executed" }]
  },
  "mixed-focus-backoff.json": {
    probes: "terse cook: check-ins space out, one min-gaps away, the fourth hits the budget",
    suppressed: [
      { turn: 4, because: "min-gap" },
      { turn: 10, because: "budget-exhausted" }
    ],
    deniedCallIds: [],
    proposalStates: []
  },
  "remember-note-flow.json": {
    probes: "full remember lifecycle: cook originates notes and the meal log, all executed",
    suppressed: [],
    deniedCallIds: [],
    proposalStates: [
      { tool: "proposeSaveNote", state: "executed" },
      { tool: "proposeSaveNote", state: "executed" },
      { tool: "proposeMealLog", state: "executed" }
    ]
  }
};

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

const SCRIPTS_DIR = resolve(fileURLToPath(new URL("./scripts/", import.meta.url)));

function isPolicyDenied(call: RunRecord["toolCalls"][number]): boolean {
  if (call.status !== "error") return false;
  const result = call.result as { error?: unknown } | null | undefined;
  return typeof result === "object" && result !== null && result["error"] === "policy-denied";
}

function plural(n: number, word: string): string {
  return n === 1 ? `${n} ${word}` : `${n} ${word}s`;
}

function loadScripts(): { name: string; script: SessionScript }[] {
  const files = readdirSync(SCRIPTS_DIR).filter((f) => f.endsWith(".json")).sort();
  return files.map((name) => {
    const parsed: unknown = JSON.parse(readFileSync(join(SCRIPTS_DIR, name), "utf8"));
    return { name, script: parseSessionScript(parsed) };
  });
}

function replayOne(name: string, script: SessionScript): { ok: boolean; lines: string[] } {
  const lines: string[] = [];
  const expected = EXPECTATIONS[name];
  if (expected === undefined) {
    lines.push(`   ✗ no expectations entry for ${name} — every script needs one`);
    return { ok: false, lines };
  }

  const gate = gateScript(script, companionDesign);
  const record = runDesignSession(script, companionDesign);

  // --- summary -------------------------------------------------------------
  const suppressedTypes = gate.suppressed
    .filter((s) => s.because === "suggestion-type-silenced")
    .map((s) => {
      const turn = script.turns.find((t) => t.i === s.turn);
      const type = turn !== undefined ? (companionDesign.suggestionType?.(turn) ?? "<no marker>") : "<missing>";
      return type;
    });
  const uniqueSilenced = [...new Set(suppressedTypes)];
  const statusCounts = { ok: 0, error: 0, duplicate: 0, cancelled: 0 };
  for (const call of record.toolCalls) statusCounts[call.status] += 1;
  const deniedIds = record.toolCalls.filter(isPolicyDenied).map((c) => c.id).sort();
  const proposalStates = record.proposals.map((p) => ({ tool: p.tool, state: p.state }));

  lines.push(`   gate: ${plural(record.usage.turns, "turn")} kept, ${plural(gate.suppressed.length, "suppressed turn")}`);
  for (const s of gate.suppressed) lines.push(`      suppressed turn ${s.turn}: ${s.because}`);
  lines.push(`   silenced suggestion types: ${uniqueSilenced.length === 0 ? "none" : uniqueSilenced.join(", ")}`);
  lines.push(`   policy denials: ${deniedIds.length === 0 ? "none" : deniedIds.join(", ")}`);
  for (const call of record.toolCalls.filter(isPolicyDenied)) {
    const reason = (call.result as { reason?: string }).reason ?? "<no reason>";
    lines.push(`      ${call.id} (${call.name}): ${reason}`);
  }
  lines.push(
    `   tool calls: ok=${statusCounts.ok} error=${statusCounts.error} duplicate=${statusCounts.duplicate} cancelled=${statusCounts.cancelled}`
  );
  lines.push(
    `   proposals: ${proposalStates.length === 0 ? "none" : proposalStates.map((p) => `${p.tool}=${p.state}`).join(", ")}`
  );
  lines.push(
    `   usage: turns=${record.usage.turns} in=${record.usage.textTokensIn}tok out=${record.usage.textTokensOut}tok ` +
      `audio=${record.usage.audioSeconds}s frames=${record.usage.framesSent} connected=${record.usage.connectedSeconds}s`
  );

  // --- expectations ----------------------------------------------------------
  const problems: string[] = [];
  if (record.design !== companionDesign.id) {
    problems.push(`design stamp is "${record.design}", expected "${companionDesign.id}"`);
  }
  if (JSON.stringify(gate.suppressed) !== JSON.stringify(expected.suppressed)) {
    problems.push(`suppressed ${JSON.stringify(gate.suppressed)}, expected ${JSON.stringify(expected.suppressed)}`);
  }
  if (JSON.stringify(deniedIds) !== JSON.stringify([...expected.deniedCallIds].sort())) {
    problems.push(`denied [${deniedIds.join(",")}], expected [${expected.deniedCallIds.join(",")}]`);
  }
  if (JSON.stringify(proposalStates) !== JSON.stringify(expected.proposalStates)) {
    problems.push(`proposals ${JSON.stringify(proposalStates)}, expected ${JSON.stringify(expected.proposalStates)}`);
  }
  if (expected.cameraEvents !== undefined && record.camera.length !== expected.cameraEvents) {
    problems.push(`camera events ${record.camera.length}, expected ${expected.cameraEvents}`);
  }
  if (expected.answers !== undefined && record.answers.length !== expected.answers) {
    problems.push(`answers ${record.answers.length}, expected ${expected.answers}`);
  }
  if (gate.droppedActions.length > 0) {
    problems.push(`${plural(gate.droppedActions.length, "user action")} dropped instead of remapping`);
  }
  // Structural, every script: a camera look never carries a verdict.
  for (const event of record.camera) {
    if (event.safetyVerdict !== null) problems.push(`camera event carried a verdict: ${JSON.stringify(event)}`);
  }

  if (problems.length === 0) {
    lines.push(`   ✓ expectations hold — ${expected.probes}`);
    return { ok: true, lines };
  }
  for (const problem of problems) lines.push(`   ✗ ${problem}`);
  return { ok: false, lines };
}

export function main(): number {
  let scripts: { name: string; script: SessionScript }[];
  try {
    scripts = loadScripts();
  } catch (e) {
    console.error(`companion scripts unreadable: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
  if (scripts.length === 0) {
    console.error(`no session scripts found under ${SCRIPTS_DIR}`);
    return 1;
  }

  console.log(`LeChef design "companion" — replaying ${plural(scripts.length, "script")}\n`);
  let failures = 0;
  for (const { name, script } of scripts) {
    console.log(`── ${name} (${script.job}, ${script.sessionId})`);
    try {
      const { ok, lines } = replayOne(name, script);
      for (const line of lines) console.log(line);
      if (!ok) failures += 1;
    } catch (e) {
      failures += 1;
      console.log(`   ✗ replay failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    console.log("");
  }

  console.log(`${plural(scripts.length, "script")}: ${scripts.length - failures} pass, ${failures} fail`);
  return failures > 0 ? 1 : 0;
}

if (import.meta.main) {
  process.exit(main());
}
