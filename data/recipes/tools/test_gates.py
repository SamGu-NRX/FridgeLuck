"""Planted-failure tests for the corpus release gates.

Each test plants a recipe that the validator at 4b6e163 accepted and asserts
the gate now refuses it, plus a passing twin so a gate that refuses everything
also fails. The last class runs the gates over the committed corpus files.

    python3 -I -m unittest discover -s data/recipes/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import corpus_io  # noqa: E402
import rights_evidence  # noqa: E402
import validate_corpus  # noqa: E402

ORIGINAL_RECORD = {
    "source_id": "fl-original-9001",
    "source_type": "original",
    "origin": "FridgeLuck original expression authored for FridgeLuck (task fl-original-recipes-f1)",
    "license": "LicenseRef-FL-Original",
    "access_date": "2026-10-11",
    "license_evidence": ("data/recipes/originals/rights_manifest.json record fl-original-9001 "
                         "(branch overhaul/original-recipes at 607ef99); ingested after "
                         "re-verification"),
    "permissions": {"text": True, "images": False, "modification": True,
                    "attribution": True, "caching": True, "offline_use": True},
}


def recipe(rid: str = "fl-original-9001", title: str = "Planted Lentil Soup",
           ingredients: list | None = None, steps: list | None = None,
           claims: list | None = None) -> dict:
    return {
        "rs_version": "1", "id": rid, "title": title, "cuisine": "american",
        "meal_slots": ["dinner"], "minutes": 30, "servings": 2,
        "ingredients": ingredients or [{"name": "red lentils",
                                        "qty": {"kind": "unknown"}}],
        "steps": steps or [{"text": "Simmer the lentils in water until soft."}],
        "source_ref": rid,
        "claims": claims or [],
    }


class RightsGate(unittest.TestCase):
    """Finding 3: rights need affirmative evidence, not missing attribution."""

    # The seed record shape at 4b6e163 (fl-seed-0001), on a planted id.
    SEED_RECORD = {
        "source_id": "frideluck_original",
        "source_type": "original",
        "origin": ("FridgeLuck seed (bundled recipe id 1; in-house authorship traced "
                   "through git history to initial commit 69f0286)"),
        "license": "LicenseRef-FL-Original",
        "access_date": "2026-10-11",
        "license_evidence": ("data/recipes/RIGHTS-AUDIT.md keep verdict for bundled recipe "
                             "id 1: no Source line; in repo since 69f0286 (2026-02-08, "
                             "initial commit); title not in the BBC scrape cache"),
        "permissions": dict(ORIGINAL_RECORD["permissions"]),
    }

    def test_absence_only_seed_record_is_refused(self):
        r = recipe("fl-seed-9001")
        problems = rights_evidence.rights_violations(r, self.SEED_RECORD)
        self.assertTrue(any("missing attribution" in p for p in problems), problems)
        self.assertTrue(any("authoring task's record" in p for p in problems), problems)

    def test_validator_refuses_the_planted_seed(self):
        r = recipe("fl-seed-9001")
        errors = validate_corpus.release_gate_errors(
            [r], {"fl-seed-9001": self.SEED_RECORD}, {"recipes": []})
        self.assertTrue(errors)

    def test_original_with_its_authoring_record_passes(self):
        self.assertEqual(rights_evidence.rights_violations(recipe(), ORIGINAL_RECORD), [])

    def test_authoring_record_for_another_recipe_is_refused(self):
        r = recipe("fl-original-9002")
        problems = rights_evidence.rights_violations(r, ORIGINAL_RECORD)
        self.assertTrue(any("not fl-original-9002" in p for p in problems), problems)

    def test_unknown_source_type_is_refused(self):
        rec = dict(ORIGINAL_RECORD, source_type="community")
        problems = rights_evidence.rights_violations(recipe(), rec)
        self.assertTrue(any("no affirmative-evidence form" in p for p in problems), problems)

    def test_open_licence_needs_licence_and_page_urls(self):
        rec = dict(ORIGINAL_RECORD, source_type="government", license="OGL-3.0",
                   license_evidence="OGL v3.0 per SOURCES.md")
        self.assertTrue(rights_evidence.rights_violations(recipe(), rec))
        rec["license_evidence"] = ("OGL v3.0 at https://www.nhs.uk/our-policies/terms-and-"
                                   "conditions/; page https://www.nhs.uk/healthier-families/x/")
        self.assertEqual(rights_evidence.rights_violations(recipe(), rec), [])

    def test_original_that_copies_bundled_wording_is_refused(self):
        source = ("Heat the oven to 200C and toss the bread with two tablespoons of the "
                  "olive oil and season well before baking")
        ref = rights_evidence.reference_ngrams([source])
        copied = recipe(steps=[{"text": "First, " + source.lower() + "."}])
        self.assertIsNotNone(rights_evidence.overlap_violation(copied, ref))
        fresh = recipe(steps=[{"text": "Crisp torn bread in a hot oven with oil and salt."}])
        self.assertIsNone(rights_evidence.overlap_violation(fresh, ref))

    def test_quarantined_recipe_left_in_the_corpus_is_refused(self):
        r = recipe("fl-seed-9001")
        entry = {"id": "fl-seed-9001", "stage": "rights", "reason": "planted",
                 "recipe": r}
        errors = validate_corpus.quarantine_errors([r], {}, [entry])
        self.assertTrue(any("still in corpus.jsonl" in e for e in errors), errors)
        errors = validate_corpus.quarantine_errors([], {}, [dict(entry, reason="")])
        self.assertTrue(any("needs a stage and a reason" in e for e in errors), errors)


class CommittedCorpus(unittest.TestCase):
    """The committed corpus passes every gate."""

    @classmethod
    def setUpClass(cls):
        cls.recipes = [l.obj for l in corpus_io.read_jsonl(corpus_io.CORPUS)]
        cls.records = corpus_io.read_manifest()["records"]
        cls.quarantine = [l.obj for l in corpus_io.read_jsonl(corpus_io.QUARANTINE)]
        cls.bundled = json.loads(validate_corpus.BUNDLED.read_text(encoding="utf-8"))

    def test_release_gates(self):
        errors = validate_corpus.release_gate_errors(
            copy.deepcopy(self.recipes), self.records, self.bundled)
        self.assertEqual(errors, [], "\n".join(errors[:20]))

    def test_quarantine_file(self):
        errors = validate_corpus.quarantine_errors(self.recipes, self.records, self.quarantine)
        self.assertEqual(errors, [], "\n".join(errors[:20]))


if __name__ == "__main__":
    unittest.main()
