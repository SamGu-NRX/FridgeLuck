import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { DEFAULT_FIXTURES, readNamedFixture } from "../evaluation/fixtureFiles.js";
import { parseLiveOptions, runLiveDecisions } from "../evaluation/runLiveDecisions.js";

test("runner defaults to committed fixtures and all request bodies exclude diagnostic documents", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fixture-boundary-"));
  try {
    const key = join(dir, "mock.env");
    writeFileSync(key, "OPENAI_API_KEY=sk-offline-fixture-test\n", { mode: 0o600 });
    const args = ["--families", "reverse-meal-v1,heldout18", "--out", join(dir, "out"), "--key-file", key, "--spend-ceiling-usd", "1", "--confirm-live"];
    expect(parseLiveOptions(args).fixtures).toBe(DEFAULT_FIXTURES);
    const documents = ["reverse-meal-spec-v1.md", "evaluation-spec.md", "README.md"].map(name => readFileSync(join(DEFAULT_FIXTURES, name), "utf8"));
    let requests = 0;
    await runLiveDecisions(args, { fetch: async (_, init) => {
      requests++;
      const text = String(init.body), body = JSON.parse(text);
      for (const document of documents) {
        expect(text).not.toContain(document);
        // Paragraphs include outcome explanations that must not leak through either input or question.
        for (const paragraph of document.split(/\n\s*\n/).filter(p => p.length > 200)) {
          expect(JSON.stringify(body)).not.toContain(JSON.stringify(paragraph).slice(1, -1));
        }
      }
      expect(Object.keys(body).sort()).toEqual(["input", "model", "questions"]);
      expect(Object.keys(JSON.parse(body.input)).sort()).toEqual(["hardFailReasons", "signals"]);
      return Response.json({ answers: [{ name: body.questions[0].name, type: "choice", choice: "estimate_only" }] });
    } });
    expect(requests).toBe(34);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("explicit fixture loading refuses unapproved names and symlinks to diagnostic documents", () => {
  const dir = mkdtempSync(join(tmpdir(), "fixture-target-"));
  try {
    for (const name of ["reverse-meal-question-v1.json", "reverse-meal-states-v1.jsonl", "decision-question.json", "heldout-inputs.jsonl", "reverse-meal-replay-v1.json"] as const) {
      symlinkSync(join(DEFAULT_FIXTURES, "evaluation-spec.md"), join(dir, name));
      expect(() => readNamedFixture(dir, name)).toThrow(`must be named ${name}`);
    }
    expect(() => readNamedFixture(DEFAULT_FIXTURES, "README.md" as never)).toThrow("Unapproved fixture name");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
