"""Resolve the referenced food-safety rulebook, or fail closed.

Cards cite rulebook rules by id inside storage.foodSafetyRef. A reference to
a rule that cannot be loaded backs nothing, so every tool that emits or
validates such references must fail closed when the rulebook is unavailable:
the build emits no advice, and validation reports a failure instead of
passing.

Search order:
  1. in-tree data/food-safety/rules.json (the joined tree once PR #97 lands)
  2. `git show origin/overhaul/food-safety-rules:data/food-safety/rules.json`
     (the reviewed PR #97 branch, so validation works before the join)
"""
import json
import os
import subprocess

RULEBOOK_PATH = "data/food-safety/rules.json"
REVIEWED_REF = "origin/overhaul/food-safety-rules"  # PR #97
# From the learn-cards dir (data/kitchen-knowledge/learn-cards) the in-tree
# rulebook sits two levels up: data/food-safety/rules.json.
IN_TREE_REL = os.path.join("..", "..", "food-safety", "rules.json")


class Unresolvable(Exception):
    """The referenced rulebook cannot be loaded from tree or reviewed branch."""


def load(learn_cards_root):
    """Return (rulebook_dict, source_description).

    Raises Unresolvable when neither source resolves; callers must treat that
    as a hard failure, never as an empty rule set.
    """
    in_tree = os.path.abspath(os.path.join(learn_cards_root, IN_TREE_REL))
    if os.path.exists(in_tree):
        with open(in_tree, encoding="utf-8") as f:
            return json.load(f), f"in-tree {RULEBOOK_PATH}"
    out = subprocess.run(
        ["git", "show", f"{REVIEWED_REF}:{RULEBOOK_PATH}"],
        cwd=os.path.dirname(learn_cards_root), capture_output=True, text=True)
    if out.returncode != 0:
        raise Unresolvable(
            f"referenced safety rulebook is unresolvable: in-tree "
            f"{RULEBOOK_PATH} is absent and `git show {REVIEWED_REF}` failed "
            f"({(out.stderr or '').strip()[:120]}) — fail closed: no storage "
            "advice may cite a rule that cannot be loaded")
    try:
        return json.loads(out.stdout), f"git show {REVIEWED_REF}:{RULEBOOK_PATH}"
    except json.JSONDecodeError as e:
        raise Unresolvable(
            f"referenced safety rulebook ({REVIEWED_REF}:{RULEBOOK_PATH}) is "
            f"not valid JSON: {e} — fail closed")


def rule_ids(rulebook):
    """The set of rule ids the loaded rulebook actually defines."""
    return {r.get("id") for r in (rulebook.get("rules") or []) if isinstance(r, dict)}
