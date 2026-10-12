/**
 * Design-arm composition runner — parent-owned join tool.
 *
 * Runs a directory of harness session scripts through the design runner
 * (run/designRunner.ts) under one or more LeChefDesign configs, emitting one
 * RunRecord per session per arm so the suite D scorer (evaluation/suites/
 * lechef/suite.py) can score each arm separately.
 *
 *   bun src/lechef/run/composeDesignArms.ts --sessions=<dir> --out=<dir> [--arms=a,b,c]
 *
 * - --sessions  directory of SessionScript JSON files (recursive, e.g. the
 *               suite D derived scripts under out/harness-scripts)
 * - --out       output root; records land in <out>/<arm>/records/<sessionId>.json
 * - --arms      comma-separated design ids (default: companion,planner,coach)
 *
 * This tool is raw-record-only like the CLI: it never scores and never
 * judges approvals. Exit code 1 when any session failed in any arm.
 *
 * Rationale (suite D composition): the plain CLI's --design flag only stamps
 * the record label — it runs the plain runSession, not the design runner.
 * Design-aware scorecards need runDesignSession so budgets, policy denials
 * and suggestion silence actually gate the replay. The corpus of record is
 * design-unset; arms re-run it under each design to measure interference.
 */

import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseSessionScript, type SessionScript } from "../fakeModel.js";
import { gateScript, runDesignSession } from "./designRunner.js";
import { companionDesign } from "../designs/companion/design.js";
import { plannerDesign } from "../designs/planner/design.js";
import { coachDesign } from "../designs/coach/design.js";

const DESIGNS: Record<string, Parameters<typeof runDesignSession>[1]> = {
  companion: companionDesign,
  planner: plannerDesign,
  coach: coachDesign,
};

interface CliArgs {
  readonly sessions: string;
  readonly out: string;
  readonly arms: readonly string[];
}

function parseArgs(argv: readonly string[]): CliArgs {
  let sessions: string | undefined;
  let out: string | undefined;
  let arms: string[] = ["companion", "planner", "coach"];
  for (const arg of argv) {
    const eq = arg.indexOf("=");
    const key = eq === -1 ? arg : arg.slice(0, eq);
    const value = eq === -1 ? undefined : arg.slice(eq + 1);
    switch (key) {
      case "--sessions":
        if (!value) throw new Error("--sessions needs a path");
        sessions = value;
        break;
      case "--out":
        if (!value) throw new Error("--out needs a path");
        out = value;
        break;
      case "--arms":
        if (!value) throw new Error("--arms needs a comma-separated list");
        arms = value.split(",").map((a) => a.trim()).filter(Boolean);
        break;
      default:
        throw new Error(`unknown argument: ${key}`);
    }
  }
  if (!sessions || !out) {
    throw new Error(
      "usage: bun src/lechef/run/composeDesignArms.ts --sessions=<dir> --out=<dir> [--arms=companion,planner,coach]"
    );
  }
  for (const arm of arms) {
    if (!Object.prototype.hasOwnProperty.call(DESIGNS, arm)) {
      throw new Error(`unknown design id: ${arm} (known: ${Object.keys(DESIGNS).join(", ")})`);
    }
  }
  return { sessions, out, arms };
}

function listScriptFiles(path: string): string[] {
  const stat = statSync(path);
  if (stat.isFile()) return [path];
  const files: string[] = [];
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    if (entry.isDirectory()) files.push(...listScriptFiles(join(path, entry.name)));
    else if (entry.isFile() && entry.name.endsWith(".json")) files.push(join(path, entry.name));
  }
  return files.sort();
}

export function main(argv: readonly string[]): number {
  let args: CliArgs;
  try {
    args = parseArgs(argv);
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    return 1;
  }

  let files: string[];
  try {
    files = listScriptFiles(resolve(args.sessions));
  } catch (e) {
    console.error(`sessions path unreadable: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
  if (files.length === 0) {
    console.error(`no session scripts found under ${args.sessions}`);
    return 1;
  }

  const parsed = files.map((file) => ({
    file,
    script: parseSessionScript(JSON.parse(readFileSync(file, "utf8")) as unknown),
  }));

  let anyFailures = 0;
  for (const arm of args.arms) {
    const design = DESIGNS[arm];
    const recordsDir = join(args.out, arm, "records");
    mkdirSync(recordsDir, { recursive: true });
    let suppressed = 0;
    let denied = 0;
    const failedSessionIds: string[] = [];
    for (const { file, script } of parsed) {
      try {
        const record = runDesignSession(script, design);
        writeFileSync(join(recordsDir, `${record.sessionId}.json`), JSON.stringify(record) + "\n");
        // Suppression lives on the gate output, not on the record; policy
        // denials are tool calls whose result carries error "policy-denied".
        suppressed += gateScript(script, design).suppressed.length;
        denied += record.toolCalls.filter(
          (c) => c.status === "error" && (c.result as { error?: string } | null)?.error === "policy-denied"
        ).length;
      } catch (e) {
        const sessionId = file.split("/").pop()?.replace(/\.json$/, "") ?? file;
        failedSessionIds.push(sessionId);
        console.error(`[${arm}] ${sessionId}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    const manifest = {
      arm,
      design: design.id,
      sessions: parsed.length,
      scored: parsed.length - failedSessionIds.length,
      failedSessionIds,
      suppressedTurns: suppressed,
      policyDeniedCalls: denied,
    };
    writeFileSync(join(args.out, arm, "composition.json"), JSON.stringify(manifest, null, 2) + "\n");
    console.log(
      `[${arm}] design="${design.id}" sessions=${parsed.length} scored=${manifest.scored} ` +
        `failed=${failedSessionIds.length} suppressedTurns=${suppressed} policyDeniedCalls=${denied} -> ${recordsDir}`
    );
    if (failedSessionIds.length > 0) {
      console.log(`[${arm}] failed sessions (script approves a proactively-denied proposal): ${failedSessionIds.join(", ")}`);
      anyFailures = 1; // real design-vs-corpus interference: surfaced, not silent
    }
  }
  return anyFailures;
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
