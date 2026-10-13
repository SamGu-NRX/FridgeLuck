#!/usr/bin/env python3
"""Path trust boundary for experiment-capsules (read side) and write guards.

Every file the capsule tools touch — sources, outputs, bindings, stored
copies — passes through here BEFORE any open. Safety is structural:

- **Read side (R1).** A read is allowed only when the exact repo-relative
  path is on the operation's explicit allowlist (the public artifact/source
  paths the validated spec or binding declares), no path component is a
  symlink, the resolved path stays inside the permitted root, and the
  final entry is not itself a symlink. Anything else — private or
  unapproved paths, ``..``-escapes, links pointing outside — is rejected
  before the file is opened. Validation failure is an
  ``UntrustedPathError`` carrying the reason; the caller turns it into
  tool errors without reading a single byte of the rejected file.

  The schema's credential-shaped-key scan (``capsule_model``) stays an
  **advisory signal only** — key shape says nothing about file bytes and
  is never the safety mechanism. The allowlist plus the symlink and
  containment checks here are the mechanism.

- **Write side (R2).** Every write goes through :func:`safe_write_bytes`:
  refuse a pre-existing symlink at the destination, refuse a symlinked
  parent component, refuse destinations that resolve outside the
  permitted output root, then write a fresh temp file inside the same
  permitted directory and ``os.replace`` it into place. Nothing is
  deleted through links, nothing is overwritten through links (a symlink
  destination is refused, not followed), and owner artifact paths are
  outside the permitted root by construction.
"""

from __future__ import annotations

import os
from pathlib import Path


class UntrustedPathError(ValueError):
    """A path failed the allowlist/symlink/containment boundary pre-open."""


def _reject_symlink_components(base: Path, relpath: str) -> Path:
    """Walk base/relpath components; reject any symlink; return the final Path.

    Existing directory components are checked with ``lstat`` semantics
    (``is_symlink``), so a link planted anywhere between the root and the
    file is rejected before the file is opened. A missing component is
    left to the caller's existence handling.
    """
    if not relpath:
        raise UntrustedPathError("empty path")
    parts = Path(relpath).parts
    if parts and Path(parts[0]).is_absolute():
        raise UntrustedPathError(f"absolute paths are not permitted: {relpath}")
    final = base
    for part in parts:
        final = final / part
        if final.is_symlink():
            raise UntrustedPathError(f"symlinked component in path: {final}")
    return final


def _require_inside(resolved: Path, root: Path, what: str) -> None:
    if not resolved.is_relative_to(root.resolve()):
        raise UntrustedPathError(f"{what} resolves outside the permitted root {root}: {resolved}")


def read_repo_file(
    repo_root: Path, relpath: str, allowed: set[str] | frozenset[str]
) -> bytes:
    """Validate ``repo_root/relpath`` against the explicit allowlist, then read.

    Rejects, before any open: non-string/empty/absolute/backslash paths,
    ``..``/``.``/empty segments, paths not on ``allowed`` (private or
    unapproved), symlinked components, symlink final entries, and resolved
    paths outside ``repo_root``.
    """
    if not isinstance(relpath, str) or not relpath:
        raise UntrustedPathError(f"path must be a non-empty string, got {relpath!r}")
    if relpath.startswith("/") or "\\" in relpath:
        raise UntrustedPathError(f"path must be repo-relative POSIX: {relpath!r}")
    if any(seg in ("", ".", "..") for seg in relpath.split("/")):
        raise UntrustedPathError(f"path must not traverse ('..'/'.'/empty): {relpath!r}")
    if relpath not in allowed:
        raise UntrustedPathError(
            f"path is not on the operation's allowlist of permitted public "
            f"artifact/source paths: {relpath!r}"
        )
    final = _reject_symlink_components(repo_root, relpath)
    if not final.is_file():
        raise FileNotFoundError(f"file is absent: {relpath}")
    _require_inside(final.resolve(), repo_root, "file")
    return final.read_bytes()


def read_capsule_file(root: Path, relpath: str) -> bytes:
    """Validate and read a file inside the capsules/scratch zone (no repo allowlist).

    Same symlink/containment rules as :func:`read_repo_file`; membership is
    enforced by the caller, which only constructs declared capsule paths
    (``binding.json``, ``outputs/<stored_as>``).
    """
    if not isinstance(relpath, str) or not relpath or relpath.startswith("/"):
        raise UntrustedPathError(f"invalid capsule path: {relpath!r}")
    if any(seg in ("", ".", "..") for seg in relpath.split("/")):
        raise UntrustedPathError(f"path must not traverse ('..'/'.'/empty): {relpath!r}")
    final = _reject_symlink_components(root, relpath)
    if not final.is_file():
        raise FileNotFoundError(f"file is absent: {relpath}")
    _require_inside(final.resolve(), root, "file")
    return final.read_bytes()


def safe_write_bytes(dest: Path, content: bytes, permitted_root: Path) -> None:
    """Guarded write: never follow, delete, or overwrite through links (R2).

    Refuses (before touching anything):

    - a pre-existing symlink at the destination,
    - a symlinked component anywhere between ``permitted_root`` and the
      destination,
    - a destination that resolves outside ``permitted_root``.

    Otherwise writes a fresh temp file inside the destination's own
    directory (same permitted output dir) and atomically ``os.replace``s
    it over a *regular* file destination — repacking stays digest-stable
    without ever writing through a link.
    """
    if dest.is_symlink():
        raise UntrustedPathError(f"write destination is a symlink (refusing): {dest}")
    dest = dest.resolve()
    permitted_root = permitted_root.resolve()
    try:
        rel = dest.relative_to(permitted_root)
    except ValueError as exc:
        # A symlinked parent resolved somewhere else: refuse, never follow.
        raise UntrustedPathError(
            f"write destination resolves outside the permitted root {permitted_root}: {dest}"
        ) from exc
    final = _reject_symlink_components(permitted_root, str(rel))
    _require_inside(final.resolve(), permitted_root, "write destination")
    parent = final.parent
    parent.mkdir(parents=True, exist_ok=True)
    if parent.is_symlink():
        raise UntrustedPathError(f"write parent is a symlink (refusing): {parent}")

    tmp_name = f".{final.name}.tmp-{os.getpid()}"
    tmp_path = parent / tmp_name
    try:
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
        os.replace(tmp_path, final)
    finally:
        # After a successful replace the temp path is gone; after a failure
        # it must not linger in the permitted output directory.
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def validate_descriptor_path(path: Path, kind: str) -> Path:
    """Validate a CLI-named descriptor (spec file, binding file, capsules dir).

    These paths *define* the allowlist, so they get the symlink-component
    and existence checks but no allowlist membership test.
    """
    if not path.exists():
        raise UntrustedPathError(f"{kind} does not exist: {path}")
    base = path.parent if path.is_file() else path
    if path.is_file():
        _reject_symlink_components(base, path.name)
    else:
        _reject_symlink_components(path.parent, path.name)
    return path
