/**
 * Loader probes: an absent example file is null (the suite's fallback path),
 * but a malformed or unreadable one must throw — contract breakage may not
 * pose as contract absence. Against the previous bare-catch loader, the
 * malformed-file expectation fails (the loader returned null).
 */
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";
import { readExampleFile } from "./contractArtifacts.js";

describe("readExampleFile", () => {
  const dir = mkdtempSync(join(tmpdir(), "fl-examples-"));
  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("returns null only for an absent file (ENOENT)", () => {
    expect(readExampleFile(join(dir, "missing.request.json"))).toBeNull();
  });

  test("a malformed example throws instead of posing as an absent example", () => {
    const p = join(dir, "broken.request.json");
    writeFileSync(p, "{ not json", "utf8");
    expect(() => readExampleFile(p)).toThrow();
  });
});
