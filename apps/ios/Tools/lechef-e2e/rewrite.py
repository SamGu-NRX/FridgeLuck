#!/usr/bin/env python3
"""Documented rewrites applied to the pinned phone sources in the e2e walk.

The copies stay byte-identical to the real sources except for the platform
transforms below (same spirit as community-check's @testable import rewrite):

1. Every copy: `import FLFeatureLogic` is dropped — the pinned FeatureLogic
   sources join the walk target directly, so the module reference is wrong.
2. CookProposalWire: `import CryptoKit` becomes a canImport guard — Linux
   toolchains have no CryptoKit; swift-crypto's Crypto module is the same API
   (SHA256), and the package depends on it.
3. GeminiLiveSessionClient: a FoundationNetworking guard is inserted (URLSession
   lives there on Linux), and `sendSessionContext`/`sessionContextPayload` are
   removed — the only references to LiveAssistantRecipeContext, which the walk
   does not pin (the walk sends bounded snapshots instead). Everything else,
   including the proposal/receipt paths under test, is untouched.
4. LiveProposalCoordinator: `@Published` is dropped — Combine has no Linux
   build; the walk reads `cards` directly and needs no observation.

Anything else that stops compiling means the real source changed in a way this
file does not anticipate: extend THIS file with a documented transform (or pin
more of the phone) rather than editing the copies by hand.
"""

import re
import sys
from pathlib import Path


def drop_import(source: str, module: str) -> str:
    return re.sub(rf"^import {module}\n", "", source, flags=re.MULTILINE)


def guard_import(source: str, module: str, fallback: str) -> str:
    replacement = f"#if canImport({module})\nimport {module}\n#else\nimport {fallback}\n#endif"
    return re.sub(rf"^import {module}$", replacement, source, count=1, flags=re.MULTILINE)


def add_networking_guard(source: str) -> str:
    # After the last top-level import in the file.
    matches = list(re.finditer(r"^import .+\n", source, flags=re.MULTILINE))
    last = matches[-1]
    guard = "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n"
    return source[: last.end()] + guard + source[last.end() :]


def remove_declaration(source: str, signature_prefix: str) -> str:
    """Removes a top-level declaration that starts with the given prefix,
    brace-matched so the rest of the file is untouched."""
    start = source.find(signature_prefix)
    if start == -1:
        raise SystemExit(f"rewrite: declaration not found: {signature_prefix!r}")
    # The declaration may carry doc comments above it — strip them too.
    head = source[:start]
    comment_end = 0
    for line in reversed(head.splitlines(keepends=True)):
        if line.startswith("///") or line.startswith("//") or line.strip() == "":
            comment_end += len(line)
        else:
            break
    decl_start = start - comment_end
    open_brace = source.index("{", start)
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                # Consume the trailing newline.
                while end < len(source) and source[end] == "\n":
                    end += 1
                return source[:decl_start] + source[end:]
    raise SystemExit(f"rewrite: unbalanced braces in {signature_prefix!r}")


def main() -> None:
    out = Path(sys.argv[1])

    for path in sorted(out.glob("*.swift")):
        text = path.read_text()
        if "FLFeatureLogic" in text:
            text = drop_import(text, "FLFeatureLogic")

        if path.name == "CookProposalWire.swift":
            text = guard_import(text, "CryptoKit", "Crypto")

        if path.name == "GeminiLiveSessionClient.swift":
            text = add_networking_guard(text)
            text = remove_declaration(text, "func sendSessionContext(")
            text = remove_declaration(text, "static func sessionContextPayload(")

        if path.name == "LiveProposalCoordinator.swift":
            text = text.replace("@Published private(set) var cards", "private(set) var cards")

        path.write_text(text)
        print(f"rewrite: {path.name}")


if __name__ == "__main__":
    main()
