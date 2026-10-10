import copy
import sys
from pathlib import Path

import pytest

TOOL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL_DIR))

import build_records  # noqa: E402
import certificate  # noqa: E402
from sources import SourceBundle  # noqa: E402


@pytest.fixture(scope="module")
def valid_1101():
    subprocess_ok = (TOOL_DIR / "fixtures" / "manifest.json").is_file()
    assert subprocess_ok, "fixtures must be generated before schema tests"
    bundle = SourceBundle(TOOL_DIR / "fixtures")
    return build_records.build_valid(bundle, 1, 101, "complete_match")


def _find(cert, iid, required=True):
    lst = cert["required_witnesses"] if required else cert["optional_witnesses"]
    return next(w for w in lst if w["ingredient_id"] == iid)


def test_valid_certificate_is_well_formed(valid_1101):
    assert certificate.structural_errors(valid_1101) == []


def test_missing_required_grams_rejected(valid_1101):
    cert = copy.deepcopy(valid_1101)
    del _find(cert, 2)["required_grams"]
    assert any("required_grams" in e for e in certificate.structural_errors(cert))


def test_string_grams_rejected(valid_1101):
    cert = copy.deepcopy(valid_1101)
    _find(cert, 1)["required_grams"] = "150"
    assert any("non-negative number" in e for e in certificate.structural_errors(cert))


def test_estimated_lot_with_numeric_grams_rejected(bundle):
    cert = build_records.build_valid(bundle, 1, 102, "complete_match")
    _find(cert, 12)["basis_lots"] = [
        {"ingredient_id": 12, "known_grams": 180.0, "is_estimate": True}
    ]
    assert any("known_grams null" in e for e in certificate.structural_errors(cert))


def test_unknown_must_not_assert_amount(bundle):
    cert = build_records.build_valid(bundle, 1, 102, "complete_match")
    _find(cert, 12)["available_grams"] = 180.0
    assert any("available_grams must be omitted" in e for e in certificate.structural_errors(cert))


def test_explanation_kind_must_match_claim(valid_1101):
    cert = copy.deepcopy(valid_1101)
    cert["explanation"] = {"kind": "missing_list", "missing": [], "excluded": [],
                           "unknown_quantity": [], "satisfied": []}
    errs = certificate.structural_errors(cert)
    assert any("explanation.kind" in e for e in errs)


def test_duplicate_witness_rejected(valid_1101):
    cert = copy.deepcopy(valid_1101)
    cert["required_witnesses"].append(copy.deepcopy(cert["required_witnesses"][0]))
    assert any("duplicate witness" in e for e in certificate.structural_errors(cert))


def test_optional_kind_in_required_list_rejected(valid_1101):
    cert = copy.deepcopy(valid_1101)
    cert["required_witnesses"].append({"ingredient_id": 7, "kind": "optional_absent"})
    assert any("not a valid required kind" in e for e in certificate.structural_errors(cert))


def test_overlap_required_and_optional_rejected(bundle):
    cert = build_records.build_valid(bundle, 1, 101, "complete_match")
    cert["required_witnesses"].append(
        {"ingredient_id": 22, "kind": "absent", "required_grams": 10.0}
    )
    cert["optional_witnesses"].append({"ingredient_id": 22, "kind": "optional_absent"})
    assert any(
        "both required and optional" in e for e in certificate.structural_errors(cert)
    )


def test_partition_double_listing_rejected(bundle):
    cert = build_records.build_valid(bundle, 2, 102, "missing_list")
    cert["explanation"]["satisfied"].append(5)
    errs = certificate.structural_errors(cert)
    assert any("twice" in e for e in errs)


def test_partition_unwitnessed_id_rejected(bundle):
    cert = build_records.build_valid(bundle, 2, 102, "missing_list")
    cert["explanation"]["missing"].append(42)
    errs = certificate.structural_errors(cert)
    assert any("unwitnessed ingredient 42" in e for e in errs)


def test_basis_lot_citing_other_ingredient_rejected(valid_1101):
    cert = copy.deepcopy(valid_1101)
    _find(cert, 2)["basis_lots"] = [
        {"ingredient_id": 1, "known_grams": 500.0, "is_estimate": False}
    ]
    errs = certificate.structural_errors(cert)
    assert any("cites ingredient 1" in e for e in errs)
