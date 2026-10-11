"""CLI entry point. Owned by: CLI/DOCS stream.

Usage contract (fill in; do not edit model.py / codes.py / reader.py / diagnostics.py):
    python3 doctor/cli.py --input PATH [--marker NAME]...
                          [--max-steps N] [--max-rows N] [--max-seconds S]

- Exactly one JSON object on stdout. Stdout carries counts, codes, fingerprints,
  basename and size only — never row values, never raw schema SQL, never
  credentials/private labels, never arbitrary exception text.
- Output goes to stdout ONLY. There is no output-file option; the input path is
  never used as an output destination and nothing on disk is ever written.
- Exit codes (codes.py): 0 clean restorable/compatible, 1 issues found,
  2 refused input, 3 limited/cancelled (never a pass), 4 internal error.
- Report shape:
  {"tool", "report_version", "input": {"basename", "size_bytes", "sha256_16"},
   "verdict", "checks": [...], "issues": [...], "limits": {...},
   "fingerprint": "..."}   or   {"refused": {"code", "detail"}, "verdict":
   "not_readable", "input": {...}} on refusals.
- Internal failures are caught and mapped to {"code": "INTERNAL_ERROR",
  "error_class": "<exception class name>"} with exit 4; never leak message text.
- Runs offline; imports nothing outside the standard library.
"""
from __future__ import annotations


def main(argv=None) -> int:  # noqa: ANN001 - contract stub
    raise NotImplementedError("cli stream: main")


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("fridgeluck-db-doctor: CLI stream not implemented yet")
