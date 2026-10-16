#!/usr/bin/env python3
"""Mutation matrix for docs/spec/taste/contracts.

Every case mutates a throwaway copy of examples/, runs check.py there, and
requires the checker to FAIL (exit != 0). The final positive control runs the
checker on an untouched copy and requires success. Each case names the review
finding (F1..F9) it pins. Run from the repo root:
  python3 docs/spec/taste/contracts/mutation_matrix.py
Exit code: 0 = every mutation caught and the positive control passes.
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

import gen_examples as gen

HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLES = os.path.join(HERE, "examples")
CHECK = os.path.join(HERE, "check.py")
SCHEMAS = ["taste-event.schema.json", "exposure.schema.json",
           "profile-statement.schema.json", "golden-fixture.schema.json"]


def make_run_root(parent):
    """A working checker root: check.py, the four schemas, and examples/."""
    root = tempfile.mkdtemp(prefix=parent)
    shutil.copy2(CHECK, os.path.join(root, "check.py"))
    for name in SCHEMAS:
        shutil.copy2(os.path.join(HERE, name), os.path.join(root, name))
    shutil.copytree(EXAMPLES, os.path.join(root, "examples"))
    return root


def load(path):
    with open(path) as f:
        return json.load(f)


def store(root, rel, doc):
    gen.write_canonical(os.path.join(root, rel), doc)


def ev(root, kind):
    return load(os.path.join(root, "examples/events", kind + ".json"))


def stmt(root, name):
    return load(os.path.join(root, "examples/profile-statement", name + ".json"))


def expo(root):
    return load(os.path.join(root, "examples/exposure/tonight-weeknight.json"))


def fix(root):
    return load(os.path.join(root, "examples/golden-fixture/coriander-v1.json"))


def patch_doc(doc, fn):
    d = copy.deepcopy(doc)
    fn(d)
    return d


# --- mutations -------------------------------------------------------------

CASES = []


def case(name, findings, mutate):
    CASES.append((name, findings, mutate))


# F1 per-kind payload validation
case("cooked-payload-missing-rating", ["F1"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].pop("rating"))))
case("cooked-payload-rating-out-of-range", ["F1"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("rating", 6))))
case("cooked-payload-unknown-field", ["F1"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("foo", 1))))
case("cooked-payload-rating-wrong-type", ["F1"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("rating", "2"))))
case("cooked-payload-slate-position-out-of-range", ["F1"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("slatePosition", 3))))
case("rated-payload-missing-cook-ref", ["F1"],
     lambda r: store(r, "examples/events/recipe_rated.json",
                     patch_doc(ev(r, "recipe_rated"), lambda d: d["payload"].pop("cookEventId"))))
case("rated-payload-rating-out-of-range", ["F1"],
     lambda r: store(r, "examples/events/recipe_rated.json",
                     patch_doc(ev(r, "recipe_rated"), lambda d: d["payload"].__setitem__("rating", 11))))
case("fixture-input-saved-unresolvable-exposure", ["F1"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"][4]["payload"]
                               .__setitem__("exposureId", "1a2b3c4d-9999-4a00-8b00-000000000099"))))
case("lechef-tag-not-in-enum", ["F1"],
     lambda r: store(r, "examples/events/lechef_feedback.json",
                     patch_doc(ev(r, "lechef_feedback"), lambda d: d["payload"].__setitem__("tag", "tastes_bad"))))
case("profile-edit-unknown-op", ["F1"],
     lambda r: store(r, "examples/events/profile_edited.json",
                     patch_doc(ev(r, "profile_edited"), lambda d: d["payload"].__setitem__("op", "unknown_op"))))
case("profile-edit-pin-magnitude-cap", ["F1"],
     lambda r: store(r, "examples/events/profile_edited.json",
                     patch_doc(ev(r, "profile_edited"), lambda d: d["payload"].__setitem__("pinnedValue", -9))))
case("profile-edit-unknown-feature-kind", ["F1"],
     lambda r: store(r, "examples/events/profile_edited.json",
                     patch_doc(ev(r, "profile_edited"), lambda d: d["payload"].__setitem__("featureKind", "stuff"))))
case("correction-unknown-action", ["F1"],
     lambda r: store(r, "examples/events/correction_applied.json",
                     patch_doc(ev(r, "correction_applied"), lambda d: d["payload"].__setitem__("action", "meh"))))

# F2 unsupported evidence events fail loudly
case("unknown-event-kind-in-fixture", ["F2"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"].append(
                         {"id": "2b3c4d5e-9999-4b00-9c00-000000009999",
                          "at": "2026-10-15T19:00:00Z", "kind": "recipe_shared",
                          "eater": "you", "recipe": {"source": "catalog", "id": "1", "revision": 1},
                          "ingredient": None, "surface": "recipe.detail", "payload": {}}))))

# F3/F4 clamp and hedged-rule semantics
case("ranking-clamp-entry-tampered", ["F3"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["ranking"][3].__setitem__("learnedContribution", -7.0))))
case("hedged-denominator-too-small", ["F4"],
     lambda r: store(r, "examples/profile-statement/inferred-hedged.json",
                     patch_doc(stmt(r, "inferred-hedged"), lambda d: d.__setitem__("denominator", 2))))
case("hedged-numerator-exceeds-denominator", ["F4"],
     lambda r: store(r, "examples/profile-statement/inferred-hedged.json",
                     patch_doc(stmt(r, "inferred-hedged"), lambda d: d.__setitem__("numerator", 4))))
case("confident-denominator-too-small", ["F4"],
     lambda r: store(r, "examples/profile-statement/inferred-mixed.json",
                     patch_doc(stmt(r, "inferred-mixed"), lambda d: d.__setitem__("denominator", 2))))
case("confident-ratio-below-minimum", ["F4"],
     lambda r: store(r, "examples/profile-statement/inferred-mixed.json",
                     patch_doc(stmt(r, "inferred-mixed"), lambda d: d.__setitem__("numerator", 1))))
case("restriction-must-not-carry-features", ["F4"],
     lambda r: store(r, "examples/profile-statement/restriction.json",
                     patch_doc(stmt(r, "restriction"), lambda d: d.__setitem__("featureKind", "ingredient"))))
case("restriction-empty-text", ["F4"],
     lambda r: store(r, "examples/profile-statement/restriction.json",
                     patch_doc(stmt(r, "restriction"), lambda d: d.__setitem__("text", ""))))
case("pinned-muted-requires-mute-window", ["F4"],
     lambda r: store(r, "examples/profile-statement/pinned-muted.json",
                     patch_doc(stmt(r, "pinned-muted"), lambda d: d.__setitem__("mutedUntil", None))))
case("pinned-empty-text", ["F4"],
     lambda r: store(r, "examples/profile-statement/pinned-muted.json",
                     patch_doc(stmt(r, "pinned-muted"), lambda d: d.__setitem__("text", ""))))

# F5 canonical serialization and F8 timestamp/float validation
case("event-malformed-timestamp", ["F8"],
     lambda r: store(r, "examples/events/recipe_viewed.json",
                     patch_doc(ev(r, "recipe_viewed"), lambda d: d.__setitem__("at", "2026-13-01T18:30:00Z"))))
case("event-timestamp-space-separator", ["F8"],
     lambda r: store(r, "examples/events/recipe_viewed.json",
                     patch_doc(ev(r, "recipe_viewed"), lambda d: d.__setitem__("at", "2026-10-12 18:30:00"))))
case("event-timestamp-wrong-utc-offset", ["F8"],
     lambda r: store(r, "examples/events/recipe_viewed.json",
                     patch_doc(ev(r, "recipe_viewed"), lambda d: d.__setitem__("at", "2026-10-12T18:30:00+00:01"))))
case("exposure-malformed-timestamp", ["F8"],
     lambda r: store(r, "examples/exposure/tonight-weeknight.json",
                     patch_doc(expo(r), lambda d: d.__setitem__("at", "2026-13-01T17:58:00Z"))))
case("exposure-subsecond-precision", ["F8"],
     lambda r: store(r, "examples/exposure/tonight-weeknight.json",
                     patch_doc(expo(r), lambda d: d.__setitem__("at", "2026-09-01T17:58:00.5Z"))))
def _dump_raw(root, rel, doc):
    with open(os.path.join(root, rel), "w") as f:
        json.dump(doc, f)


case("event-float-overprecision", ["F8"],
     lambda r: _dump_raw(r, "examples/events/ingredient_substituted.json",
                         patch_doc(ev(r, "ingredient_substituted"),
                                   lambda d: d["payload"].__setitem__("ratio", 1.0000001))))
case("event-float-servings", ["F8"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("servings", 2.5))))
case("event-int-rating-as-float", ["F8"],
     lambda r: store(r, "examples/events/recipe_cooked.json",
                     patch_doc(ev(r, "recipe_cooked"), lambda d: d["payload"].__setitem__("rating", 2.0))))
case("exposure-float-context", ["F8"],
     lambda r: store(r, "examples/exposure/tonight-weeknight.json",
                     patch_doc(expo(r), lambda d: d["context"].__setitem__("kitchenIngredientCount", 6.5))))
case("statement-float-pin", ["F8"],
     lambda r: store(r, "examples/profile-statement/pinned-muted.json",
                     patch_doc(stmt(r, "pinned-muted"), lambda d: d.__setitem__("pinnedValue", -8.25))))
case("fixture-float-rulescore", ["F8"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["catalog"]["recipes"][0].__setitem__("ruleScore", 63.25))))
def _dump_unsorted(root):
    path = os.path.join(root, "examples/events/recipe_viewed.json")
    with open(path) as f:
        doc = json.load(f)
    doc["id"] = "3c4d5e6f-1111-4c00-8d00-000000000002"
    with open(path, "w") as f:
        json.dump(dict(list(doc.items())[::-1]), f, indent=4)


case("fixture-noncanonical-keys", ["F5"], _dump_unsorted)
case("fixture-version-bumped", ["F5", "F6"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d.__setitem__("version", 3))))

# F6 schema/spec drift
case("event-schema-renamed", ["F6"],
     lambda r: os.rename(os.path.join(r, "taste-event.schema.json"),
                         os.path.join(r, "taste-event-v2.schema.json")))

# F7 household cap removed (a size-4 household must now validate)
case("exposure-large-household", [],  # positive expectation handled below
     lambda r: store(r, "examples/exposure/tonight-weeknight.json",
                     patch_doc(expo(r), lambda d: d["context"].__setitem__("householdSize", 4))))

# F9 tie-break exercised
case("ranking-order-flipped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["ranking"].insert(
                         0, d["expected"]["ranking"].pop(1)))))
case("fixture-state-alpha-tampered", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["featureState"][1].__setitem__("alpha", 0.5))))
case("fixture-state-beta-tampered", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["featureState"][1].__setitem__("beta", 1.1))))
case("hidden-statement-unhidden", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["hiddenStatements"].pop(0))))
case("fixture-input-event-dropped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"].pop(6))))
case("fixture-input-exposure-dropped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["exposures"].pop(4))))
case("fixture-input-rating-changed", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"][1]["payload"].__setitem__("rating", 3))))
case("fixture-input-unsorted", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"].reverse())))
case("fixture-input-payload-out-of-range", ["F1", "F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["events"][1]["payload"].__setitem__("slatePosition", 9))))
case("fixture-pin-value-changed", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["statements"][0].__setitem__("pinnedValue", -6.0))))
case("fixture-pin-statement-dropped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["input"]["statements"].pop(0))))
case("fixture-statement-dropped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["expected"]["profileStatements"].pop(0))))
case("fixture-recipe-dropped", ["F9"],
     lambda r: store(r, "examples/golden-fixture/coriander-v1.json",
                     patch_doc(fix(r), lambda d: d["catalog"]["recipes"].pop(1))))
case("example-file-deleted", ["F5"],
     lambda r: os.remove(os.path.join(r, "examples/events/recipe_viewed.json")))


def run(root):
    return subprocess.run([sys.executable, "check.py"], cwd=root,
                          capture_output=True, text=True)


def main():
    failures = []
    # Copy control FIRST: if an untouched working root does not pass, the
    # harness itself is broken (e.g. schemas not staged) and every later
    # "caught" verdict would be vacuous.
    control = make_run_root("mm-control-")
    try:
        res = run(control)
        if res.returncode != 0:
            print("mutation_matrix.py: copy control FAILED - harness is broken, results would be vacuous")
            print(res.stdout)
            print(res.stderr)
            return 1
    finally:
        shutil.rmtree(control, ignore_errors=True)
    print(f"copy control ok; running {len(CASES)} mutation cases + 2 controls")
    for name, findings, mutate in CASES:
        root = make_run_root("mm-")
        try:
            mutate(root)
            res = run(root)
            if name == "exposure-large-household":
                ok = res.returncode == 0
                verdict = "passes (F7 fix verified)" if ok else "REJECTED - F7 regression"
            else:
                ok = res.returncode != 0
                verdict = "caught" if ok else "NOT CAUGHT"
            if not ok:
                failures.append(name)
            print(f"  [{verdict:>28}] {name}  ({','.join(findings) or 'control'})")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    # positive control on the untouched tree
    res = subprocess.run([sys.executable, "check.py"], cwd=HERE, capture_output=True, text=True)
    ok = res.returncode == 0
    print(f"  [{'positive control ok':>28}] untouched examples tree ({res.stdout.strip().splitlines()[-1] if res.stdout else res.stderr.strip()})")
    if not ok:
        failures.append("positive-control")
    if failures:
        print(f"mutation_matrix.py: {len(failures)} case(s) not caught: {', '.join(failures)}")
        return 1
    print("mutation_matrix.py: all mutations caught, positive control passes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
