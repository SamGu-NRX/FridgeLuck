/**
 * Harness CLI — loads session scripts and emits one RunRecord JSON per
 * session. Runs entirely offline: fake provider + fake phone, no network.
 *
 *   bun src/lechef/run/cli.ts --sessions=<dir-or-file> --out=<dir> [--design=<name>] [--pretty]
 *
 * - --sessions  a session script JSON file, or a directory whose *.json
 *               files (recursive) are session scripts
 * - --out       output directory for RunRecord files (<sessionId>.json)
 * - --design    override the script's design label (design x session runs)
 * - --pretty    pretty-print the emitted JSON
 *
 * The CLI is raw-record-only: it never scores, never judges approvals, and
 * never talks to a model API. Exit code 1 when any session failed or none
 * were found.
 */

import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseSessionScript, type SessionScript } from "../fakeModel.js";
import { runSession } from "./harness.js";

interface CliArgs {
  readonly sessions: string;
  readonly out: string;
  readonly design?: string;
  readonly pretty: boolean;
}

function parseArgs(argv: readonly string[]): CliArgs {
  let sessions: string | undefined;
  let out: string | undefined;
  let design: string | undefined;
  let pretty = false;
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
      case "--design":
        if (!value) throw new Error("--design needs a name");
        design = value;
        break;
      case "--pretty":
        pretty = true;
        break;
      default:
        throw new Error(`unknown argument: ${key}`);
    }
  }
  if (!sessions || !out) {
    throw new Error("usage: bun src/lechef/run/cli.ts --sessions=<dir-or-file> --out=<dir> [--design=<name>] [--pretty]");
  }
  return { sessions, out, ...(design !== undefined ? { design } : {}), pretty };
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

  mkdirSync(args.out, { recursive: true });
  let failures = 0;
  for (const file of files) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      const script: SessionScript = parseSessionScript(parsed);
      const effective = args.design !== undefined ? { ...script, design: args.design } : script;
      const record = runSession(effective);
      const outPath = join(args.out, `${record.sessionId}.json`);
      writeFileSync(outPath, JSON.stringify(record, null, args.pretty ? 2 : undefined) + "\n");
      console.log(
        `${record.sessionId}: design=${record.design} turns=${record.usage.turns} toolCalls=${record.toolCalls.length} ` +
          `proposals=${record.proposals.length} receipts=${record.receipts.length} timers=${record.timers.length} -> ${outPath}`
      );
    } catch (e) {
      failures += 1;
      console.error(`${file}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return failures > 0 ? 1 : 0;
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
