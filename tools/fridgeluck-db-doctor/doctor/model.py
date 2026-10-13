"""Frozen data model shared by reader, diagnostics and CLI.

This file is the interface contract between the four work streams. Fill in the
stubs in reader.py / diagnostics.py / cli.py against these types; do NOT edit
model.py or codes.py (owned by the integrator).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

# --- Budget: hard caps for one inspection run. All inspections are bounded. ---
@dataclass(frozen=True)
class Budget:
    max_steps: int = 200_000      # SQLite progress-handler steps per connection
    max_rows: int = 10_000        # max rows fetched by any single bounded scan
    max_seconds: float = 10.0     # wall-clock deadline for the whole inspection

    def __post_init__(self) -> None:
        if self.max_steps < 1 or self.max_rows < 1 or self.max_seconds <= 0:
            raise ValueError("budget caps must be positive")


class Verdict(str, Enum):
    NOT_READABLE = "not_readable"                    # refused before open
    STRUCTURALLY_READABLE = "structurally_readable"  # valid SQLite, opened RO, schema listed
    READABLE_WITH_ISSUES = "readable_with_issues"    # opened RO but integrity/FK/marker problems
    APP_COMPATIBLE = "app_compatible_candidate"      # readable + FridgeLuck structural markers present
    RESTORABLE_CANDIDATE = "restorable_candidate"    # app-compatible + clean integrity + 0 FK + nothing limited


@dataclass
class CheckResult:
    """One diagnostic. detail carries counts/codes only — never row values or SQL text."""
    code: str
    status: str                      # pass | fail | limited | skipped
    detail: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {"code": self.code, "status": self.status, "detail": dict(self.detail)}


@dataclass
class DiagnosticsResult:
    verdict: str                     # a Verdict value (string for cheap JSON)
    checks: list                     # list[CheckResult]
    issues: list                     # list[{"code": str, "count": int}]
    limits: dict                     # {"cancelled": bool, "truncated": bool, "deadline_hit": bool,
                                     #  "steps_used": int, "steps_max": int}
    fingerprint: "str | None"        # 16-hex schema fingerprint, or None


@dataclass(frozen=True)
class InputInfo:
    path: str                        # as given by the operator
    basename: str                    # safe for output
    size_bytes: int
    sha256_16: str                   # first 16 hex chars of the file's SHA-256


class RefusalError(Exception):
    """Raised before/at open when the input must be rejected. .code is a stable refusal code."""
    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


class BudgetExceeded(Exception):
    """Raised internally when the deadline or step budget aborts an operation."""
    def __init__(self, reason: str):  # "deadline" | "steps"
        super().__init__(reason)
        self.reason = reason
