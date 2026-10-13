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
from path_trust import UntrustedPathError, read_repo_file


@dataclass(frozen=True)
class ImportObservation:
    module_head: str  # top-level package name (".<level>:<module>" for relative)
    kind: str  # "static" | "dynamic"
    lineno: int
    detail: str
    names: tuple[str, ...] = ()  # imported aliases (for relative resolution)
    module_full: str = ""  # full dotted module (absolute imports, dynamic literals)


def scan_source(text: str, filename: str) -> tuple[list[ImportObservation], str | None]:
    """Return (observations, syntax_error). Syntax errors never raise here.

    Two passes: first collect importlib alias bindings (R5), then collect
    import observations with FULL dotted module names (R4).
    """
    try:
        tree = ast.parse(text, filename=filename)
    except SyntaxError as exc:
        return [], f"{type(exc).__name__}: {exc.msg} (line {exc.lineno})"

    # Pass 1 — importlib alias bindings (R5):
    #   `import importlib` / `import importlib as il`  -> bound names
    #   `from importlib import import_module [as im]`  -> callable names
    importlib_aliases: set[str] = set()
    import_module_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "importlib":
                    importlib_aliases.add(alias.asname or "importlib")
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module == "importlib":
                for alias in node.names:
                    if alias.name in ("import_module", "reload"):
                        import_module_names.add(alias.asname or alias.name)

    observations: list[ImportObservation] = []

    def add(
        head: str,
        module_full: str,
        kind: str,
        lineno: int,
        detail: str,
        names: tuple[str, ...] = (),
    ) -> None:
        observations.append(
            ImportObservation(
                module_head=head,
                module_full=module_full,
                kind=kind,
                lineno=lineno,
                detail=detail,
                names=names,
            )
        )

    # Pass 2 — the actual imports and dynamic-import call sites.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                # `import pkg.child` records the full dotted name so the
                # closure check resolves pkg/child.py, not just pkg/.
                add(
                    alias.name.split(".")[0],
                    alias.name,
                    "static",
                    node.lineno,
                    alias.name,
                )
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module:
                names = tuple(alias.name for alias in node.names)
                # `from pkg import child` keeps the module and the names:
                # when pkg/child.py exists on disk it is part of the closure
                # even if pkg/__init__.py re-exports the name.
                add(
                    node.module.split(".")[0],
                    node.module,
                    "static",
                    node.lineno,
                    f"{node.module} (from-names: {list(names)})" if names else node.module,
                    names=names,
                )
            elif node.level > 0:
                names = tuple(alias.name for alias in node.names)
                add(
                    f".{node.level}:{node.module or ''}",
                    "",
                    "static",
                    node.lineno,
                    f"relative level={node.level} module={node.module or ''} "
                    f"names={list(names)}",
                    names=names,
                )
        elif isinstance(node, ast.Call):
            target = _dynamic_import_target(node, importlib_aliases, import_module_names)
            if target is not None:
                arg = target[1]
                if (
                    arg is not None
                    and isinstance(arg, ast.Constant)
                    and isinstance(arg.value, str)
                ):
                    # A literal dynamic import is statically knowable.
                    literal = arg.value
                    add(
                        literal.split(".")[0],
                        literal,
                        "static",
                        node.lineno,
                        f"dynamic-literal {literal}",
                    )
                else:
                    add("<dynamic>", "", "dynamic", node.lineno, ast.unparse(node)[:120])
    return observations, None


def _dynamic_import_target(
    node: ast.Call,
    importlib_aliases: set[str] | None = None,
    import_module_names: set[str] | None = None,
):
    """Return (func_node, arg_node) for dynamic-import calls, or None.

    Recognized forms (R5):
    - ``importlib.import_module(...)`` / ``importlib.reload(...)``
    - ``il.import_module(...)`` after ``import importlib as il``
    - bare ``import_module(...)`` / ``reload(...)`` after
      ``from importlib import import_module``
    - builtin ``__import__(...)``
    - any other ``<recv>.import_module(...)`` — unresolvable receiver
      (arg_node ``None``: recorded as a dynamic coverage gap)
    """
    aliases = {"importlib"} | (importlib_aliases or set())
    from_names = import_module_names if import_module_names is not None else set()
    if not node.args:
        return None
    func = node.func
    if (
        isinstance(func, ast.Attribute)
        and func.attr in ("import_module", "reload")
        and isinstance(func.value, ast.Name)
        and func.value.id in aliases
    ):
        return func, node.args[0]
    if isinstance(func, ast.Attribute) and func.attr == "import_module":
        # Unknown receiver (assignment aliasing like `il = importlib`,
        # attribute chains): cannot be resolved statically, so it stays a
        # declared coverage gap — never silently ignored (R5).
        return func, None
    if isinstance(func, ast.Name) and (func.id in from_names or func.id == "__import__"):
        return func, node.args[0]
    return None


