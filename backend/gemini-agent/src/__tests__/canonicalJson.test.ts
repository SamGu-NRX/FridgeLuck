import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { canonicalJson } from "../evaluation/canonicalJson.js";

describe("canonical JSON", () => {
  test("sorts recursively with compact Unicode JSON and preserves decoded evidence", () => {
    const value = { z: [{ b: "café 🥕\n", a: true }], a: null, n: 0.85 };
    expect(canonicalJson(value)).toBe('{"a":null,"n":0.85,"z":[{"a":true,"b":"café 🥕\\n"}]}');
    expect(JSON.parse(canonicalJson(value))).toEqual(value);
    expect(canonicalJson({ "10": 1, "2": 2 })).toBe('{"10":1,"2":2}');
  });
  test("matches Python byte-for-byte on nondivergent shapes including code-point key order", () => {
    const value = { "🥕": 0.85, "": 2, a: [true, false, null, "東京", { z: "\t\"\\", a: 0.5 }] };
    const python = spawnSync("python3", ["-B", "-c", "import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(',', ':'),ensure_ascii=False,allow_nan=False),end='')"], { input: JSON.stringify(value), encoding: "utf8" });
    expect(python.status).toBe(0);
    expect(canonicalJson(value)).toBe(python.stdout);
  });
  test("Python float spelling diverges but decoded evidence agrees", () => {
    const python = spawnSync("python3", ["-B", "-c", "import json; print(json.dumps({'weight':1.0,'score':0.0},sort_keys=True,separators=(',', ':'),ensure_ascii=False,allow_nan=False),end='')"], { encoding: "utf8" });
    expect(python.status).toBe(0);
    const request = { weight: 1, score: 0 };
    expect(python.stdout).toBe('{"score":0.0,"weight":1.0}');
    expect(canonicalJson(request)).toBe('{"score":0,"weight":1}');
    expect(JSON.parse(python.stdout)).toEqual(JSON.parse(canonicalJson(request)));
  });
  for (const [name, value, reason] of [
    ["NaN", NaN, "nonfinite number"], ["Infinity", Infinity, "nonfinite number"],
    ["negative Infinity", -Infinity, "nonfinite number"], ["undefined", undefined, "unsupported undefined"],
    ["nested undefined", { a: undefined }, "unsupported undefined at $.a"],
    ["function", () => 1, "unsupported function"], ["bigint", 1n, "unsupported bigint"],
    ["symbol", Symbol("a"), "unsupported symbol"], ["date", new Date(0), "non-plain object"],
    ["map", new Map(), "non-plain object"], ["sparse array", new Array(1), "sparse or decorated array"]
  ] as const) test(`rejects ${name}`, () => expect(() => canonicalJson(value)).toThrow(reason));
  test("rejects cycles, accessors and symbol keys", () => {
    const cycle: unknown[] = []; cycle.push(cycle);
    expect(() => canonicalJson(cycle)).toThrow("cycle");
    expect(() => canonicalJson({ get a() { return 1; } })).toThrow("accessor");
    expect(() => canonicalJson({ [Symbol("x")]: 1 })).toThrow("symbol key");
  });
  test("shared noncyclic objects and null-prototype objects are valid", () => {
    const shared = { a: 1 };
    expect(canonicalJson([shared, shared])).toBe('[{"a":1},{"a":1}]');
    expect(canonicalJson(Object.assign(Object.create(null), { b: 2, a: 1 }))).toBe('{"a":1,"b":2}');
  });
});
