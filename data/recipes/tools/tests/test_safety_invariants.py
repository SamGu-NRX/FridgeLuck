"""Safety-invariant tests: planted failures per rule, then the shipped
bundle pinned with strict expected violations.

The catalog rebuild (#210) removed the burst11 claim and sweep violations.
Pins now require no violations. The oats list includes the breakfast and
pantry recipes added by that rebuild; it records Sam's open gluten-free
label decision without changing the safety rules.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

import safety_invariants as si  # noqa: E402

BUNDLE = REPO / "data/recipes/build/recipes-v2.json"
SWIFT_GATE = REPO / "apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift"


# --- Synthetic bundle helpers ---

def ing(key: str, classes: list[str]) -> dict:
    return {"key": key, "classes": classes}


def step(text: str = "stir", uses: list[int] | None = None,
         timer: int | None = None, thermo: dict | None = None) -> dict:
    return {"text": text, "uses": uses or [], "timer_seconds": timer,
            "thermometer": thermo}


def recipe(rid: str, claims: dict, lines: list[str], steps: list[dict]) -> dict:
    base = {"vegetarian": None, "vegan": None, "gluten_free": None,
            "dairy_free": None}
    return {"catalog_id": rid, "claims": {**base, **claims},
            "ingredients": [{"key": k} for k in lines], "steps": steps}


def bundle(recipes: list[dict], ingredients: list[dict]) -> dict:
    return {"schema": "test", "bundle_version": 0, "generated_at": None,
            "cuisines": [], "ingredients": ingredients, "recipes": recipes}


def pairs(rows: list[dict]) -> set[tuple[str, str]]:
    return {(r["recipe"], r["claim"]) for r in rows}


# --- Rule 1: claim true only when derive_claim over the lines is True ---

def test_rule1_flags_true_claim_over_unknown_line():
    b = bundle(
        [recipe("r1", {"vegan": True}, ["rice", "chipotle"], [step()])],
        [ing("rice", ["plant"]), ing("chipotle", ["plant", "unknown"])])
    rows = si.check_claims(b, {e["key"]: e for e in b["ingredients"]})
    assert pairs(rows) == {("r1", "vegan")}
    assert "unknown" in rows[0]["detail"]


def test_rule1_flags_true_claim_a_class_contradicts():
    # derive_claim returns False here; validate_bundle refuses this at compile
    # time, so the shipped bundle should never contain it — the rule still
    # reports it (a claim is true ONLY when the classes prove it True).
    b = bundle(
        [recipe("r2", {"vegetarian": True}, ["chicken"], [step()])],
        [ing("chicken", ["meat"])])
    assert pairs(si.check_claims(b, {e["key"]: e for e in b["ingredients"]})) \
        == {("r2", "vegetarian")}


def test_rule1_clean_when_every_claim_is_proven():
    b = bundle(
        [recipe("r3", {"vegetarian": True, "vegan": False,
                       "gluten_free": True, "dairy_free": False},
                ["rice", "corn"], [step()])],
        [ing("rice", ["plant"]), ing("corn", ["plant"])])
    assert si.check_claims(b, {e["key"]: e for e in b["ingredients"]}) == []


def test_rule1_uses_compile_bundle_derive_claim_one_definition():
    # The check must reuse the compiler's definition, not a re-derivation.
    assert si.compile_bundle is __import__("compile_bundle")
    assert si.CLAIM_BLOCKERS["vegetarian"] == {"meat", "fish", "shellfish"}
    assert si.CLAIM_BLOCKERS["vegan"] == \
        {"meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"}
    assert si.CLAIM_BLOCKERS["gluten_free"] == {"gluten"}
    assert si.CLAIM_BLOCKERS["dairy_free"] == {"dairy"}


# --- Rule 2: vegan True implies vegetarian and dairy_free True ---

def test_rule2_flags_vegan_without_the_implied_claims():
    b = bundle([recipe("r4", {"vegan": True}, ["rice"], [step()])],
               [ing("rice", ["plant"])])
    rows = si.check_vegan_lattice(b)
    assert [r["recipe"] for r in rows] == ["r4"]
    assert rows[0]["missing"] == ["dairy_free", "vegetarian"]


def test_rule2_clean_when_implied_claims_are_true_or_vegan_absent():
    b = bundle(
        [recipe("r5", {"vegan": True, "vegetarian": True, "dairy_free": True},
                ["rice"], [step()]),
         recipe("r6", {"vegan": False}, ["rice"], [step()]),
         recipe("r7", {}, ["rice"], [step()])],
        [ing("rice", ["plant"])])
    assert si.check_vegan_lattice(b) == []


# --- Rule 3: the sweep — claims admit -> class screen admits ---

def test_rule3_sweep_flags_claim_admitted_recipe_the_screen_blocks():
    b = bundle(
        [recipe("r8", {"dairy_free": True}, ["tamari"], [step()])],
        [ing("tamari", ["plant", "unknown"])])
    rows = si.check_sweep(b, {e["key"]: e for e in b["ingredients"]})
    assert {(r["recipe"], r["household"]) for r in rows} == {("r8", "milk")}


def test_rule3_sweep_clean_when_the_screen_agrees():
    b = bundle(
        [recipe("r9", {"dairy_free": True}, ["rice"], [step()]),
         recipe("r10", {"vegetarian": True}, ["tofu"], [step()])],
        [ing("rice", ["plant"]), ing("tofu", ["plant", "soy"])])
    assert si.check_sweep(b, {e["key"]: e for e in b["ingredients"]}) == []


def test_rule3_households_without_claims_fail_closed():
    # No claim speaks for egg/peanut/pescatarian/keto households, so the
    # claim path never admits anything for them; the sweep asserts that
    # direction by construction.
    claims = {"vegetarian": True, "vegan": True, "gluten_free": True,
              "dairy_free": True}
    for restriction in ("egg", "peanut", "tree_nut", "soy", "fish",
                        "shellfish", "sesame", "mustard", "pescatarian",
                        "keto"):
        assert not si.claims_admit((restriction,), None, claims), restriction
    # And the claim-backed households do admit when their claim is True.
    assert si.claims_admit((), "vegetarian", claims)
    assert si.claims_admit(("milk",), None, claims)


def test_rule3_sweep_covers_every_recipe_for_25_households():
    assert len(si.HOUSEHOLDS) == 25
    names = {h["name"] for h in si.HOUSEHOLDS}
    assert names >= {"milk", "egg", "peanut", "tree_nut", "soy",
                     "wheat_gluten", "fish", "shellfish", "sesame",
                     "mustard", "vegetarian", "pescatarian", "vegan", "keto",
                     "milk+vegetarian", "milk+wheat_gluten",
                     "milk+wheat_gluten+vegan", "egg+peanut", "milk+keto"}


def test_rule3_class_screen_mirrors_the_gate():
    # A restricted group's class on any line blocks; keto fails closed;
    # unknown/empty composition blocks any restricted household.
    assert si.screen_block(("milk",), None, [{"dairy"}]) is not None
    assert si.screen_block(("milk",), None, [{"plant"}]) is None
    assert si.screen_block((), "keto", [{"plant"}]) is not None
    assert si.screen_block((), "pescatarian", [{"meat"}]) is not None
    assert si.screen_block((), "pescatarian", [{"fish"}]) is None
    assert si.screen_block(("sesame",), None, [{"plant", "unknown"}]) is not None
    assert si.screen_block(("sesame",), None, [set()]) is not None
    assert si.screen_block((), None, [{"unknown"}]) is None  # unrestricted


# --- Rule 4: thermometer checks for cooked raw animal lines ---

def test_rule4_flags_raw_animal_line_cooked_without_thermometer():
    b = bundle(
        [recipe("r11", {}, ["chicken"], [
            step("Roast the chicken for 30 min", uses=[0], timer=1800)])],
        [ing("chicken", ["meat"])])
    rows = si.check_thermometers(b, {e["key"]: e for e in b["ingredients"]})
    assert [r["recipe"] for r in rows] == ["r11"]
    assert rows[0]["keys"] == ["chicken"]


def test_rule4_clean_with_thermometer():
    thermo = {"endpoint_c": 74.0, "food": "poultry", "fsis_class": "poultry"}
    b = bundle(
        [recipe("r12", {}, ["chicken"], [
            step("Roast the chicken", uses=[0], thermo=thermo)])],
        [ing("chicken", ["meat"])])
    assert si.check_thermometers(b, {e["key"]: e for e in b["ingredients"]}) == []


def test_rule4_ready_to_eat_keys_are_exempt_with_reasons():
    for key in ("canned_tuna", "sardines", "anchovies", "nduja",
                "chicharrones", "fish_sauce"):
        assert key in si.READY_TO_EAT and si.READY_TO_EAT[key]
    for key in ("chicken_stock", "beef_stock", "vegetable_stock", "broth"):
        assert key in si.READY_TO_EAT and si.READY_TO_EAT[key]
    assert "tuna" not in si.READY_TO_EAT  # raw steak: cooked, not exempt
    b = bundle(
        [recipe("r13", {}, ["canned_tuna"], [
            step("Flake the canned tuna into the bowl", uses=[0])])],
        [ing("canned_tuna", ["fish"])])
    assert si.check_thermometers(b, {e["key"]: e for e in b["ingredients"]}) == []


def test_rule4_raw_line_nobody_cooks_needs_no_check():
    b = bundle(
        [recipe("r14", {}, ["egg"], [
            step("Whisk the egg cold for the marinade", uses=[0])])],
        [ing("egg", ["egg"])])
    assert si.check_thermometers(b, {e["key"]: e for e in b["ingredients"]}) == []


# --- Rule 5: timers between 1 s and 12 h ---

@pytest.mark.parametrize("t,ok", [(0, False), (43201, False), (1, True),
                                  (43200, True), (None, True)])
def test_rule5_timer_bounds(t, ok):
    b = bundle([recipe("r15", {}, ["rice"], [step(timer=t)])],
               [ing("rice", ["plant"])])
    rows = si.check_timers(b)
    assert (rows == []) if ok else ([r["recipe"] for r in rows] == ["r15"])


# --- Oats advisory: recorded, never decided ---

def test_oats_advisory_lists_gluten_free_oat_recipes_only():
    b = bundle(
        [recipe("r16", {"gluten_free": True}, ["rolled_oats"], [step()]),
         recipe("r17", {}, ["rolled_oats"], [step()]),
         recipe("r18", {"gluten_free": True}, ["rice"], [step()])],
        [ing("rolled_oats", ["plant"]), ing("rice", ["plant"])])
    assert si.oats_advisory(b, {e["key"]: e for e in b["ingredients"]}) == ["r16"]


# --- Drift against HouseholdSafetyGate.swift ---

def test_swift_gate_tables_match_the_check():
    assert si.swift_table_drift(SWIFT_GATE.read_text()) == []


@pytest.mark.parametrize("mutation,needle", [
    (lambda s: s.replace('case .milk: return "dairy"', 'case .milk: return "soy"'),
     "group->class drifted"),
    (lambda s: s.replace('case mustard\n', '', 1), "allergen groups drifted"),
    (lambda s: s.replace('case pescatarian\n', '', 1), "diets drifted"),
    (lambda s: s.replace('case .vegan: return ["meat", "fish", "shellfish", '
                         '"animal", "dairy", "egg", "honey"]',
                         'case .vegan: return ["meat", "fish"]'),
     "diet->blockedClasses drifted"),
    (lambda s: s.replace("ketoMaxCarbsPerServingGrams: Double? = nil",
                         "ketoMaxCarbsPerServingGrams: Double? = 20"),
     "ketoMaxCarbsPerServingGrams is no longer nil"),
])
def test_swift_drift_is_planted(mutation, needle):
    drifted = mutation(SWIFT_GATE.read_text())
    assert any(needle in d for d in si.swift_table_drift(drifted))


def test_swift_drift_catches_a_missing_unknown_screen():
    drifted = SWIFT_GATE.read_text().replace(
        'for line in lines where line.classes.isEmpty || line.classes.contains("unknown") {',
        'for line in lines where false {')
    assert any("fail-closed screen is gone" in d
               for d in si.swift_table_drift(drifted))


# --- The shipped bundle, pinned strictly ---

# #210 derives claims from every ingredient, including unknown composition.
EXPECTED_RULE1: set[tuple[str, str]] = set()

EXPECTED_RULE2 = {}

EXPECTED_SWEEP: set[tuple[str, str]] = set()

EXPECTED_OATS = [
    "rcp-000167", "rcp-000168", "rcp-000238", "rcp-000507", "rcp-000527",
    "rcp-000538", "rcp-000552", "rcp-000751", "rcp-000776", "rcp-000777",
    "rcp-000778", "rcp-000788", "rcp-000882", "rcp-000901", "rcp-000934",
    "rcp-000954", "rcp-000955", "rcp-000957", "rcp-000990", "rcp-000991",
]


@pytest.fixture(scope="module")
def shipped():
    return si.run_all(BUNDLE)


def test_shipped_rule1_pins(shipped):
    assert pairs(shipped["rule1_claims"]) == EXPECTED_RULE1


def test_shipped_rule2_pins(shipped):
    rows = {r["recipe"]: sorted(r["missing"])
            for r in shipped["rule2_vegan_lattice"]}
    assert rows == EXPECTED_RULE2


def test_shipped_rule3_sweep_pins(shipped):
    rows = {(r["recipe"], r["household"]) for r in shipped["rule3_sweep"]}
    assert rows == EXPECTED_SWEEP
    # every sweep violation must trace to a rule-1 recipe (the same root cause)
    assert {r for r, _ in rows} == {r for r, _ in EXPECTED_RULE1}


def test_shipped_rule4_pins(shipped):
    assert shipped["rule4_thermometers"] == []


def test_shipped_rule5_pins(shipped):
    assert shipped["rule5_timers"] == []


def test_shipped_oats_advisory_pins(shipped):
    assert shipped["oats_advisory"] == EXPECTED_OATS


def test_shipped_sweep_actually_exercised(shipped):
    # The sweep is not vacuous: claim-backed households must admit a real
    # slice of the catalog (so "nothing blocked" would be an observation,
    # not an artifact of nothing being evaluated).
    bundle, ingredients = si.load_bundle(BUNDLE)
    for household in ("vegetarian", "vegan", "milk", "wheat_gluten"):
        h = next(x for x in si.HOUSEHOLDS if x["name"] == household)
        admitted = sum(1 for r in bundle["recipes"]
                       if si.claims_admit(h["groups"], h["diet"], r["claims"]))
        assert admitted > 20, household
    for household in ("egg", "pescatarian", "keto"):
        h = next(x for x in si.HOUSEHOLDS if x["name"] == household)
        admitted = sum(1 for r in bundle["recipes"]
                       if si.claims_admit(h["groups"], h["diet"], r["claims"]))
        assert admitted == 0, household


# --- CLI ---

def test_cli_exits_0_and_reports_oats_advisory_on_the_shipped_bundle():
    out = subprocess.run(
        [sys.executable, "-I", str(TOOLS / "safety_invariants.py"), str(BUNDLE)],
        capture_output=True, text=True, cwd=REPO)
    assert out.returncode == 0
    assert "advisory" in out.stdout and "violations: 0" in out.stdout


def test_cli_exits_1_and_reports_planted_violations(tmp_path):
    bad = bundle(
        [recipe("unsafe-claim", {"vegetarian": True}, ["chicken"], [step()])],
        [ing("chicken", ["meat"])])
    p = tmp_path / "unsafe-bundle.json"
    p.write_text(__import__("json").dumps(bad))
    out = subprocess.run(
        [sys.executable, "-I", str(TOOLS / "safety_invariants.py"), str(p)],
        capture_output=True, text=True, cwd=REPO)
    assert out.returncode == 1, out.stdout + out.stderr
    assert "'unsafe-claim'" in out.stdout and "'vegetarian'" in out.stdout
    assert "violations: 2" in out.stdout


def test_cli_exits_0_on_a_clean_bundle(tmp_path):
    clean = bundle(
        [recipe("rX", {"vegetarian": True, "gluten_free": True},
                ["rice", "tofu"], [step(timer=600)])],
        [ing("rice", ["plant"]), ing("tofu", ["plant", "soy"])])
    p = tmp_path / "clean-bundle.json"
    p.write_text(__import__("json").dumps(clean))
    out = subprocess.run(
        [sys.executable, "-I", str(TOOLS / "safety_invariants.py"), str(p)],
        capture_output=True, text=True, cwd=REPO)
    assert out.returncode == 0, out.stdout + out.stderr
    assert "violations: 0" in out.stdout


def test_cli_usage_error(tmp_path):
    out = subprocess.run(
        [sys.executable, "-I", str(TOOLS / "safety_invariants.py"),
         str(tmp_path / "missing.json")],
        capture_output=True, text=True, cwd=REPO)
    assert out.returncode == 2
