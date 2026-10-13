"""Deterministic cell formatting for fixture study tables.

Exact integer/rational arithmetic only: one decimal, half-up, no float
formatting anywhere, so the rendered table is digest-stable across runs.
"""

from decimal import ROUND_HALF_UP, Decimal
from fractions import Fraction

_ONE_DECIMAL = Decimal("0.1")


def fmt_count(value: int) -> str:
    return str(int(value))


def fmt_ratio(numerator: int, denominator: int) -> str:
    if denominator == 0:
        return "0.0"
    fraction = Fraction(numerator, denominator)
    share = Decimal(fraction.numerator) / Decimal(fraction.denominator)
    return str(share.quantize(_ONE_DECIMAL, rounding=ROUND_HALF_UP))
