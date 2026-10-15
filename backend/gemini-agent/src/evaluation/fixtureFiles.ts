import { readFileSync, realpathSync } from "node:fs";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const DEFAULT_FIXTURES = fileURLToPath(new URL("../../evaluation-fixtures", import.meta.url));
type RequestFixture = "reverse-meal-question-v1.json" | "reverse-meal-states-v1.jsonl" | "decision-question.json" | "heldout-inputs.jsonl";

// Check the target name after resolving symlinks so a named input cannot point at a spec or labels.
export function readNamedFixture(directory: string, name: RequestFixture | "reverse-meal-replay-v1.json") {
  const approved = ["reverse-meal-question-v1.json", "reverse-meal-states-v1.jsonl", "decision-question.json", "heldout-inputs.jsonl", "reverse-meal-replay-v1.json"];
  if (!approved.includes(name)) throw new Error(`Unapproved fixture name: ${name}`);
  const path = resolve(directory, name), target = realpathSync(path);
  if (basename(target) !== name) throw new Error(`Fixture target must be named ${name}, resolved to ${target}`);
  return { path, bytes: readFileSync(target) };
}
