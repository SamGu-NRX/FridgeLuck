#!/usr/bin/env python3
"""Read-only packer: adapt existing owners' PUBLIC artifacts into capsules.

    python3 tools/experiment-capsules/pack.py \
        --spec tools/experiment-capsules/specs.json \
        --out tools/experiment-capsules/results

For every spec in the spec file, pack.py:

1. validates the spec strictly (unknown fields, credential-shaped or
   volatile keys, path traversal — all rejected),
2. refuses to run when the declared toolchain version does not match the
   running interpreter (a capsule must not claim a toolchain it was not
   packed with),
3. computes sha256 digests for every declared source/import file,
4. validates the import closure — a spec whose sources import undeclared
   local files, undeclared external dependencies, or dynamic imports
   without a declared coverage gap FAILS here; the packer never emits a
   binding the contract checker would reject,
5. copies every declared output into ``<out>/<capsule_id>/outputs/`` and
   records its digest, bytes, origin path and stored name in the binding.

Hard constraints (verified by tests, enforced by construction):

- **No all-repository hash sweep.** Only spec-declared paths are read and
  hashed, so unrelated studies can never be invalidated by a re-pack.
- **No hidden labels.** A capsule directory contains only ``binding.json``
  and ``outputs/``; verify.py rejects anything else.
- **No raw keys.** Credential-shaped fields are schema findings at both
  the spec and the binding layer; nothing is read from the environment.
- **Never overwrite an owner's manifest.** Owners' files are opened
  read-only; every write is bound to ``--out`` (guard below), and owner
  manifest paths are never written.
- **Never call any owner's live endpoint.** This tool is network-free by
  construction: it imports no network module and never executes owner
  code — owner studies are packed from their published files, never run.

Trust limits (README.md): digests bind content, not intent. A consistent
malicious rewrite passes without an external root of trust.
"""

from __future__ import annotations

import argparse
import json
import platform
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from capsule_model import (  # noqa: E402
    SCHEMA_VERSION,
    _check_safe_path,
    _walk_forbidden_keys,
    canonical_json_bytes,
    parse_binding,
    sha256_hex,
)
from import_scan import analyze_binding_sources  # noqa: E402

REPO_ROOT = TOOLS_DIR.parents[1]

_SPEC_TOP_KEYS = {"schema_version", "specs"}
_SPEC_KEYS = {
    "capsule_id",
    "title",
    "owner",
    "sources",
    "toolchain",
    "permitted_inputs",
    "model_transport",
    "coverage_gaps",
    "outputs",
}
_SOURCE_KEYS = {"path", "role"}
_OUTPUT_KEYS = {"origin_path", "stored_as"}