def _absolute_candidates(
    module_full: str, names: tuple[str, ...], roots: list[Path]
) -> list[Path]:
    """Candidate files importing ``module_full`` could load (R4).

    Every package prefix is included: importing ``pkg.child.grandchild``
    executes ``pkg/__init__.py``, ``pkg/child/__init__.py`` and
    ``pkg/child/grandchild.py`` — a declared ``pkg/__init__.py`` alone
    never closes ``pkg.child``. For ``from pkg import child`` module
    forms, ``pkg/child.py`` is a candidate whenever it exists on disk.
    """
    parts = module_full.split(".") if module_full else []
    candidates: list[Path] = []
    for depth in range(1, len(parts) + 1):
        base = "/".join(parts[:depth])
        for root in roots:
            for candidate in (root / f"{base}.py", root / base / "__init__.py"):
                if candidate not in candidates:
                    candidates.append(candidate)
    if parts:
        mod_base = "/".join(parts)
        for root in roots:
            for name in names:
                candidate = root / mod_base / f"{name}.py"
                if candidate not in candidates:
                    candidates.append(candidate)
    return candidates


def _relative_candidates(
    module_field: str, level: int, names: tuple[str, ...], source_path: Path
) -> list[Path]:
    """Candidate files a relative import could load (R4: dotted, recursive).

    ``from . import x``        -> <dir>/x.py, <dir>/x/__init__.py
    ``from .mod import y``     -> <dir>/mod.py, <dir>/mod/__init__.py,
                                  <dir>/mod/y.py
    ``from .pkg.child import x`` -> <dir>/pkg/__init__.py, <dir>/pkg/child.py,
                                  <dir>/pkg/child/__init__.py,
                                  <dir>/pkg/child/x.py
    """
    if level - 1 > len(source_path.parents):
        return []
    base_dir = source_path.parents[level - 1] if level > 1 else source_path.parent
    candidates: list[Path] = []
    if module_field:
        parts = module_field.split(".")
        for depth in range(1, len(parts) + 1):
            base = base_dir.joinpath(*parts[:depth])
            candidates.append(base.with_name(base.name + ".py"))
            candidates.append(base / "__init__.py")
        mod = base_dir.joinpath(*parts)
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
        # Allowlist read (R1): only declared source paths may be opened,
        # and only after symlink/containment validation passes.
        try:
            source_text = read_repo_file(
                repo_root, source.path, declared
            ).decode("utf-8")
        except FileNotFoundError:
            continue  # absence is reported as missing-import elsewhere
        except UntrustedPathError as exc:
            findings.append(
                Finding(
                    "source-path-untrusted",
                    source.path,
                    f"declared source path rejected before read: {exc}",
                )
            )
            continue
        observations, syntax_error = scan_source(source_text, source.path)
        if syntax_error is not None:
            findings.append(
                Finding(
                    "source-syntax",
                    source.path,
                    f"declared source does not parse: {syntax_error}",
                )
            )
            continue

        file_path = repo_root / source.path
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
                existing_rels = {
                    r for r in (rel(c) for c in candidates if c.is_file()) if r
                }
                # Every on-disk candidate must be declared: with dotted
                # modules the intermediate package __init__ files are part
                # of the closure too (R4).
                undeclared_rels = sorted(existing_rels - declared)
                if undeclared_rels:
                    findings.append(
                        Finding(
                            "undeclared-import",
                            f"{source.path}:{obs.lineno}",
                            f"relative import resolves to undeclared file(s): "
                            + ", ".join(undeclared_rels),
                        )
                    )
                # No existing candidate: an import that would fail at runtime;
                # nothing undeclared exists, so no coverage finding.
                continue

            if obs.module_head in sys.stdlib_module_names:
                continue

            candidates = _absolute_candidates(
                obs.module_full or obs.module_head, obs.names, roots
            )
            candidate_rels = {rel(c) for c in candidates}
            candidate_rels.discard(None)
            existing_rels = {r for r in (rel(c) for c in candidates if c.is_file()) if r}
            # Every on-disk candidate must be declared (R4): a declared
            # pkg/__init__.py does not close pkg.child when pkg/child.py
            # exists undeclared. Declared-but-absent candidates are left to
            # the missing-import checker.
            undeclared_rels = sorted(existing_rels - declared)
            if undeclared_rels:
                findings.append(
                    Finding(
                        "undeclared-import",
                        f"{source.path}:{obs.lineno}",
                        f"import {obs.detail!r} resolves to undeclared file(s): "
                        + ", ".join(undeclared_rels),
                    )
                )
                continue
            if existing_rels or candidate_rels & declared:
                # On-disk candidates all declared, or a declared candidate
                # currently absent (missing-import covers it).
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
