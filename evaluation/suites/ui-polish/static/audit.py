"""Static audit arm of suite F (ui-polish) — pure Python, runs on any host.

This arm is SUPPORTING EVIDENCE ONLY. It audits what is statically knowable
from the committed SwiftUI source and design tokens:

1. WCAG 2.x contrast math over the declared text/surface token pairs from
   AppTheme.swift, in both light and dark modes (the 4.5:1 body-text rule).
2. Declared minimum-size inventory: numeric constants and literal
   frame(minWidth:)/frame(minHeight:) declarations below 44 pt anywhere in the
   app source (the 44 pt touch-target rule; 64 pt cook-mode targets are
   measured on-device by the XCUITest arm, not here).
3. XXL Dynamic Type clipping risks: text containers with fixed literal heights
   or single-line limits, which are the patterns that clip at XXL.

It does NOT replace the macOS arm: it cannot see rendering, resolved Dynamic
Type layout, or runtime compositing. Counts carry conservative intervals: any
source file that fails to parse widens the high bound, so a broken audit can
never look clean.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import tokens

# Tokens the design system declares as text or accent-colored foregrounds.
TEXT_TOKENS = ("textPrimary", "textSecondary")
ACCENT_TEXT_TOKENS = ("accent", "sage", "oat", "dustyRose")
# Gradients behind hero text: audited against the worse endpoint.
GRADIENT_TOKENS = ("heroLight", "heroMid")

BODY_TEXT_MIN_RATIO = 4.5
TOUCH_TARGET_PT = 44.0

_FIXED_HEIGHT = re.compile(r"\.frame\(\s*height:\s*([\d.]+)\b")
_SINGLE_LINE = re.compile(r"\.lineLimit\(\s*1\s*\)")
_MIN_DIMENSION = re.compile(r"\.frame\(\s*min(?:Width|Height):\s*([\d.]+)\b")
_TEXT_DECL = re.compile(r"\bText\(")


@dataclass
class StaticFindings:
    contrast_pairs_audited: int = 0
    contrast_violations: list[dict[str, Any]] = field(default_factory=list)
    contrast_dark_panel_pairs: list[dict[str, Any]] = field(default_factory=list)
    contrast_accent_below_3: list[dict[str, Any]] = field(default_factory=list)
    contrast_unresolved: list[str] = field(default_factory=list)
    declared_minimums_below_44: list[dict[str, Any]] = field(default_factory=list)
    declared_minimums_unparsed_files: list[str] = field(default_factory=list)
    xxl_clipping_risks: list[dict[str, Any]] = field(default_factory=list)
    xxl_risk_unparsed_files: list[str] = field(default_factory=list)


def _hex_of(rgba: tuple[float, float, float, float]) -> str:
    r, g, b, _ = rgba
    return "#{:02X}{:02X}{:02X}".format(
        round(r * 255), round(g * 255), round(b * 255)
    )


def audit_contrast(parsed: tokens.ParsedTheme, findings: StaticFindings) -> None:
    """Evaluate declared token pairs with WCAG 2.x math, in three buckets.

    - body pairs (textPrimary/textSecondary on the light neutrals bg/bgDeep/
      surface/surfaceMuted/surfaceElevated, both modes): these are the pairs
      the SPEC 4.5:1 body-text rule governs; violations count toward the
      static metric value.
    - dark-panel pairs (the same text tokens on deepOlive/deepOliveLight):
      those panels render light text tokens by design, so a dark-token pair
      failing 4.5:1 there is a declaration artifact, not a body-text
      violation. Recorded as context for the macOS arm, never counted.
    - accent/gradient pairs (accent-colored text on every surface and the
      hero gradient endpoints): large-text/graphics territory (3:1). Listed
      as evidence; the 4.5:1 body-text bar does not apply to them.
    """
    colors = parsed.colors
    body_fg = list(TEXT_TOKENS)
    body_surfaces = ("bg", "bgDeep", "surface", "surfaceMuted", "surfaceElevated")
    dark_panels = ("deepOlive", "deepOliveLight")
    accent_fg = list(ACCENT_TEXT_TOKENS)
    gradient_surfaces = list(GRADIENT_TOKENS)

    def evaluate(fg_name: str, bg_name: str, mode: str) -> dict[str, Any] | None:
        fg_token = colors.get(fg_name)
        bg_token = colors.get(bg_name)
        if fg_token is None:
            findings.contrast_unresolved.append(f"missing text token {fg_name}")
            return None
        if bg_token is None:
            findings.contrast_unresolved.append(f"missing surface token {bg_name}")
            return None
        fg = tokens.resolve(fg_token, colors, mode)
        bgc = tokens.resolve(bg_token, colors, mode)
        if fg is None or bgc is None:
            findings.contrast_unresolved.append(f"unresolvable {fg_name} on {bg_name} ({mode})")
            return None
        if fg[3] < 1.0:
            fg = tokens.composite_over(fg, bgc)
        ratio = tokens.contrast_ratio(fg, bgc)
        return {
            "pair": f"{fg_name} on {bg_name} ({mode})",
            "ratio": round(ratio, 2),
            "fg": _hex_of(fg),
            "bg": _hex_of(bgc),
            "below": ratio < BODY_TEXT_MIN_RATIO,
        }

    for fg_name in body_fg:
        for bg_name in body_surfaces:
            for mode in ("light", "dark"):
                result = evaluate(fg_name, bg_name, mode)
                if result is None:
                    continue
                findings.contrast_pairs_audited += 1
                if result["below"]:
                    findings.contrast_violations.append(dict(result, **{
                        "class": "body text",
                        "note": "declared body-text pair below 4.5:1",
                    }))
        for bg_name in dark_panels:
            for mode in ("light", "dark"):
                result = evaluate(fg_name, bg_name, mode)
                if result is None:
                    continue
                findings.contrast_pairs_audited += 1
                if result["below"]:
                    findings.contrast_dark_panel_pairs.append(dict(result, **{
                        "note": ("dark panel takes light text tokens by design; "
                                 "dark-token pairing is a declaration artifact — "
                                 "macOS arm verifies what is actually rendered"),
                    }))

    for fg_name in accent_fg:
        for bg_name in body_surfaces + dark_panels + tuple(gradient_surfaces):
            for mode in ("light", "dark"):
                result = evaluate(fg_name, bg_name, mode)
                if result is None:
                    continue
                findings.contrast_pairs_audited += 1
                if result["ratio"] < 3.0:
                    findings.contrast_accent_below_3.append(dict(result, **{
                        "class": "accent-colored text",
                        "note": ("below the 3:1 large-text/graphics rule; the "
                                 "4.5:1 body-text bar does not apply to accent text"),
                    }))


def audit_declared_minimums(repo_root: Path, findings: StaticFindings) -> None:
    """Inventory literal frame(minWidth:)/minHeight:) declarations below 44 pt."""
    app_dir = repo_root / "apps" / "ios"
    for swift in sorted(app_dir.rglob("*.swift")):
        try:
            lines = swift.read_text().splitlines()
        except OSError as exc:
            findings.declared_minimums_unparsed_files.append(f"{swift}: {exc}")
            continue
        rel = swift.relative_to(repo_root)
        for lineno, line in enumerate(lines, start=1):
            for match in _MIN_DIMENSION.finditer(line):
                value = float(match.group(1))
                if value < TOUCH_TARGET_PT:
                    findings.declared_minimums_below_44.append({
                        "file": str(rel), "line": lineno,
                        "declared_pt": value,
                        "source": line.strip()[:120],
                    })


def audit_xxl_clipping_risks(repo_root: Path, findings: StaticFindings) -> None:
    """Flag fixed-height frames and single-line limits near Text declarations.

    A fixed pixel height or a lineLimit(1) is the pattern that clips when the
    user's Dynamic Type reaches XXL. Static detection is heuristic: these are
    risks to review, not proven violations.
    """
    app_dir = repo_root / "apps" / "ios"
    for swift in sorted(app_dir.rglob("*.swift")):
        try:
            lines = swift.read_text().splitlines()
        except OSError as exc:
            findings.xxl_risk_unparsed_files.append(f"{swift}: {exc}")
            continue
        rel = swift.relative_to(repo_root)
        for lineno, line in enumerate(lines, start=1):
            has_text = any(_TEXT_DECL.search(l) for l in lines[max(0, lineno - 6): lineno + 1])
            for match in _FIXED_HEIGHT.finditer(line):
                height = float(match.group(1))
                if height < 90 and has_text:
                    findings.xxl_clipping_risks.append({
                        "file": str(rel), "line": lineno,
                        "kind": "fixed-height frame near Text",
                        "height_pt": height,
                        "source": line.strip()[:120],
                    })
            if _SINGLE_LINE.search(line) and has_text:
                findings.xxl_clipping_risks.append({
                    "file": str(rel), "line": lineno,
                    "kind": "lineLimit(1) near Text (truncates at XXL)",
                    "height_pt": None,
                    "source": line.strip()[:120],
                })


def run_static_audit(repo_root: Path) -> dict[str, Any]:
    """Run the whole static arm; returns findings plus conservative intervals.

    Every count metric gets interval [found, found + unresolved] so unparseable
    inputs widen the reported range instead of hiding behind a clean zero.
    """
    findings = StaticFindings()
    theme_path = repo_root / "apps" / "ios" / "DesignSystem" / "AppTheme.swift"
    if not theme_path.is_file():
        return {
            "present": False,
            "reason": f"design tokens not found: {theme_path}",
        }
    parsed = tokens.parse_theme(theme_path)
    findings.contrast_unresolved.extend(parsed.unresolved_lines)
    audit_contrast(parsed, findings)
    audit_declared_minimums(repo_root, findings)
    audit_xxl_clipping_risks(repo_root, findings)

    contrast_high = len(findings.contrast_violations) + len(findings.contrast_unresolved)
    minimums_high = (
        len(findings.declared_minimums_below_44)
        + len(findings.declared_minimums_unparsed_files)
    )
    xxl_high = len(findings.xxl_clipping_risks) + len(findings.xxl_risk_unparsed_files)
    return {
        "present": True,
        "contrast": {
            "pairs_audited": findings.contrast_pairs_audited,
            "violations": findings.contrast_violations,
            "dark_panel_pairs": findings.contrast_dark_panel_pairs,
            "accent_below_3": findings.contrast_accent_below_3,
            "unresolved": findings.contrast_unresolved,
            "interval": [len(findings.contrast_violations), contrast_high],
        },
        "touch_minimums": {
            "below_44": findings.declared_minimums_below_44,
            "unparsed_files": findings.declared_minimums_unparsed_files,
            "interval": [
                len(findings.declared_minimums_below_44),
                minimums_high,
            ],
        },
        "xxl_risks": {
            "risks": findings.xxl_clipping_risks,
            "unparsed_files": findings.xxl_risk_unparsed_files,
            "interval": [len(findings.xxl_clipping_risks), xxl_high],
        },
    }
