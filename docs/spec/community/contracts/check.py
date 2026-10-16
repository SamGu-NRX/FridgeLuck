#!/usr/bin/env python3
"""Contract checker for the FridgeLuck community spec.

Standard library only. Validates:
  1. every JSON Schema in schemas/ parses and carries $schema/$id/title;
  2. every example in examples/ named in manifest.json validates against its schema
     (request examples -> requests.schema.json#/$defs/<Op>, response examples -> the
     manifest's responseSchema), with external $ref resolution, format checks, and
     value constraints (pattern, minLength/maxLength, minimum/maximum,
     exclusiveMinimum);
  3. every file in examples/ is covered by the manifest (no orphan examples);
  4. every operation in the manifest has a response example or is a declared 204;
  5. OpenAPI operations match the manifest 1:1 (parsed from openapi.yaml with a
     deliberately small YAML-subset reader - the contract files are the source of
     truth, the OpenAPI document is kept in the subset it can read);
  6. every OpenAPI `schema:` value is a Schema Object (`{$ref: ...}`), never a
     bare string - a string `schema:` is not a valid OpenAPI 3.1 document;
  7. every cross-reference in ../SPEC.md resolves - both the `§N.N` form and the
     prose "section N.N" / "sections N-M" forms (overhaul citations excluded).

Run:  python3 contracts/check.py            (from anywhere)
Exit 0 = all checks pass.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCHEMAS = ROOT / "schemas"
EXAMPLES = ROOT / "examples"

ERRORS: list[str] = []


def err(msg: str) -> None:
    ERRORS.append(msg)


# ---------------------------------------------------------------- YAML subset
def read_yaml_subset(text: str) -> dict:
    """Minimal YAML reader covering exactly the shapes used by openapi.yaml:
    nested mappings, sequences, scalars, quoted strings, | block scalars,
    inline flow sequences [a, b], and inline flow mappings {key: value} whose
    values are scalars (used for Schema Object $refs)."""
    lines = []  # (indent, content)
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        lines.append((indent, raw.strip()))

    def parse_scalar(s: str):
        if s.startswith('"') and s.endswith('"'):
            return json.loads(s)  # JSON strings are valid YAML double-quoted scalars
        if s in ("true", "True"):
            return True
        if s in ("false", "False"):
            return False
        if s in ("null", "~", ""):
            return None
        if re.fullmatch(r"-?\d+", s):
            return int(s)
        if s.startswith("[") and s.endswith("]"):
            body = s[1:-1].strip()
            return [parse_scalar(p.strip()) for p in body.split(",")] if body else []
        if s == "{}":
            return {}
        if s.startswith("{") and s.endswith("}"):
            body = s[1:-1].strip()
            out: dict = {}
            if body:
                for part in body.split(","):
                    k, _, v = part.partition(":")
                    out[k.strip()] = parse_scalar(v.strip())
            return out
        return s

    def block_scalar(idx: int) -> tuple[str, int]:
        _, content = lines[idx]
        assert content.endswith(": |"), content
        out = []
        j = idx + 1
        base = None
        while j < len(lines) and lines[j][0] > lines[idx][0]:
            if base is None:
                base = lines[j][0]
            out.append(" " * (lines[j][0] - base) + lines[j][1])
            j += 1
        return "\n".join(out), j - 1

    def parse_block(idx: int, indent: int) -> tuple[dict, int]:
        obj: dict = {}
        i = idx
        while i < len(lines):
            ind, content = lines[i]
            if ind < indent:
                break
            if ind > indent:
                err(f"openapi.yaml: unexpected indentation at line with '{content[:40]}'")
                break
            if ": " in content:
                key, _, rest = content.partition(": ")
            elif content.endswith(":"):
                key, rest = content[:-1], ""
            else:
                err(f"openapi.yaml: cannot parse line '{content[:60]}'")
                break
            if rest == "|":
                val, i = block_scalar(i)
                obj[key] = val
                i += 1
                continue
            if rest == "":
                # nested block or null; a block sequence may sit at any deeper indent
                if i + 1 < len(lines) and lines[i + 1][1].startswith("- "):
                    val, i = parse_seq(i + 1, lines[i + 1][0])
                elif i + 1 < len(lines) and lines[i + 1][0] > ind:
                    val, i = parse_block(i + 1, lines[i + 1][0])
                else:
                    val, i = None, i + 1
            else:
                val, i = parse_scalar(rest), i + 1
            if key in obj:
                err(f"openapi.yaml: duplicate key '{key}'")
            obj[key] = val
        return obj, i

    def parse_seq(idx: int, indent: int) -> tuple[list, int]:
        out = []
        i = idx
        while i < len(lines):
            ind, content = lines[i]
            if ind != indent or not content.startswith("- "):
                break
            rest = content[2:]
            if ": " in rest or rest.endswith(":"):
                # mapping item; rewrite the line as a mapping entry and parse there
                lines[i] = (ind + 2, rest)
                obj, i = parse_block(i, ind + 2)
                out.append(obj)
            else:
                out.append(parse_scalar(rest))
                i += 1
        return out, i

    obj, _ = parse_block(0, lines[0][0])
    return obj


# ---------------------------------------------------------------- schema load
_schema_cache: dict[str, dict] = {}


def load_schema(ref: str) -> dict:
    if ref.startswith("#/"):
        raise ValueError(f"internal-only ref outside a document: {ref}")
    if "#" in ref:
        file_part, frag = ref.split("#", 1)
    else:
        file_part, frag = ref, ""
    base = "https://fridgeluck.dev/community/schemas/"
    if file_part.startswith(base):
        file_part = file_part[len(base):]  # $id-absolute refs resolve to the local schemas dir
    if "://" in file_part:
        raise ValueError(f"remote $ref unsupported: {ref}")
    path = SCHEMAS / file_part
    if not path.exists():
        raise FileNotFoundError(path)
    if str(path) not in _schema_cache:
        doc = json.loads(path.read_text())
        _schema_cache[str(path)] = doc
    doc = _schema_cache[str(path)]
    if frag:
        for part in frag.lstrip("/").split("/"):
            part = part.replace("~1", "/").replace("~0", "~")
            doc = doc[part]
    return doc


def resolve(schema: dict):
    seen = 0
    while isinstance(schema, dict) and "$ref" in schema:
        seen += 1
        if seen > 20:
            raise ValueError("circular $ref chain")
        schema = load_schema(schema["$ref"])
    return schema


FORMAT_PATTERNS = {
    "uuid": r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    "date-time": r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$",
    "date": r"^\d{4}-\d{2}-\d{2}$",
    "email": r"^[^@\s]+@[^@\s]+\.[^@\s]+$",
    "uri": r"^[a-zA-Z][a-zA-Z0-9+.-]*:\S+$",
}


def validate(instance, schema, where: str) -> None:
    schema = resolve(schema)
    if schema is True or schema == {}:
        return
    if schema is False:
        err(f"{where}: schema forbids any value")
        return

    if "anyOf" in schema:
        for sub in schema["anyOf"]:
            sub_errors = _capture(instance, sub)
            if not sub_errors:
                break
        else:
            err(f"{where}: matches none of anyOf")
        # continue validating siblings like description after anyOf
        for key in ("enum", "const", "format"):
            if key in schema:
                validate_keyword(instance, schema, key, where)
        return

    if "allOf" in schema:
        for sub in schema["allOf"]:
            validate(instance, sub, where)

    for key in ("enum", "const", "format"):
        if key in schema:
            validate_keyword(instance, schema, key, where)

    expected = schema.get("type")
    if expected is not None:
        types = expected if isinstance(expected, list) else [expected]
        pytypes = {"object": dict, "array": list, "string": str, "integer": int,
                   "number": (int, float), "boolean": bool, "null": type(None)}
        if not isinstance(instance, tuple(pytypes[t] for t in types if t in pytypes)):
            err(f"{where}: expected type {types}, got {type(instance).__name__}")
            return
        if "integer" in types and isinstance(instance, bool):
            err(f"{where}: boolean is not an integer")
            return
        if "integer" in types and isinstance(instance, bool):
            err(f"{where}: boolean is not an integer")
            return

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            err(f"{where}: string shorter than minLength={schema['minLength']}")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            err(f"{where}: string longer than maxLength={schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            err(f"{where}: {instance[:40]!r} does not match pattern {schema['pattern']!r}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            err(f"{where}: {instance} below minimum={schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            err(f"{where}: {instance} above maximum={schema['maximum']}")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            err(f"{where}: {instance} not above exclusiveMinimum={schema['exclusiveMinimum']}")

    if isinstance(instance, dict):
        for r in schema.get("required", []):
            if r not in instance:
                err(f"{where}: missing required property '{r}'")
        props = schema.get("properties", {})
        ap = schema.get("additionalProperties", True)
        for k, v in instance.items():
            if k in props:
                validate(v, props[k], f"{where}.{k}")
            elif ap is False:
                err(f"{where}: additional property '{k}' not allowed")
            elif isinstance(ap, dict):
                validate(v, ap, f"{where}.{k}")
    elif isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            err(f"{where}: fewer than minItems={schema['minItems']}")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            err(f"{where}: more than maxItems={schema['maxItems']}")
        if schema.get("uniqueItems"):
            marks = [json.dumps(x, sort_keys=True) for x in instance]
            if len(set(marks)) != len(marks):
                err(f"{where}: uniqueItems violated")
        items = schema.get("items", {})
        for i, v in enumerate(instance):
            validate(v, items, f"{where}[{i}]")


def validate_keyword(instance, schema, key: str, where: str) -> None:
    if key == "enum" and instance not in schema["enum"]:
        err(f"{where}: {instance!r} not in enum {schema['enum']}")
    if key == "const" and instance != schema["const"]:
        err(f"{where}: {instance!r} != const {schema['const']!r}")
    if key == "format":
        pat = FORMAT_PATTERNS.get(schema["format"])
        if pat and isinstance(instance, str) and not re.match(pat, instance):
            err(f"{where}: {instance!r} is not a valid {schema['format']}")


def _capture(instance, schema) -> list[str]:
    global ERRORS
    saved = ERRORS
    ERRORS = []
    validate(instance, schema, "probe")
    out, ERRORS = ERRORS, saved
    return out


# ---------------------------------------------------------------- main
def main() -> int:
    # 1. schemas parse
    schema_files = sorted(SCHEMAS.glob("*.schema.json"))
    if not schema_files:
        err("no schema files found")
    for f in schema_files:
        try:
            doc = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            err(f"{f.name}: invalid JSON ({e})")
            continue
        for key in ("$schema", "$id", "title"):
            if key not in doc:
                err(f"{f.name}: missing '{key}'")

    # 2/3/4. manifest-driven example validation
    try:
        manifest = json.loads((ROOT / "manifest.json").read_text())
    except json.JSONDecodeError as e:
        print(f"manifest.json invalid: {e}")
        return 1

    covered: set[str] = set()
    NO_BODY_RESPONSE = {"revokeSession", "deleteAccount", "withdrawPublication", "removeVote",
                        "revokeInvite", "removeMember", "leaveTable", "deleteCard",
                        "addBlock", "removeBlock", "createReport", "castVote"}
    for opid, entry in manifest.items():
        for part in ("request", "response"):
            fname = entry.get(part)
            if not fname:
                continue
            covered.add(fname)
            fpath = EXAMPLES / fname
            if not fpath.exists():
                err(f"{opid}: example file {fname} missing")
                continue
            try:
                ex = json.loads(fpath.read_text())
            except json.JSONDecodeError as e:
                err(f"{opid}: {fname} invalid JSON ({e})")
                continue
            sref = entry.get(part + "Schema")
            if not sref:
                err(f"{opid}: {part} example has no schema in manifest")
                continue
            try:
                schema = load_schema(sref)
            except (FileNotFoundError, KeyError, ValueError) as e:
                err(f"{opid}: cannot load schema {sref} ({e})")
                continue
            validate(ex, schema, f"{opid}.{part}")

        if "response" not in entry and opid not in NO_BODY_RESPONSE:
            err(f"{opid}: no response example and not in the 204 set")
        if "request" in entry and not entry.get("requestSchema"):
            err(f"{opid}: request example has no requestSchema")

    orphans = sorted(p.name for p in EXAMPLES.glob("*.json") if p.name not in covered and p.name != "manifest.json")
    for name in orphans:
        err(f"examples/{name} is not referenced by manifest.json")

    # 5. openapi.yaml operations == manifest operations
    openapi_path = ROOT / "openapi.yaml"
    try:
        doc = read_yaml_subset(openapi_path.read_text())
    except Exception as e:  # noqa: BLE001
        err(f"openapi.yaml could not be parsed: {e}")
        doc = {}
    spec_ops = set()
    for path, methods in (doc.get("paths") or {}).items():
        if not isinstance(methods, dict):
            continue
        for method, op in methods.items():
            if method.lower() in ("get", "post", "put", "patch", "delete") and isinstance(op, dict):
                oid = op.get("operationId")
                if oid:
                    spec_ops.add(oid)
                else:
                    err(f"openapi.yaml: {method.upper()} {path} has no operationId")
    manifest_ops = set(manifest)
    for oid in sorted(manifest_ops - spec_ops):
        err(f"openapi.yaml: operation {oid} missing (present in manifest)")
    for oid in sorted(spec_ops - manifest_ops):
        err(f"openapi.yaml: operation {oid} has no manifest entry")
    info = doc.get("info") or {}
    if doc.get("openapi") != "3.1.0":
        err(f"openapi.yaml: expected openapi 3.1.0, found {doc.get('openapi')!r}")
    if not info.get("title") or not info.get("version"):
        err("openapi.yaml: info.title/info.version missing")

    # 6. every OpenAPI schema value is a Schema Object, never a bare string;
    #    every Response Object carries a description (required in OpenAPI 3.1)
    def walk_schema_values(node, where: str, in_responses: bool = False) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "schema" and isinstance(v, str):
                    err(f"openapi.yaml: {where}: schema is a bare string, "
                        f"not a Schema Object: {v!r}")
                elif in_responses and re.fullmatch(r"(?:[1-5]\d{2}|default)", str(k).strip('"')) \
                        and isinstance(v, dict) and not isinstance(v.get("description"), str):
                    err(f"openapi.yaml: {where}.{k}: response object has no description")
                else:
                    walk_schema_values(v, f"{where}.{k}",
                                       in_responses=in_responses or str(k) == "responses")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk_schema_values(v, f"{where}[{i}]", in_responses=in_responses)

    walk_schema_values(doc, "openapi")

    # 6b. every path template variable is declared as a path parameter
    for path, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        shared = item.get("parameters") if isinstance(item.get("parameters"), list) else []
        for method, op in item.items():
            if method.lower() not in ("get", "post", "put", "patch", "delete") \
                    or not isinstance(op, dict):
                continue
            declared = set()
            for p in (op.get("parameters") or []) + shared:
                if isinstance(p, dict) and p.get("in") == "path":
                    declared.add(p.get("name"))
            for v in sorted(set(re.findall(r"\{(\w+)\}", path)) - declared):
                err(f"openapi.yaml: {method.upper()} {path}: path parameter {{{v}}} not declared")

    # 7. SPEC.md cross-references resolve (§N.N and prose "section N" forms)
    spec_path = ROOT.parent / "SPEC.md"
    if spec_path.exists():
        spec_text = spec_path.read_text()
        headers: set[str] = set()
        for line in spec_text.splitlines():
            hm = re.match(r"^#{2,3} (\d+)(?:\.(\d+))?[\.\s]", line)
            if hm:
                headers.add(hm.group(1))
                if hm.group(2):
                    headers.add(f"{hm.group(1)}.{hm.group(2)}")
        for lineno, line in enumerate(spec_text.splitlines(), 1):
            stripped = re.sub(r"\boverhaul §\d+(?:\.\d+)?", "", line)
            refs = [(f"§{r}", r) for r in re.findall(r"§(\d+(?:\.\d+)?)", stripped)]
            refs += [(f"section {r}", r)
                     for r in re.findall(r"\bsection (\d+(?:\.\d+)?)", stripped, re.I)]
            for lo, hi in re.findall(r"\bsections (\d+)(?:[–-](\d+))?", stripped, re.I):
                refs.append((f"sections {lo}", lo))
                if hi:
                    refs.append((f"sections {hi}", hi))
            for form, ref in refs:
                if ref not in headers:
                    err(f"SPEC.md:{lineno}: cross-reference '{form}' does not resolve")

    if ERRORS:
        print(f"FAIL - {len(ERRORS)} problem(s):")
        for e in ERRORS:
            print(f"  - {e}")
        return 1
    n_examples = sum(1 for p in EXAMPLES.glob("*.json"))
    print(f"OK - {len(schema_files)} schemas, {len(manifest_ops)} operations, "
          f"{n_examples} example files, OpenAPI 3.1 in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
