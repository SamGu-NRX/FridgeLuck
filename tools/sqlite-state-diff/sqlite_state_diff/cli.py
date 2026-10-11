"""Command-line entry point for sqlite-state-diff.

Scaffold checkpoint: this file pins the argument surface and the exit-code
contract. The comparison core (readers.py, kernel.py) lands in the next
checkpoint and main() will be wired to it; until then the command refuses
to guess rather than pretend equality.
"""

import argparse
import sys

EXIT_EQUAL = 0
EXIT_DIFFERENT = 1
EXIT_INVALID = 2
EXIT_LIMITED = 3


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sqlite-state-diff",
        description=(
            "Read-only comparison of two closed synthetic SQLite fixtures. "
            "Reports schema, row, and typed-value differences as deterministic JSON."
        ),
    )
    p.add_argument("a", metavar="A", help="first fixture file (opened read-only, never modified)")
    p.add_argument("b", metavar="B", help="second fixture file (opened read-only, never modified)")
    p.add_argument(
        "--table",
        action="append",
        required=True,
        metavar="NAME",
        help="table to compare (repeat for several tables)",
    )
    p.add_argument(
        "--key",
        action="append",
        default=[],
        metavar="TABLE:COL[,COL...]",
        help=(
            "explicit row identity for a table; required when the table has no "
            "stable declared primary key. Without a stable identity the tool "
            "refuses rather than guess row order."
        ),
    )
    p.add_argument(
        "--max-rows-per-table",
        type=int,
        default=None,
        metavar="N",
        help="row bound per table; a breach marks the result limited (never equal)",
    )
    p.add_argument(
        "--time-budget-seconds",
        type=float,
        default=None,
        metavar="S",
        help="wall-clock bound; a breach marks the result limited (never equal)",
    )
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    print(
        "sqlite-state-diff: comparison core not present in the scaffold checkpoint",
        file=sys.stderr,
    )
    return EXIT_INVALID


if __name__ == "__main__":
    sys.exit(main())
