#!/usr/bin/env python3
"""Import rules for the overhaul Swift packages (FridgeLuckCore and later
capability packages under packages/).

Enforces the two contracts Package.swift states in its header comment:

1. FLDomain imports Foundation only — the domain stays dependency-free so
   every other layer can build on it.
2. No target imports UIKit, SwiftUI or AppKit — UI belongs to the app
   targets, never to the portable logic.

plus the dependency-direction rule the review asked for:

3. Layer rank is FLDomain (0) < FLPersistence (1) < capability targets (2).
   A target may import lower-ranked same-repo packages and the declared
   third-party set (GRDB); it may never import a higher-ranked one.

Fail closed: an import that is not explicitly allowed here is a violation —
each new dependency must be declared by the owning part, never silently
absorbed. Adding an entry below is a reviewed decision, which is the point.

Scope: Sources/ of every package under packages/ that has a Package.swift.
Test targets are out of scope (they import XCTest by design); layering is a
property of shipped targets. .build/ and .git/ are skipped, so vendored or
checked-out third-party sources inside a build directory cannot pollute the
scan.

Limitation: imports are matched after stripping `//` line comments; a module
name quoted inside a string literal at the start of a line would produce a
false positive. No such pattern exists in this repo.

Usage:
    python3 scripts/overhaul-checks/import_rules.py            # scan repo
    python3 scripts/overhaul-checks/import_rules.py <repo-root>
"""

import re
import sys
from pathlib import Path

UI_FRAMEWORKS = {"SwiftUI", "UIKit", "AppKit"}
THIRD_PARTY = {"GRDB"}

# Same-repo packages by layer rank: lower rank may be imported by higher.
PACKAGE_LAYERS = (
    ("FLDomain", 0),
    ("FLPersistence", 1),
)
PACKAGE_LAYER_NAMES = {name for name, _ in PACKAGE_LAYERS}
CAPABILITY_RANK = 2

# Per-target allowed imports. FLDomain's entry is the whole contract (stdlib
# only); FLPersistence adds the store and the domain; every other target is a
# capability target and gets the capability allowlist.
FLDOMAIN_ALLOWED = {"Foundation"}
FLPERSISTENCE_ALLOWED = {"Foundation", "FLDomain"} | THIRD_PARTY
CAPABILITY_ALLOWED = {"Foundation", "FLDomain", "FLPersistence"} | THIRD_PARTY

IMPORT_RE = re.compile(r"^\s*(?:@\S+\s+)*import\s+([A-Za-z_][A-Za-z0-9_.]*)")

VIOLATION_TEMPLATE = "{file}:{line}: import '{name}' is not allowed in target '{target}' ({reason})"


def target_allowed_imports(target: str) -> set:
    if target == "FLDomain":
        return FLDOMAIN_ALLOWED
    if target == "FLPersistence":
        return FLPERSISTENCE_ALLOWED
    return set(CAPABILITY_ALLOWED)


def rank_of(target: str) -> int:
    """The layer rank of a target: the target name IS the layer unit."""
    for name, rank in PACKAGE_LAYERS:
        if name == target:
            return rank
    return CAPABILITY_RANK


def strip_line_comment(line: str) -> str:
    # Good enough for import scanning: strings containing '//' before a real
    # import on the same line do not occur in this repo.
    return line.split("//", 1)[0]


def imports_in_file(path: Path):
    """Yield (line_number, module) for each import in a Swift file."""
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError) as exc:
        yield (1, f"<unreadable file: {exc}>")
        return
    for number, raw_line in enumerate(text.splitlines(), start=1):
        match = IMPORT_RE.match(strip_line_comment(raw_line))
        if match:
            yield (number, match.group(1))


def swift_sources_under(directory: Path):
    for path in sorted(directory.rglob("*.swift")):
        parts = path.relative_to(directory).parts
        if ".build" in parts or ".git" in parts:
            continue
        yield path


def packages_under(repo_root: Path):
    packages_dir = repo_root / "packages"
    if not packages_dir.is_dir():
        return []
    result = []
    for package_dir in sorted(packages_dir.iterdir()):
        if (package_dir / "Package.swift").is_file():
            result.append(package_dir)
    return result


def reasons_for(target: str, module: str) -> list:
    """Human-readable reasons an import is disallowed (nonempty = not allowed)."""
    if module in UI_FRAMEWORKS:
        return ["UI framework: no overhaul target may import UIKit, SwiftUI or AppKit"]
    if module in PACKAGE_LAYER_NAMES and rank_of(module) > rank_of(target):
        return [
            f"dependency direction: '{module}' (rank {rank_of(module)}) outranks "
            f"'{target}' (rank {rank_of(target)})"
        ]
    return [f"not in '{target}' allowed imports; declare new dependencies here first"]


def check_target(target: str, sources: Path):
    allowed = target_allowed_imports(target)
    violations = []
    for path in swift_sources_under(sources):
        for line_number, module in imports_in_file(path):
            root_module = module.split(".")[0]
            if root_module in allowed:
                continue
            reasons = reasons_for(target, root_module)
            violations.append(
                VIOLATION_TEMPLATE.format(
                    file=path, line=line_number, name=root_module,
                    target=target, reason=reasons[0],
                )
            )
    return violations


def scan(repo_root: Path):
    violations = []
    stats = {"packages": 0, "targets": 0, "files": 0}
    for package_dir in packages_under(repo_root):
        sources = package_dir / "Sources"
        if not sources.is_dir():
            continue
        stats["packages"] += 1
        for target_dir in sorted(sources.iterdir()):
            if not target_dir.is_dir():
                continue
            stats["targets"] += 1
            violations.extend(check_target(target_dir.name, target_dir))
            stats["files"] += sum(1 for _ in swift_sources_under(target_dir))
    return violations, stats


def main(argv):
    repo_root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parents[2]
    violations, stats = scan(repo_root)
    if violations:
        for violation in violations:
            print(violation)
        print(f"import rules: FAILED ({len(violations)} violation(s))")
        return 1
    print(
        f"import rules: OK — {stats['files']} Swift files across "
        f"{stats['targets']} targets in {stats['packages']} package(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
