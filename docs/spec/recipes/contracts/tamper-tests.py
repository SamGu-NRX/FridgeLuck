#!/usr/bin/env python3
"""Adversarial tamper suite for the recipe contracts checker.

Copies the repo to a throwaway directory, applies one mutation per case, and
asserts that check.py exits nonzero (and, for one case, names the right entry
in its failure message). Run from anywhere:

    python3 docs/spec/recipes/contracts/tamper-tests.py
"""
import json, shutil, subprocess, sys, tempfile
from pathlib import Path

CONTRACTS = Path(__file__).resolve().parent
REPO = CONTRACTS.parents[3]


def run_case(name, mutate, expect_substr=None):
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        repo = tmp / "repo"
        shutil.copytree(REPO, repo, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        mutate(repo / "docs" / "spec" / "recipes" / "contracts")
        r = subprocess.run([sys.executable, str(repo / "docs/spec/recipes/contracts/check.py")],
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        caught = r.returncode != 0
        detail = ""
        if caught:
            fail_lines = [l for l in out.splitlines() if "FAIL" in l or "ERROR" in l]
            detail = (fail_lines[-1] if fail_lines else out.strip().splitlines()[-1])[:110]
        ok = caught and (expect_substr is None or expect_substr in out)
        label = "caught" if ok else ("MISSED" if not caught else "WRONG-MSG")
        print(f"{label:9} {name}")
        if detail:
            print(f"          {detail}")
        return ok


def edit(rel, fn):
    def apply(contracts):
        p = contracts / rel
        data = json.loads(p.read_text())
        fn(data)
        p.write_text(json.dumps(data, indent=2) + "\n")
    return apply


def find(events, **kw):
    return next(e for e in events if all(e.get(k) == v for k, v in kw.items()))


CASES = [
    ("bundle uses index out of range", edit("examples/bundle-v2.sample.json",
        lambda b: b["recipes"][0]["steps"][0]["uses"].__setitem__(0, 99))),
    ("bundle unknown fdc_id", edit("examples/bundle-v2.sample.json",
        lambda b: b["ingredients"][0].__setitem__("fdc_id", 999999))),
    ("identity fdc not in catalog", edit("examples/ingredient-identity-map.sample.json",
        lambda i: next(e for e in i["entries"] if e["status"] == "resolved").__setitem__("fdc_id", 123456))),
    ("identity missing entry", edit("examples/ingredient-identity-map.sample.json",
        lambda i: i["entries"].pop())),
    ("rating out of range", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="recipe_rated").__setitem__("rating", 9))),
    ("event unknown recipe", edit("examples/taste-events-v1.sample.json",
        lambda e: e[0].__setitem__("recipe_catalog_id", "rcp-999999"))),
    ("rated with null rating", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="recipe_rated").__setitem__("rating", None))),
    ("rated with missing rating", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="recipe_rated").pop("rating"))),
    ("rating on non-rated event", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="cook_started").__setitem__("rating", 4))),
    ("dismissed with null reason", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="suggestion_dismissed").__setitem__("dismiss_reason", None))),
    ("dismissed with missing reason", edit("examples/taste-events-v1.sample.json",
        lambda e: find(e, type="suggestion_dismissed").pop("dismiss_reason"))),
    ("computed coverage with null per-100g", edit("examples/bundle-v2.sample.json",
        lambda b: next(i for i in b["ingredients"] if i["key"] == "ginger").__setitem__("per_100g", None))),
    ("event revision beyond shipped", edit("examples/taste-events-v1.sample.json",
        lambda e: next(x for x in e if x["recipe_catalog_id"] != "rcp-000002").__setitem__("recipe_revision", 9))),
    ("rights status licensed", edit("examples/bundle-v2.sample.json",
        lambda b: b["recipes"][2]["rights"].__setitem__("status", "licensed"))),
    ("identity wrong fdc names right legacy id", edit("examples/ingredient-identity-map.sample.json",
        lambda i: next(e for e in i["entries"] if e["legacy_id"] == 8).__setitem__("fdc_id", 123456))),
]


def main():
    results = []
    for name, mut in CASES:
        expect = "legacy 8" if "right legacy id" in name else None
        results.append(run_case(name, mut, expect))
    n_ok = sum(results)
    print(f"\n{n_ok}/{len(CASES)} tamper cases caught")
    return 0 if n_ok == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
