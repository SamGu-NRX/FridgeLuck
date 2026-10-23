import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

test("confirmation rate reads the before snapshot from a checkout containing a space", () => {
  const tmp = mkdtempSync(join(tmpdir(), "fridgeluck-confirmation-"));
  const root = join(tmp, "with space");
  try {
    const runDir = join(root, "backend", "gemini-agent", "src", "run");
    const canonDir = join(root, "backend", "gemini-agent", "src", "lechef", "canon", "ingredient-facts");
    const evaluationDir = join(root, "evaluation", "lechef-facts");
    mkdirSync(runDir, { recursive: true });
    mkdirSync(join(canonDir, "review"), { recursive: true });
    mkdirSync(evaluationDir, { recursive: true });
    for (const name of ["confirmation-rate.ts", "apply-facts-review.ts"]) {
      copyFileSync(new URL(`../../run/${name}`, import.meta.url), join(runDir, name));
    }
    const beforePath = join(evaluationDir, "before-facts.json");
    writeFileSync(beforePath, JSON.stringify({ facts: { rice: { allergens: { milk: { state: "unknown" } } } } }));
    writeFileSync(join(canonDir, "facts.json"), JSON.stringify({ facts: { rice: { allergens: { milk: { state: "free" } } } } }));
    const result = spawnSync(process.execPath, [join(runDir, "confirmation-rate.ts")], {
      cwd: root, encoding: "utf8", timeout: 10_000,
      env: { ...process.env, NODE_ENV: undefined }
    });
    expect({ status: result.status, stderr: result.stderr, error: result.error?.message }).toEqual({
      status: 0, stderr: "", error: undefined
    });
    expect(result.stdout).toContain("before: 10 of 10 (100.0%)  after: 9 of 10 (90.0%)");
    expect(result.stdout).toContain(`before snapshot: ${realpathSync(beforePath)}`);
    expect(result.stdout).toContain("applied 0, unchanged 0, refused 0 (nothing written)");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
