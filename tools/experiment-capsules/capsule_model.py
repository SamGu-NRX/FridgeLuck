#!/usr/bin/env python3
"""Capsule binding model for experiment-capsules.

A capsule binding is the machine-checkable statement of what produced a
food-study table: the exact source/import files it depends on (each with a
content digest), the toolchain, the permitted input references, the
model/transport settings that produced the outputs, the immutable output
digests, and the declared coverage gaps for imports that cannot be resolved
statically.

Design rules enforced here:

- Bindings are data. Parsing is strict: unknown fields, volatile fields
  (wall-clock time, git head) and credential-shaped fields ("api_key",
  "token", ...) are schema findings, never silently ignored.
- All paths are repo-root-relative POSIX paths. Absolute paths and ``..``
  traversal are rejected at the boundary.
- Digests are sha256 over raw file bytes.
- Volatile values (wall-clock time, HEAD commit sha) must stay out of
  regenerated table content so regeneration is digest-stable; see
  ``volatile_scan.py`` and the regeneration proof.

Trust limits (see README.md): digests bind content, not intent. The scheme
detects drift and inconsistent rewrites, but a *consistent* malicious
rewrite passes unless an external root of trust exists.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = "1"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
# Repo-relative POSIX path: no leading slash, no dot/dotdot segments.
_SEGMENT_OK = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._ -]*$")
_CAPSULE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")
# Credential-shaped field names are rejected wherever they appear.
_KEY_LIKE_RE = re.compile(
    r"api[_-]?key|token|secret|password|credential|authorization", re.IGNORECASE
)
# Bindings must not carry wall-clock or VCS values; these field names are
# rejected outright so bindings stay digest-stable.
_VOLATILE_KEYS = frozenset(
    {
        "generated_at",
        "timestamp",
        "created_at",
        "datetime",
        "date_generated",
        "run_at",
        "head",
        "head_sha",
        "commit",
        "commit_sha",
        "git_sha",
        "now",
        "today",
    }
)

SOURCE_ROLES = ("source", "import")
TRANSPORT_MODES = ("offline-deterministic", "model")


@dataclass(frozen=True)
class Finding:
    """One checker rejection (or schema error), classified by ``code``.

    Codes:
      schema                     binding is not a valid capsule binding
      missing-import             a declared source/import file is absent
      source-mismatch            file content differs from its declared digest
      self-referential-hash      an output embeds the digest declared for it
      missing-output             a declared output file is absent
      undeclared-import          a statically resolvable local import is not
                                 declared in ``sources``
      undeclared-dynamic-import  a dynamic import construct has no declared
                                 coverage gap (gaps are declared, never guessed)
      undeclared-dependency      a non-stdlib external import is not declared
                                 in ``toolchain.dependencies``
      source-syntax              a declared Python source does not parse
      missing-storage            a declared output has no stored_as name
    """

    code: str
    path: str
    detail: str

    def to_dict(self) -> dict:
        return {"code": self.code, "path": self.path, "detail": self.detail}


@dataclass(frozen=True)
class SourceRef:
    path: str
    role: str
    sha256: str


@dataclass(frozen=True)
class OutputRef:
    path: str
    sha256: str
    bytes: int
    stored_as: str | None


@dataclass(frozen=True)
class CoverageGap:
    file: str
    reason: str


@dataclass(frozen=True)
class Binding:
    capsule_id: str
    study_id: str | None
    title: str
    owner: str
    notes: str | None
    sources: tuple[SourceRef, ...]
    toolchain: dict
    permitted_inputs: tuple[str, ...]
    model_transport: dict
    coverage_gaps: tuple[CoverageGap, ...]
    outputs: tuple[OutputRef, ...]
    raw: dict

    def source_paths(self) -> set[str]:
        return {s.path for s in self.sources}

    def canonical_bytes(self) -> bytes:
        """Canonical serialization: sorted keys, compact separators.

        The capsule identity (binding digest) is sha256 over these bytes, so
        whitespace and key order in a committed binding.json never change
        identity.
        """
        return canonical_json_bytes(self.raw)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_hex(path.read_bytes())


def canonical_json_bytes(obj: dict) -> bytes:
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")


def _check_safe_path(value, where: str, findings: list[Finding]) -> bool:
    if not isinstance(value, str) or not value:
        findings.append(Finding("schema", where, "path must be a non-empty string"))
        return False
    if value.startswith("/") or "\\" in value:
        findings.append(Finding("schema", value, "path must be repo-relative POSIX"))
        return False
    segments = value.split("/")
    if any(seg in ("", ".", "..") for seg in segments):
        findings.append(Finding("schema", value, "path must not traverse ('..'/'.'/empty)"))
        return False
    if not all(_SEGMENT_OK.match(seg) for seg in segments):
        findings.append(Finding("schema", value, "path has unsupported characters"))
        return False
    return True


def _walk_forbidden_keys(node, where: str, findings: list[Finding]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str):
                if key.lower() in _VOLATILE_KEYS:
                    findings.append(
                        Finding(
                            "schema",
                            f"{where}.{key}",
                            "volatile field (wall-clock/HEAD) is not allowed in a binding",
                        )
                    )
                elif _KEY_LIKE_RE.search(key):
                    findings.append(
                        Finding(
                            "schema",
                            f"{where}.{key}",
                            "credential-shaped field is not allowed in a binding",
                        )
                    )
            _walk_forbidden_keys(value, f"{where}.{key}", findings)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            _walk_forbidden_keys(value, f"{where}[{i}]", findings)


def parse_binding(raw: dict) -> tuple[Binding | None, list[Finding]]:
    """Strictly parse a binding dict. Returns (binding|None, schema findings).

    On schema findings the caller must not run file-level checks: a binding
    that fails its own schema cannot be trusted to describe anything.
    """
    findings: list[Finding] = []
    if not isinstance(raw, dict):
        return None, [Finding("schema", "<root>", "binding must be a JSON object")]

    allowed = {
        "schema_version",
        "capsule_id",
        "study_id",
        "title",
        "owner",
        "notes",
        "sources",
        "toolchain",
        "permitted_inputs",
        "model_transport",
        "coverage_gaps",
        "outputs",
    }
    for key in sorted(raw):
        if key not in allowed:
            findings.append(Finding("schema", key, f"unknown field {key!r}"))
    _walk_forbidden_keys(raw, "binding", findings)
    if findings:
        return None, findings

    if raw.get("schema_version") != SCHEMA_VERSION:
        findings.append(
            Finding(
                "schema",
                "schema_version",
                f"must be {SCHEMA_VERSION!r}, got {raw.get('schema_version')!r}",
            )
        )
    capsule_id = raw.get("capsule_id")
    if not isinstance(capsule_id, str) or not _CAPSULE_ID_RE.match(capsule_id):
        findings.append(Finding("schema", "capsule_id", "must match ^[a-z0-9][a-z0-9-]{2,63}$"))
    study_id = raw.get("study_id")
    if study_id is not None and (
        not isinstance(study_id, str) or not _CAPSULE_ID_RE.match(study_id)
    ):
        findings.append(Finding("schema", "study_id", "must match ^[a-z0-9][a-z0-9-]{2,63}$"))
    if not isinstance(raw.get("title"), str) or not raw["title"]:
        findings.append(Finding("schema", "title", "must be a non-empty string"))
    if not isinstance(raw.get("owner"), str) or not raw["owner"]:
        findings.append(Finding("schema", "owner", "must be a non-empty string"))
    notes = raw.get("notes")
    if notes is not None and not isinstance(notes, str):
        findings.append(Finding("schema", "notes", "must be a string when present"))

    # --- sources ---
    sources: list[SourceRef] = []
    seen_paths: set[str] = set()
    raw_sources = raw.get("sources")
    if not isinstance(raw_sources, list) or not raw_sources:
        findings.append(Finding("schema", "sources", "must be a non-empty list"))
    else:
        for i, item in enumerate(raw_sources):
            where = f"sources[{i}]"
            if not isinstance(item, dict):
                findings.append(Finding("schema", where, "must be an object"))
                continue
            path = item.get("path")
            ok_path = _check_safe_path(path, f"{where}.path", findings)
            if ok_path and path in seen_paths:
                findings.append(Finding("schema", path, "duplicate source path"))
            if ok_path:
                seen_paths.add(path)
            role = item.get("role")
            if role not in SOURCE_ROLES:
                findings.append(
                    Finding("schema", where, f"role must be one of {SOURCE_ROLES}")
                )
            digest = item.get("sha256")
            if not isinstance(digest, str) or not _SHA256_RE.match(digest):
                findings.append(Finding("schema", where, "sha256 must be 64 lowercase hex"))
            if ok_path and role in SOURCE_ROLES and isinstance(digest, str):
                sources.append(SourceRef(path=path, role=role, sha256=digest))

    # --- toolchain ---
    toolchain = raw.get("toolchain")
    if not isinstance(toolchain, dict):
        findings.append(Finding("schema", "toolchain", "must be an object"))
        toolchain = {}
    else:
        if toolchain.get("language") != "python":
            findings.append(Finding("schema", "toolchain.language", "must be 'python'"))
        if not isinstance(toolchain.get("language_version"), str) or not toolchain[
            "language_version"
        ]:
            findings.append(
                Finding("schema", "toolchain.language_version", "must be a version string")
            )
        deps = toolchain.get("dependencies", [])
        if not isinstance(deps, list) or not all(isinstance(d, str) for d in deps):
            findings.append(
                Finding("schema", "toolchain.dependencies", "must be a list of names")
            )

    # --- permitted inputs ---
    permitted = raw.get("permitted_inputs")
    input_paths: list[str] = []
    if not isinstance(permitted, list) or not permitted:
        findings.append(Finding("schema", "permitted_inputs", "must be a non-empty list"))
    else:
        for i, path in enumerate(permitted):
            if _check_safe_path(path, f"permitted_inputs[{i}]", findings):
                input_paths.append(path)

    # --- model/transport ---
    transport = raw.get("model_transport")
    if not isinstance(transport, dict):
        findings.append(Finding("schema", "model_transport", "must be an object"))
    else:
        mode = transport.get("mode")
        if mode not in TRANSPORT_MODES:
            findings.append(
                Finding("schema", "model_transport.mode", f"must be one of {TRANSPORT_MODES}")
            )
        elif mode == "model":
            if not isinstance(transport.get("model"), str) or not transport["model"]:
                findings.append(
                    Finding("schema", "model_transport.model", "required when mode is 'model'")
                )
            if not isinstance(transport.get("transport"), str) or not transport["transport"]:
                findings.append(
                    Finding(
                        "schema",
                        "model_transport.transport",
                        "required when mode is 'model' (e.g. 'gemini-live-rest')",
                    )
                )
            for numeric in ("temperature", "seed"):
                if transport.get(numeric) is not None and not isinstance(
                    transport.get(numeric), (int, float)
                ):
                    findings.append(
                        Finding("schema", f"model_transport.{numeric}", "must be numeric or null")
                    )

    # --- coverage gaps ---
    gaps: list[CoverageGap] = []
    raw_gaps = raw.get("coverage_gaps", [])
    if not isinstance(raw_gaps, list):
        findings.append(Finding("schema", "coverage_gaps", "must be a list"))
    else:
        for i, item in enumerate(raw_gaps):
            where = f"coverage_gaps[{i}]"
            if not isinstance(item, dict):
                findings.append(Finding("schema", where, "must be an object"))
                continue
            gap_file = item.get("file")
            reason = item.get("reason")
            if _check_safe_path(gap_file, f"{where}.file", findings):
                if gap_file not in seen_paths:
                    findings.append(
                        Finding(
                            "schema",
                            gap_file,
                            "coverage gap names a file that is not a declared source",
                        )
                    )
                else:
                    gaps.append(CoverageGap(file=gap_file, reason=str(reason)))
            if not isinstance(reason, str) or not reason:
                findings.append(Finding("schema", f"{where}.reason", "must be a non-empty string"))

    # --- outputs ---
    outputs: list[OutputRef] = []
    raw_outputs = raw.get("outputs")
    if not isinstance(raw_outputs, list) or not raw_outputs:
        findings.append(Finding("schema", "outputs", "must be a non-empty list"))
    else:
        seen_stored: set[str] = set()
        for i, item in enumerate(raw_outputs):
            where = f"outputs[{i}]"
            if not isinstance(item, dict):
                findings.append(Finding("schema", where, "must be an object"))
                continue
            path = item.get("path")
            if _check_safe_path(path, f"{where}.path", findings) and path in seen_paths:
                findings.append(Finding("schema", path, "duplicate output path"))
            digest = item.get("sha256")
            if not isinstance(digest, str) or not _SHA256_RE.match(digest):
                findings.append(Finding("schema", where, "sha256 must be 64 lowercase hex"))
            size = item.get("bytes")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                findings.append(Finding("schema", where, "bytes must be a non-negative integer"))
            stored_as = item.get("stored_as")
            if stored_as is not None:
                if (
                    not isinstance(stored_as, str)
                    or "/" in stored_as
                    or stored_as in (".", "..")
                    or not stored_as
                ):
                    findings.append(
                        Finding("schema", f"{where}.stored_as", "must be a bare file name")
                    )
                elif stored_as in seen_stored:
                    findings.append(Finding("schema", f"{where}.stored_as", "duplicate stored name"))
                else:
                    seen_stored.add(stored_as)
            if isinstance(path, str) and isinstance(digest, str) and isinstance(size, int):
                outputs.append(
                    OutputRef(path=path, sha256=digest, bytes=size, stored_as=stored_as)
                )

    if findings:
        return None, findings

    binding = Binding(
        capsule_id=capsule_id,
        study_id=study_id,
        title=raw["title"],
        owner=raw["owner"],
        notes=notes,
        sources=tuple(sources),
        toolchain=toolchain,
        permitted_inputs=tuple(input_paths),
        model_transport=transport,
        coverage_gaps=tuple(gaps),
        outputs=tuple(outputs),
        raw=raw,
    )
    return binding, []


def load_binding_file(path: Path) -> tuple[dict | None, list[Finding]]:
    """Load raw binding JSON; malformed JSON becomes a schema finding."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, [Finding("schema", str(path), f"cannot load binding: {exc}")]
    return raw, []
