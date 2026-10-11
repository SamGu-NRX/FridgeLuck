"""Static entry-point audit for suite G (journeys) — runs on any host.

SUPPORTING EVIDENCE ONLY. For each of the nine PLAN journeys it searches the
committed SwiftUI source for at least one discoverable affordance that could
serve as the journey's entry point (button labels, navigation titles,
ShareLink, accessibility labels). A journey with no discoverable affordance
is reported MISSING — on the current base that is expected for share,
challenge and taste-profile edit, and it is a real finding: the plan requires
those journeys to be runnable.

It cannot verify that a journey is completable end to end (that needs the
simulator, i.e. the macOS arm); the interval widens when source files cannot
be read, so a broken scan can never look clean.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# Per journey: affordance patterns that would let a user start it. Regexes
# match against raw Swift source lines (Text("..."), Button("..."),
# navigationTitle("..."), accessibilityLabel("..."), ShareLink).
ENTRY_PATTERNS: dict[str, tuple[str, ...]] = {
    "first-run": (r"Onboarding|Welcome|firstRun",),
    "scan-and-review": (r"Scan options|ScanIngredients|IngredientReview|scan",),
    "tonight": (r"HomeDashboard|recommendation|Tonight",),
    "recipe": (r"RecipeResults|RecipeDetail|BEST MATCH|Recipes",),
    "cook": (r"LeChef|LiveAssistant|Cook",),
    "complete": (r"Meal Complete|MealFinalization|Log Meal",),
    "share": (r"ShareLink|share|Share",),
    "challenge": (r"[Cc]hallenge",),
    "taste-profile-edit": (r"[Tt]aste|Dietary|Preferences",),
}


def run_static_entry_audit(repo_root: Path) -> dict[str, Any]:
    definitions_path = Path(__file__).resolve().parent.parent / "journeys.json"
    if not definitions_path.is_file():
        return {"present": False, "reason": f"{definitions_path} not found"}
    definitions = json.loads(definitions_path.read_text())

    app_dir = repo_root / "apps" / "ios"
    corpus: list[tuple[str, str]] = []
    unread: list[str] = []
    for swift in sorted(app_dir.rglob("*.swift")):
        try:
            corpus.append((str(swift.relative_to(repo_root)), swift.read_text()))
        except OSError as exc:
            unread.append(f"{swift}: {exc}")

    journeys_out: list[dict[str, Any]] = []
    for journey in definitions["journeys"]:
        jid = journey["id"]
        hits: list[dict[str, str]] = []
        for pattern in ENTRY_PATTERNS.get(jid, ()):
            rx = re.compile(pattern)
            for rel, text in corpus:
                for lineno, line in enumerate(text.splitlines(), start=1):
                    if rx.search(line) and ("Text(" in line or "Button(" in line
                                             or "navigationTitle" in line
                                             or "accessibilityLabel" in line
                                             or "ShareLink" in line
                                             or "struct " in line):
                        hits.append({"file": rel, "line": lineno,
                                     "source": line.strip()[:110], "pattern": pattern})
                        if len(hits) >= 3:
                            break
                if len(hits) >= 3:
                    break
            if len(hits) >= 3:
                break
        journeys_out.append({
            "id": jid,
            "entry_found": bool(hits),
            "hits": hits[:3],
        })

    found = sum(1 for j in journeys_out if j["entry_found"])
    total = len(journeys_out)
    return {
        "present": True,
        "journeys": journeys_out,
        "found": found,
        "total": total,
        "unread_files": unread,
        "interval": [found, found + len(unread)],
        "missing_ids": [j["id"] for j in journeys_out if not j["entry_found"]],
    }
