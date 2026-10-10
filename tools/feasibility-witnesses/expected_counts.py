"""Expected verifier outcomes for the built record corpus.

The nine valid certificates are all claim-backed and derivation-consistent,
so every one is accepted with explanation_verdict "supported". The eighteen
mutations m01-m18 each target exactly one rejection class.
"""

EXPECTED_MUTANT_CLASSES = {
    "m01": "structure",
    "m02": "structure",
    "m03": "structure",
    "m04": "structure",
    "m05": "source_binding",
    "m06": "source_binding",
    "m07": "source_binding",
    "m08": "source_binding",
    "m09": "claim_not_in_source",
    "m10": "claim_not_in_source",
    "m11": "claim_not_in_source",
    "m12": "incomplete_witness",
    "m13": "incomplete_witness",
    "m14": "incomplete_witness",
    "m15": "unsupported_witness",
    "m16": "unsupported_witness",
    "m17": "unsupported_witness",
    "m18": "unsupported_witness",
}

EXPECTED_CLASS_COUNTS: dict[str, int] = {}
for _c in EXPECTED_MUTANT_CLASSES.values():
    EXPECTED_CLASS_COUNTS[_c] = EXPECTED_CLASS_COUNTS.get(_c, 0) + 1

TOTAL_MUTANTS = len(EXPECTED_MUTANT_CLASSES)
TOTAL_VALIDS = 9


def assert_expected_counts(summary: dict, valid_count: int = TOTAL_VALIDS) -> list[str]:
    errs: list[str] = []
    if summary["records"] != valid_count + TOTAL_MUTANTS:
        errs.append(
            f"records: expected {valid_count + TOTAL_MUTANTS}, got {summary['records']}"
        )
    if summary["accepted"] != valid_count:
        errs.append(f"accepted: expected {valid_count}, got {summary['accepted']}")
    if summary["rejected"] != TOTAL_MUTANTS:
        errs.append(f"rejected: expected {TOTAL_MUTANTS}, got {summary['rejected']}")
    if summary["rejected_by_class"] != EXPECTED_CLASS_COUNTS:
        errs.append(
            f"rejected_by_class: expected {EXPECTED_CLASS_COUNTS}, "
            f"got {summary['rejected_by_class']}"
        )
    if summary["supported"] != valid_count:
        errs.append(f"supported: expected {valid_count}, got {summary['supported']}")
    if summary["unsupported"] != 0:
        errs.append(f"unsupported: expected 0, got {summary['unsupported']}")
    return errs
