import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CANON_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../lechef/canon");

interface PinnedFile {
  path: string;
  sha256: string;
  upstream: string;
  branch: string;
  commit: string;
}

function provenance(): PinnedFile[] {
  const md = readFileSync(join(CANON_DIR, "PROVENANCE.md"), "utf8");
  const m = md.match(/```json\n([\s\S]*?)\n```/);
  if (!m) throw new Error("canon/PROVENANCE.md carries no ```json pinned-files block");
  const parsed: unknown = JSON.parse(m[1]);
  if (typeof parsed !== "object" || parsed === null || !Array.isArray((parsed as { files: unknown }).files)) {
    throw new Error("pinned-files block must be an object with a files array");
  }
  return (parsed as { files: PinnedFile[] }).files;
}

function sha256Of(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

describe("canon pinning: verbatim data with provenance", () => {
  it("every pinned file exists and its SHA256 matches the recorded provenance", () => {
    const files = provenance();
    expect(files.length).toBeGreaterThan(0);
    for (const f of files) {
      const actual = sha256Of(join(CANON_DIR, f.path));
      expect(actual).toBe(f.sha256);
      expect(f.commit).toMatch(/^[0-9a-f]{40}$/);
      expect(f.branch.length).toBeGreaterThan(0);
    }
  });

  it("the pinned FLIngredientFacts dataset passes its own TypeScript conformance kit", () => {
    const runner = join(CANON_DIR, "ingredient-facts/conformance/runners/typescript/run_conformance.ts");
    const proc = Bun.spawnSync(["bun", runner], { stdout: "pipe", stderr: "pipe" });
    const out = proc.stdout.toString() + proc.stderr.toString();
    expect(proc.exitCode).toBe(0);
    expect(out).toMatch(/cases passed/);
  });
});