def spec_errors(raw: object) -> list[str]:
    """Validate the pack-spec document; return human-readable errors."""
    errors: list[str] = []
    if not isinstance(raw, dict):
        return ["spec file must be a JSON object"]
    for key in sorted(raw):
        if key not in _SPEC_TOP_KEYS:
            errors.append(f"unknown spec field {key!r}")
    forbidden: list = []
    _walk_forbidden_keys(raw, "spec", forbidden)
    errors.extend(f"{f.path}: {f.detail}" for f in forbidden)
    if raw.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must be {SCHEMA_VERSION!r}")
    specs = raw.get("specs")
    if not isinstance(specs, list) or not specs:
        errors.append("specs must be a non-empty list")
        return errors
    seen_ids: set[str] = set()
    for i, spec in enumerate(specs):
        where = f"specs[{i}]"
        if not isinstance(spec, dict):
            errors.append(f"{where}: must be an object")
            continue
        for key in sorted(spec):
            if key not in _SPEC_KEYS:
                errors.append(f"{where}: unknown field {key!r}")
        capsule_id = spec.get("capsule_id")
        if not isinstance(capsule_id, str) or not capsule_id:
            errors.append(f"{where}: capsule_id must be a non-empty string")
        elif capsule_id in seen_ids:
            errors.append(f"{where}: duplicate capsule_id {capsule_id!r}")
        else:
            seen_ids.add(capsule_id)
        for field in ("title", "owner"):
            if not isinstance(spec.get(field), str) or not spec[field]:
                errors.append(f"{where}: {field} must be a non-empty string")

        sources = spec.get("sources")
        if not isinstance(sources, list) or not sources:
            errors.append(f"{where}: sources must be a non-empty list")
        else:
            seen_paths: set[str] = set()
            for j, source in enumerate(sources):
                s_where = f"{where}.sources[{j}]"
                if not isinstance(source, dict) or set(source) != _SOURCE_KEYS:
                    errors.append(f"{s_where}: must be an object with keys {sorted(_SOURCE_KEYS)}")
                    continue
                path = source.get("path")
                path_findings: list = []
                path_ok = _check_safe_path(path, f"{s_where}.path", path_findings)
                if path_ok:
                    if path in seen_paths:
                        errors.append(f"{s_where}: duplicate source path {path!r}")
                    seen_paths.add(path)
                else:
                    errors.append(f"{s_where}.path: invalid path {path!r}")
                if source.get("role") not in ("source", "import"):
                    errors.append(f"{s_where}.role: must be 'source' or 'import'")

        toolchain = spec.get("toolchain")
        if not isinstance(toolchain, dict):
            errors.append(f"{where}: toolchain must be an object")
        elif toolchain.get("language") != "python" or not isinstance(
            toolchain.get("language_version"), str
        ):
            errors.append(f"{where}: toolchain must declare python language_version")

        permitted = spec.get("permitted_inputs")
        if not isinstance(permitted, list) or not permitted:
            errors.append(f"{where}: permitted_inputs must be a non-empty list")
        else:
            for j, path in enumerate(permitted):
                if not _check_safe_path(path, f"{where}.permitted_inputs[{j}]", []):
                    errors.append(f"{where}.permitted_inputs[{j}]: invalid path {path!r}")

        if not isinstance(spec.get("model_transport"), dict):
            errors.append(f"{where}: model_transport must be an object")
        if not isinstance(spec.get("coverage_gaps"), list):
            errors.append(f"{where}: coverage_gaps must be a list")

        outputs = spec.get("outputs")
        if not isinstance(outputs, list) or not outputs:
            errors.append(f"{where}: outputs must be a non-empty list")
        else:
            seen_stored: set[str] = set()
            for j, output in enumerate(outputs):
                o_where = f"{where}.outputs[{j}]"
                if not isinstance(output, dict) or set(output) != _OUTPUT_KEYS:
                    errors.append(
                        f"{o_where}: must be an object with keys {sorted(_OUTPUT_KEYS)}"
                    )
                    continue
                origin = output.get("origin_path")
                if not _check_safe_path(origin, f"{o_where}.origin_path", []):
                    errors.append(f"{o_where}.origin_path: invalid path {origin!r}")
                stored = output.get("stored_as")
                if (
                    not isinstance(stored, str)
                    or not stored
                    or "/" in stored
                    or stored in (".", "..")
                ):
                    errors.append(f"{o_where}.stored_as: must be a bare file name")
                elif stored in seen_stored:
                    errors.append(f"{o_where}.stored_as: duplicate stored name {stored!r}")
                else:
                    seen_stored.add(stored)
    return errors


def closure_findings(binding_raw: dict, repo_root: Path) -> list:
    """Import-coverage findings for a would-be binding (pack gate)."""
    binding, schema_findings = parse_binding(binding_raw)
    if binding is None or schema_findings:
        return schema_findings
    # Fresh digests make dependency checks trivially clean; the closure
    # question is import coverage.
    return analyze_binding_sources(binding, repo_root)


