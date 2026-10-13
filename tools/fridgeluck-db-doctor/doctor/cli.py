"""CLI entry point for fridgeluck-db-doctor. Owned by: CLI/DOCS stream.

Usage:
    python3 doctor/cli.py --input PATH [--marker NAME]...
                          [--max-steps N] [--max-rows N] [--max-seconds S]

Behavior contract:
- Exactly one JSON object on stdout, and stdout only. It carries counts, codes,
  fingerprints, basename and size — never row values, never raw schema SQL,
  never credentials, never arbitrary exception text.
- The tool writes nothing to disk: no output-file option, the input path is
  never an output destination, and a missing input file is never created.
- Exit codes (codes.py): 0 clean app_compatible_candidate/restorable_candidate,
  1 issues found, 2 refused input (argparse usage errors also exit 2),
  3 limited or cancelled — never a pass, 4 internal error — never a pass.
- Refusal output: {"tool", "report_version", "input": {"basename",
  "size_bytes", "sha256_16"}, "verdict": "not_readable", "refused":
  {"code", "detail"}} with a short fixed detail string, exit 2.
- Internal failures are caught and mapped to {"tool", "report_version",
  "verdict": "not_readable", "internal_error": {"code": "INTERNAL_ERROR",
  "error_class": "<exception class name>"}} with exit 4; exception text is
  never surfaced.
- Runs offline; imports nothing outside the standard library.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# sys.path bootstrap so this runs as a plain script (python3 doctor/cli.py)
# and imports cleanly under tests: parents[1] is the tool directory.
_TOOL_DIR = Path(__file__).resolve().parents[1]
for _entry in (str(_TOOL_DIR), str(_TOOL_DIR / "doctor")):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)

import codes  # noqa: E402  (flat imports; path bootstrapped above)
import diagnostics  # noqa: E402
import model  # noqa: E402
import reader  # noqa: E402

TOOL_NAME = "fridgeluck-db-doctor"
REPORT_VERSION = 1
# CLI-only refusal code: non-positive budget flags. Not a codes.py input
# refusal — the file was never the problem.
INVALID_BUDGET = "INVALID_BUDGET"

# Fixed, short detail strings keyed by refusal code. Refusal output never
# echoes paths beyond the operator's basename, and never carries exception text.
_REFUSAL_DETAILS = {
    codes.INPUT_MISSING: "input file does not exist",
    codes.INPUT_NOT_REGULAR: "input is not a regular file",
    codes.INPUT_SYMLINK: "input is a symlink; symlinks are never followed",
    codes.INPUT_NOT_SQLITE: "input is not a SQLite 3 database",
    codes.INPUT_SIDECAR_PRESENT: "pending -wal/-shm/-journal sidecar present",
}


def _emit(payload: dict) -> None:
    print(json.dumps(payload, sort_keys=True))


def _refusal_payload(path: str, code: str, detail: str) -> dict:
    """Refusal report. The file was never opened, so size/digest stay unknown."""
    return {
        "tool": TOOL_NAME,
        "report_version": REPORT_VERSION,
        "input": {"basename": os.path.basename(path), "size_bytes": 0, "sha256_16": None},
        "verdict": codes.VERDICT_NOT_READABLE,
        "refused": {"code": code, "detail": detail},
    }


def _internal_error_payload(error_class: str) -> dict:
    return {
        "tool": TOOL_NAME,
        "report_version": REPORT_VERSION,
        "verdict": codes.VERDICT_NOT_READABLE,
        "internal_error": {"code": codes.ISSUE_INTERNAL, "error_class": error_class},
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fridgeluck-db-doctor",
        description=(
            "Bounded, strictly read-only inspection of a FridgeLuck SQLite "
            "artifact; prints exactly one JSON report on stdout, writes nothing."
        ),
    )
    parser.add_argument(
        "--input", required=True, metavar="PATH",
        help="artifact to inspect (read-only; never modified, never created)",
    )
    parser.add_argument(
        "--marker", action="append", default=None, metavar="NAME",
        help="extra table to require as a structural marker; repeats extend the built-in list",
    )
    parser.add_argument(
        "--max-steps", type=int, default=200_000, metavar="N",
        help="progress-handler steps per connection (default: 200000)",
    )
    parser.add_argument(
        "--max-rows", type=int, default=10_000, metavar="N",
        help="max rows fetched by any single bounded scan (default: 10000)",
    )
    parser.add_argument(
        "--max-seconds", type=float, default=10.0, metavar="S",
        help="wall-clock deadline for the whole inspection (default: 10.0)",
    )
    return parser


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        try:
            budget = model.Budget(
                max_steps=args.max_steps,
                max_rows=args.max_rows,
                max_seconds=args.max_seconds,
            )
        except ValueError:
            _emit(_refusal_payload(args.input, INVALID_BUDGET, "invalid budget"))
            return codes.EXIT_REFUSED_INPUT

        expected_tables = tuple(diagnostics.DEFAULT_EXPECTED_TABLES) + tuple(args.marker or ())

        try:
            reader.probe_input(args.input)  # pre-open refusal gate (missing/symlink/...)
            con, info, _handle = reader.open_read_only(args.input, budget)
            try:
                result = diagnostics.run_diagnostics(con, budget, expected_tables=expected_tables)
            finally:
                con.close()
        except model.RefusalError as refusal:
            _emit(_refusal_payload(
                args.input,
                refusal.code,
                _REFUSAL_DETAILS.get(refusal.code, "input refused before open"),
            ))
            return codes.EXIT_REFUSED_INPUT

        verdict = result.verdict
        if isinstance(verdict, model.Verdict):
            verdict = verdict.value

        limited = any(
            result.limits.get(flag) for flag in ("cancelled", "truncated", "deadline_hit")
        ) or any(check.status == codes.STATUS_LIMITED for check in result.checks)
        if limited:
            exit_code = codes.EXIT_LIMITED
        elif result.issues:
            exit_code = codes.EXIT_ISSUES_FOUND
        else:
            exit_code = codes.EXIT_OK

        _emit({
            "tool": TOOL_NAME,
            "report_version": REPORT_VERSION,
            "input": {
                "basename": info.basename,
                "size_bytes": info.size_bytes,
                "sha256_16": info.sha256_16,
            },
            "verdict": verdict,
            "checks": [check.to_dict() for check in result.checks],
            "issues": result.issues,
            "limits": result.limits,
            "fingerprint": result.fingerprint,
        })
        return exit_code

    except Exception as exc:  # deliberate catch-all: map to JSON, never leak text
        _emit(_internal_error_payload(type(exc).__name__))
        return codes.EXIT_INTERNAL_ERROR


if __name__ == "__main__":
    sys.exit(main())
