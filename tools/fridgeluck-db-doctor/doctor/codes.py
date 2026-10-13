"""Stable machine-readable codes for fridgeluck-db-doctor.

These constants are part of the output contract: tests, CI and operators may
match on them. Do not rename or remove codes without updating tests and README.
"""
from __future__ import annotations

# --- Exit statuses (the only values the CLI process returns) ---
EXIT_OK = 0               # inspection completed inside budget; no issues found
EXIT_ISSUES_FOUND = 1     # inspection completed inside budget; issues reported
EXIT_REFUSED_INPUT = 2    # input rejected before open (see refusal code)
EXIT_LIMITED = 3          # inspection cancelled, truncated or deadline hit: never a pass
EXIT_INTERNAL_ERROR = 4   # unexpected internal failure: never a pass

# --- Refusal codes (input rejected before opening; exit 2) ---
INPUT_MISSING = "INPUT_MISSING"
INPUT_NOT_REGULAR = "INPUT_NOT_REGULAR_FILE"
INPUT_SYMLINK = "INPUT_SYMLINK"
INPUT_NOT_SQLITE = "INPUT_NOT_SQLITE"
INPUT_SIDECAR_PRESENT = "INPUT_SIDECAR_PRESENT"

# --- Check codes (one per diagnostic) ---
CHECK_OPEN_READ_ONLY = "OPEN_READ_ONLY"
CHECK_HEADER_MAGIC = "HEADER_MAGIC"
CHECK_INTEGRITY = "INTEGRITY_CHECK"
CHECK_FOREIGN_KEYS = "FOREIGN_KEY_CHECK"
CHECK_TABLE_PRESENCE = "TABLE_PRESENCE"
CHECK_MIGRATION_STATE = "MIGRATION_STATE"
CHECK_SCHEMA_FINGERPRINT = "SCHEMA_FINGERPRINT"

# --- Check statuses ---
STATUS_PASS = "pass"
STATUS_FAIL = "fail"
STATUS_LIMITED = "limited"
STATUS_SKIPPED = "skipped"

# --- Issue codes (aggregated in report["issues"]) ---
ISSUE_INTEGRITY_ERRORS = "INTEGRITY_ERRORS"
ISSUE_FK_VIOLATIONS = "FOREIGN_KEY_VIOLATIONS"
ISSUE_EXPECTED_TABLE_MISSING = "EXPECTED_TABLE_MISSING"
ISSUE_MIGRATION_STATE_UNKNOWN = "MIGRATION_STATE_UNKNOWN"
ISSUE_MIGRATION_LAGGING = "MIGRATION_LAGGING"
ISSUE_CANCELLED = "CHECK_CANCELLED"
ISSUE_LIMITED_ROWS = "CHECK_LIMITED_ROWS"
ISSUE_DEADLINE = "CHECK_DEADLINE_EXCEEDED"
ISSUE_INTERNAL = "INTERNAL_ERROR"

# --- Verdict values (report["verdict"]) ---
VERDICT_NOT_READABLE = "not_readable"
VERDICT_READABLE = "structurally_readable"
VERDICT_READABLE_WITH_ISSUES = "readable_with_issues"
VERDICT_APP_COMPATIBLE = "app_compatible_candidate"
VERDICT_RESTORABLE = "restorable_candidate"

REFUSAL_CODES = frozenset({
    INPUT_MISSING, INPUT_NOT_REGULAR, INPUT_SYMLINK,
    INPUT_NOT_SQLITE, INPUT_SIDECAR_PRESENT,
})
CHECK_STATUSES = frozenset({STATUS_PASS, STATUS_FAIL, STATUS_LIMITED, STATUS_SKIPPED})
VERDICTS = frozenset({
    VERDICT_NOT_READABLE, VERDICT_READABLE, VERDICT_READABLE_WITH_ISSUES,
    VERDICT_APP_COMPATIBLE, VERDICT_RESTORABLE,
})