def _contained(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def pack_spec(spec: dict, out_dir: Path, repo_root: Path) -> tuple[dict, list[str]]:
    """Pack one spec into (binding_raw, errors). Reads owners, writes nothing."""
    errors: list[str] = []

    # Sources must exist and hash now; a pack that would emit a
    # missing-import binding is refused outright.
    sources_raw: list[dict] = []
    for source in spec["sources"]:
        path = source["path"]
        file_path = repo_root / path
        if not file_path.is_file():
            errors.append(f"declared source/import file is absent: {path}")
            continue
        sources_raw.append(
            {"path": path, "role": source["role"], "sha256": sha256_hex(file_path.read_bytes())}
        )
    if errors:
        return {}, errors

    # Outputs: read owner files, copy bytes, record digests.
    outputs_raw: list[dict] = []
    copied: list[tuple[Path, bytes]] = []
    for output in spec["outputs"]:
        origin = output["origin_path"]
        origin_path = repo_root / origin
        if not origin_path.is_file():
            errors.append(f"declared output file is absent: {origin}")
            continue
        content = origin_path.read_bytes()
        outputs_raw.append(
            {
                "path": origin,
                "sha256": sha256_hex(content),
                "bytes": len(content),
                "stored_as": output["stored_as"],
            }
        )
        copied.append((Path(output["stored_as"]), content))
    if errors:
        return {}, errors

    binding_raw = {
        "schema_version": SCHEMA_VERSION,
        "capsule_id": spec["capsule_id"],
        "title": spec["title"],
        "owner": spec["owner"],
        "sources": sources_raw,
        "toolchain": spec["toolchain"],
        "permitted_inputs": spec["permitted_inputs"],
        "model_transport": spec["model_transport"],
        "coverage_gaps": spec["coverage_gaps"],
        "outputs": outputs_raw,
    }
    binding, schema_findings = parse_binding(binding_raw)
    if binding is None or schema_findings:
        return {}, [f"packed binding failed schema: {f.code} {f.path}: {f.detail}" for f in schema_findings]

    # Pack gate: never emit a binding the checker would reject.
    closure = closure_findings(binding_raw, repo_root)
    if closure:
        return {}, [
            "spec is not import-closed; fix the spec before packing:"
        ] + [f"  {f.code}: {f.path}: {f.detail}" for f in closure]

    # Write phase — everything below is under out_dir, never an owner path.
    capsule_dir = out_dir / spec["capsule_id"]
    outputs_dir = capsule_dir / "outputs"
    if not _contained(capsule_dir, out_dir):
        errors.append("capsule directory escapes --out; refusing to write")
        return {}, errors
    for stored_name, _ in copied:
        target = outputs_dir / stored_name
        if not _contained(target, out_dir):
            errors.append(f"output target escapes --out: {target}")
            continue
        if _contained(target, repo_root) and target.resolve() in {
            (repo_root / o["origin_path"]).resolve() for o in spec["outputs"]
        }:
            errors.append(f"refusing to overwrite an owner artifact: {stored_name}")
    if errors:
        return {}, errors
    outputs_dir.mkdir(parents=True, exist_ok=True)
    for stored_name, content in copied:
        (outputs_dir / stored_name).write_bytes(content)
    binding_path = capsule_dir / "binding.json"
    binding_path.write_bytes(canonical_json_bytes(binding_raw) + b"\n")

    binding_raw_sorted = json.loads(canonical_json_bytes(binding_raw))
    return binding_raw_sorted, []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Pack existing owners' public study artifacts into capsules (read-only toward owners)."
    )
    parser.add_argument("--spec", type=Path, required=True, help="pack spec JSON file")
    parser.add_argument("--out", type=Path, required=True, help="capsule output directory")
    parser.add_argument(
        "--repo-root", type=Path, default=REPO_ROOT, help="repository root (default: derived)"
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    out_dir = args.out.resolve()
    if not repo_root.is_dir():
        print(f"error: repo root not found: {repo_root}", file=sys.stderr)
        return 2
    if not args.spec.is_file():
        print(f"error: spec file not found: {args.spec}", file=sys.stderr)
        return 2

    try:
        raw = json.loads(args.spec.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot load spec: {exc}", file=sys.stderr)
        return 2

    errors = spec_errors(raw)
    if errors:
        print("spec rejected:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 2

    running = platform.python_version()
    for spec in raw["specs"]:
        declared = spec["toolchain"]["language_version"]
        if declared != running:
            print(
                "error: toolchain mismatch: spec "
                f"{spec['capsule_id']!r} declares language_version {declared} but "
                f"this interpreter is {running}; a capsule must not claim a "
                "toolchain it was not packed with",
                file=sys.stderr,
            )
            return 2

    failed = False
    for spec in raw["specs"]:
        binding_raw, pack_errors = pack_spec(spec, out_dir, repo_root)
        capsule_id = spec["capsule_id"]
        if pack_errors:
            failed = True
            print(f"capsule {capsule_id}: PACK FAILED")
            for error in pack_errors:
                print(f"  {error}")
            continue
        sources_n = len(binding_raw["sources"])
        outputs_n = len(binding_raw["outputs"])
        print(f"capsule {capsule_id}: packed ({sources_n} sources, {outputs_n} outputs)")
        for output in binding_raw["outputs"]:
            print(
                f"  output {output['stored_as']}: sha256={output['sha256']} "
                f"bytes={output['bytes']} origin={output['path']}"
            )

    if failed:
        print("packing completed with failures", file=sys.stderr)
        return 1
    print(f"packed {len(raw['specs'])} capsule(s) under {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
