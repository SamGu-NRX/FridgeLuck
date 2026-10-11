#!/usr/bin/env python3
"""Static import scanning for declared capsule sources.

Answers one question per declared Python source: which modules does it
pull in, and is every pull either (a) the standard library, (b) declared
in the binding's ``sources`` (role source or import), (c) declared in
``toolchain.dependencies``, or (d) a dynamic import construct covered by a
declared coverage gap?

A module head counts as *declared* when a candidate file for it
(``<root>/<module>.py`` or ``<root>/<module>/__init__.py``, for some
resolution root) names a declared source path — even if that file is
currently absent on disk. Absence is the contract checker's
``missing-import`` finding, not an import-coverage hole.

Dynamic imports (``importlib.import_module`` / ``__import__`` with a
non-literal target) cannot be resolved statically. They are never guessed
as closed: a source that contains one must have a matching coverage-gap
entry in the binding, or the checker rejects it.
"""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from capsule_model import Binding, Finding


@dataclass(frozen=True)
class ImportObservation:
    module_head: str  # top-level package name (".<level>:<module>" for relative)
    kind: str  # "static" | "dynamic"
    lineno: int
    detail: str
    names: tuple[str, ...] = ()  # imported aliases (for relative resolution)


def scan_source(text: str, filename: str) -> tuple[list[ImportObservation], str | None]:
    """Return (observations, syntax_error). Syntax errors never raise here."""
    try:
        tree = ast.parse(text, filename=filename)
    except SyntaxError as exc:
        return [], f"{type(exc).__name__}: {exc.msg} (line {exc.lineno})"

    observations: list[ImportObservation] = []

    def add(head: str, kind: str, lineno: int, detail: str, names: tuple[str, ...] = ()) -> None:
        observations.append(
            ImportObservation(module_head=head, kind=kind, lineno=lineno, detail=detail, names=names)
        )

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                add(alias.name.split(".")[0], "static", node.lineno, alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module:
                add(node.module.split(".")[0], "static", node.lineno, node.module)
            elif node.level > 0:
                names = tuple(alias.name for alias in node.names)
                add(
                    f".{node.level}:{node.module or ''}",
                    "static",
                    node.lineno,
                    f"relative level={node.level} module={node.module or ''} "
                    f"names={list(names)}",
                    names=names,
                )
        elif isinstance(node, ast.Call):
            target = _dynamic_import_target(node)
            if target is not None:
                arg = target[1]
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    # A literal dynamic import is statically knowable.
                    literal = arg.value
                    add(literal.split(".")[0], "static", node.lineno, f"dynamic-literal {literal}")
                else:
                    add("<dynamic>", "dynamic", node.lineno, ast.unparse(node)[:120])
    return observations, None


def _dynamic_import_target(node: ast.Call):
    """Return (func_node, arg_node) for importlib.import_module/__import__ calls."""
    func = node.func
    is_import_module = (
        isinstance(func, ast.Attribute)
        and func.attr in ("import_module", "reload")
        and isinstance(func.value, ast.Name)
        and func.value.id == "importlib"
    )
    is_builtin = isinstance(func, ast.Name) and func.id == "__import__"
    if (is_import_module or is_builtin) and node.args:
        return func, node.args[0]
    return None


def _absolute_candidates(module_head: str, roots: list[Path]) -> list[Path]:
    base = module_head.replace(".", "/")
    found: list[Path] = []
    for root in roots:
        for candidate in (root / f"{base}.py", root / base / "__init__.py"):
            if candidate not in found:
                found.append(candidate)
    return found


def _relative_candidates(
    module_field: str, level: int, names: tuple[str, ...], source_path: Path
) -> list[Path]:
    """Candidate files a relative import could load.

    ``from . import x``      -> <dir>/x.py, <dir>/x/__init__.py
    ``from .mod import y``   -> <dir>/mod.py, <dir>/mod/__init__.py,
                                <dir>/mod/y.py
    """
    if level - 1 > len(source_path.parents):
        return []
    base_dir = source_path.parents[level - 1] if level > 1 else source_path.parent
    candidates: list[Path] = []
    if module_field:
        mod = base_dir / module_field.replace(".", "/")
        candidates += [mod.with_name(mod.name + ".py"), mod / "__init__.py"]
        for name in names:
            candidates.append(mod / f"{name}.py")
    else:
        for name in names:
            target = base_dir / name
            candidates += [target.with_name(target.name + ".py"), target / "__init__.py"]
    return candidates


def analyze_binding_sources(binding: Binding, repo_root: Path) -> list[Finding]:
    """Check every declared .py source's imports against the binding."""
    findings: list[Finding] = []
    declared = binding.source_paths()

    # Resolution roots: every ancestor directory of every declared source.
    roots: list[Path] = []
    for path in declared:
        for parent in (repo_root / path).parents:
            if parent not in roots:
                roots.append(parent)
    # Nearest root first: deterministic resolution under shadowing.
    roots.sort(key=lambda p: (len(p.parts), str(p)), reverse=True)

    dependencies = set(binding.toolchain.get("dependencies", []) or [])
    gap_files = {gap.file for gap in binding.coverage_gaps}

    def rel(path: Path) -> str | None:
        """Repo-relative POSIX string, or None when outside the repo root."""
        try:
            return str(path.resolve().relative_to(repo_root.resolve()))
        except ValueError:
            return None

    for source in binding.sources:
        if not source.path.endswith(".py"):
            continue
        file_path = repo_root / source.path
        if not file_path.is_file():
            continue  # absence is reported as missing-import elsewhere
        observations, syntax_error = scan_source(
            file_path.read_text(encoding="utf-8"), source.path
        )
        if syntax_error is not None:
            findings.append(
                Finding(
                    "source-syntax",
                    source.path,
                    f"declared source does not parse: {syntax_error}",
                )
            )
            continue

        for obs in observations:
            if obs.kind == "dynamic":
                if source.path not in gap_files:
                    findings.append(
                        Finding(
                            "undeclared-dynamic-import",
                            f"{source.path}:{obs.lineno}",
                            "dynamic import construct has no declared coverage gap: "
                            f"{obs.detail}",
                        )
                    )
                continue

            if obs.module_head.startswith("."):
                level_str, module_field = obs.module_head.split(":", 1)
                candidates = _relative_candidates(
                    module_field, int(level_str[1:]), obs.names, file_path
                )
                existing_rels = {rel(c) for c in candidates if c.is_file()}
                existing_rels.discard(None)
                if existing_rels and existing_rels.isdisjoint(declared):
                    findings.append(
                        Finding(
                            "undeclared-import",
                            f"{source.path}:{obs.lineno}",
                            f"relative import resolves to undeclared file(s): "
                            + ", ".join(sorted(existing_rels)),
                        )
                    )
                # No existing candidate: an import that would fail at runtime;
                # nothing undeclared exists, so no coverage finding.
                continue

            if obs.module_head in sys.stdlib_module_names:
                continue

            candidates = _absolute_candidates(obs.module_head, roots)
            candidate_rels = {rel(c) for c in candidates}
            candidate_rels.discard(None)
            # Declared wins even when the file is absent on disk: the
            # checker already reports that as missing-import.
            if candidate_rels & declared:
                continue
            existing = [c for c in candidates if c.is_file()]
            if existing:
                findings.append(
                    Finding(
                        "undeclared-import",
                        f"{source.path}:{obs.lineno}",
                        f"import {obs.detail!r} resolves to undeclared file(s): "
                        + ", ".join(sorted({rel(c) for c in existing})),
                    )
                )
                continue
            if obs.module_head not in dependencies:
                findings.append(
                    Finding(
                        "undeclared-dependency",
                        f"{source.path}:{obs.lineno}",
                        f"external import {obs.detail!r} is not declared in "
                        "toolchain.dependencies",
                    )
                )
    return findings
