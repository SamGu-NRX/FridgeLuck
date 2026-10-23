"""Parser for the committed design tokens in apps/ios/DesignSystem/AppTheme.swift.

The static arm of suite F audits the tokens AS DECLARED in source. This module
turns AppTheme.swift into structured color/spacing data; it never executes
Swift. If the file drifts (renamed tokens, new syntax) the parser reports what
it could not resolve so the audit can widen its conservative interval instead
of silently undercounting.

Colors are declared as dynamic(light: RGB(...), dark: RGB(...)) with optional
RGBA alpha. Values are 0...1 doubles with a #RRGGBB comment next to them; the
comment is not trusted, only the numbers are parsed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# dynamic(light: RGB(red: 0.96, green: 0.94, blue: 0.91), dark: RGB(...))
# dynamic(light: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.10), ...)
_DYN = re.compile(
    r"static\s+let\s+(?P<name>\w+)\s*=\s*dynamic\(\s*"
    r"light:\s*(?P<lt>RGBA?)\(\s*red:\s*(?P<lr>[\d.]+),\s*green:\s*(?P<lg>[\d.]+),\s*"
    r"blue:\s*(?P<lb>[\d.]+)(?:,\s*alpha:\s*(?P<la>[\d.]+))?\s*\)\s*,?\s*"
    r"dark:\s*(?P<dt>RGBA?)\(\s*red:\s*(?P<dr>[\d.]+),\s*green:\s*(?P<dg>[\d.]+),\s*"
    r"blue:\s*(?P<db>[\d.]+)(?:,\s*alpha:\s*(?P<da>[\d.]+))?\s*\)"
)
# static let positive = sage   (alias to another token)
_ALIAS = re.compile(r"static\s+let\s+(?P<name>\w+)\s*=\s*(?P<target>[a-z]\w+)\s*$")
# .opacity(0.12) chained onto a token:  static let accentMuted = accent.opacity(0.12)
_OPACITY = re.compile(
    r"static\s+let\s+(?P<name>\w+)\s*=\s*(?P<target>\w+)\.opacity\((?P<alpha>[\d.]+)\)"
)
# Numeric constants inside named enums, e.g. Space.buttonVertical / Home.navIconSize.
_ENUM_HEADER = re.compile(r"enum\s+(?P<enum>\w+)")
_CONST = re.compile(r"static\s+let\s+(?P<name>\w+)\s*:\s*CGFloat\s*=\s*(?P<value>[\d.]+)")


@dataclass
class ColorToken:
    name: str
    light: tuple[float, float, float, float]  # r, g, b, a
    dark: tuple[float, float, float, float]
    kind: str  # "rgb" | "rgba" | "alias" | "opacity"
    source_of: str | None = None  # for alias/opacity tokens
    alpha: float | None = None  # opacity tokens: the declared alpha


@dataclass
class NumericConstant:
    enum: str
    name: str
    value: float


@dataclass
class ParsedTheme:
    colors: dict[str, ColorToken] = field(default_factory=dict)
    constants: list[NumericConstant] = field(default_factory=list)
    unresolved_lines: list[str] = field(default_factory=list)
    other_declarations: list[str] = field(default_factory=list)
    source_file: str = ""


def parse_theme(theme_path: Path) -> ParsedTheme:
    """Parse AppTheme.swift into tokens. Records anything it cannot resolve.

    `dynamic(light:..., dark:...)` declarations span multiple lines in the
    committed source, so they are accumulated with paren balancing before
    matching. All other declarations stay line-based. Trailing comments are
    stripped first; the #RRGGBB comments are never trusted as data.
    """
    parsed = ParsedTheme(source_file=str(theme_path))
    lines = [ln.split("//")[0].rstrip() for ln in theme_path.read_text().splitlines()]
    current_enum = ""
    i = 0
    n = len(lines)
    while i < n:
        stripped = lines[i].strip()
        if not stripped:
            i += 1
            continue
        enum_match = _ENUM_HEADER.search(stripped)
        if enum_match:
            current_enum = enum_match.group("enum")

        if re.search(r"=\s*dynamic\s*\(", stripped):
            # Accumulate the whole declaration (paren-balanced) so multi-line
            # dynamic() blocks parse as one statement.
            buf = stripped
            depth = buf.count("(") - buf.count(")")
            start_line = i + 1
            while depth > 0 and i + 1 < n:
                i += 1
                buf += " " + lines[i].strip()
                depth += lines[i].count("(") - lines[i].count(")")
            dyn = _DYN.search(buf)
            if dyn:
                name = dyn.group("name")
                parsed.colors[name] = ColorToken(
                    name=name,
                    light=(float(dyn.group("lr")), float(dyn.group("lg")),
                           float(dyn.group("lb")), float(dyn.group("la") or 1.0)),
                    dark=(float(dyn.group("dr")), float(dyn.group("dg")),
                          float(dyn.group("db")), float(dyn.group("da") or 1.0)),
                    kind="rgba" if dyn.group("lt") == "RGBA" else "rgb",
                )
            else:
                parsed.unresolved_lines.append(
                    f"{theme_path.name}:{start_line}: {buf[:160]}"
                )
            i += 1
            continue

        op = _OPACITY.search(stripped)
        if op:
            parsed.colors[op.group("name")] = ColorToken(
                name=op.group("name"),
                light=(), dark=(),
                kind="opacity",
                source_of=op.group("target"),
                alpha=float(op.group("alpha")),
            )
            i += 1
            continue
        alias = _ALIAS.search(stripped)
        if alias and alias.group("target") in parsed.colors:
            parsed.colors[alias.group("name")] = ColorToken(
                name=alias.group("name"),
                light=(), dark=(),
                kind="alias",
                source_of=alias.group("target"),
            )
            i += 1
            continue
        const = _CONST.search(stripped)
        if const:
            parsed.constants.append(
                NumericConstant(
                    enum=current_enum, name=const.group("name"), value=float(const.group("value"))
                )
            )
            i += 1
            continue
        # A declaration line we do not understand: classify it honestly. Font,
        # gradient-shape and other non-color declarations are recognized and
        # parked in other_declarations; only color-suspect lines widen the
        # contrast interval via unresolved_lines.
        if stripped.startswith("static let"):
            if "Font." in stripped or stripped.startswith("static let gradient"):
                parsed.other_declarations.append(f"{theme_path.name}:{i + 1}: {stripped}")
            else:
                parsed.unresolved_lines.append(f"{theme_path.name}:{i + 1}: {stripped}")
        i += 1
    return parsed


def resolve(token: ColorToken, colors: dict[str, ColorToken], mode: str,
            depth: int = 0) -> tuple[float, float, float, float] | None:
    """Resolve a token to concrete RGBA for light/dark; None when unresolvable."""
    if depth > 4:
        return None
    if token.kind in ("rgb", "rgba"):
        return token.light if mode == "light" else token.dark
    source = colors.get(token.source_of or "")
    if source is None:
        return None
    base = resolve(source, colors, mode, depth + 1)
    if base is None:
        return None
    if token.kind == "opacity":
        r, g, b, _ = base
        return (r, g, b, token.alpha if token.alpha is not None else 1.0)
    return base  # alias


def srgb_to_linear(channel: float) -> float:
    """WCAG 2.x sRGB channel -> linear luminance component."""
    if channel <= 0.03928:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def relative_luminance(rgba: tuple[float, float, float, float]) -> float:
    r, g, b, _ = rgba
    return (
        0.2126 * srgb_to_linear(r)
        + 0.7152 * srgb_to_linear(g)
        + 0.0722 * srgb_to_linear(b)
    )


def contrast_ratio(fg: tuple[float, float, float, float],
                   bg: tuple[float, float, float, float]) -> float:
    """WCAG 2.x contrast ratio between two opaque colors (alpha ignored: the
    static arm audits fully opaque declared pairs only)."""
    l1 = relative_luminance(fg)
    l2 = relative_luminance(bg)
    lighter = max(l1, l2)
    darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


def composite_over(fg: tuple[float, float, float, float],
                   bg: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    """Alpha-composite fg over bg (used only for the opacity-token audit)."""
    fa = fg[3]
    if fa >= 1.0:
        return fg
    return tuple(fa * f + (1 - fa) * b for f, b in zip(fg[:3], bg[:3])) + (1.0,)  # type: ignore[return-value]


def theme_facts(repo_root: Path) -> dict[str, Any]:
    """Convenience: parse the committed theme and return audit-ready facts."""
    theme_path = repo_root / "apps" / "ios" / "DesignSystem" / "AppTheme.swift"
    if not theme_path.is_file():
        return {"present": False, "reason": f"{theme_path} not found in this tree"}
    parsed = parse_theme(theme_path)
    return {"present": True, "parsed": parsed}
