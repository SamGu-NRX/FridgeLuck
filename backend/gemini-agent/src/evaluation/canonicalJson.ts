export function canonicalJson(value: unknown): string {
  const ancestors = new Set<object>();
  function encode(item: unknown, path: string): string {
    if (item === null) return "null";
    if (typeof item === "string" || typeof item === "boolean") return JSON.stringify(item);
    if (typeof item === "number") {
      if (!Number.isFinite(item)) throw new Error(`Canonical JSON: nonfinite number at ${path}`);
      // Python retains float spelling (1.0, -0.0); JS numbers lose that type.
      // Compare decoded objects for evidence parity, never those numeric bytes.
      return JSON.stringify(item);
    }
    if (typeof item !== "object") throw new Error(`Canonical JSON: unsupported ${typeof item} at ${path}`);
    if (!Array.isArray(item) && Object.getPrototypeOf(item) !== Object.prototype && Object.getPrototypeOf(item) !== null) {
      throw new Error(`Canonical JSON: non-plain object at ${path}`);
    }
    if (ancestors.has(item)) throw new Error(`Canonical JSON: cycle at ${path}`);
    if (Object.getOwnPropertySymbols(item).length) throw new Error(`Canonical JSON: symbol key at ${path}`);
    ancestors.add(item);
    let encoded: string;
    if (Array.isArray(item)) {
      if (Object.keys(item).length !== item.length) throw new Error(`Canonical JSON: sparse or decorated array at ${path}`);
      encoded = `[${Array.from(item, (v, i) => encode(v, `${path}[${i}]`)).join(",")}]`;
    } else {
      // Python sorts by Unicode code point, not JavaScript's UTF-16 code units.
      const keys = Object.keys(item).sort((a, b) => {
        const x = Array.from(a, c => c.codePointAt(0)!);
        const y = Array.from(b, c => c.codePointAt(0)!);
        for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i]! - y[i]!;
        return x.length - y.length;
      });
      encoded = `{${keys.map(key => {
        const descriptor = Object.getOwnPropertyDescriptor(item, key)!;
        if (!("value" in descriptor)) throw new Error(`Canonical JSON: accessor at ${path}.${key}`);
        return `${JSON.stringify(key)}:${encode(descriptor.value, `${path}.${key}`)}`;
      }).join(",")}}`;
    }
    ancestors.delete(item);
    return encoded;
  }
  return encode(value, "$");
}
