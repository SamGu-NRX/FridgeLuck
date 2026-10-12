"""Derive Part 1 harness session scripts from the pinned corpus.

The corpus of record is the pinned session schema documented in
sessions/README.md (id/scenario/events/expected, role "model",
replayNote annotations). The Part 1 harness (backend/gemini-agent
src/lechef, merged from overhaul/lechef-f1) consumes a different,
also-pinned shape (fakeModel.ts SessionScript: design required, role
"assistant", userActions, fixture). This converter is the mechanical
bridge: it never invents content, it re-encodes the corpus one-to-one.

Mappings and decisions (each documented in sessions/README.md):

- role "model" -> "assistant"; turn i = the turn's index in the corpus
  file (the scorer pairs replayNotes and records on these indices).
- events -> userActions. kill-app becomes kill, then a clock advance
  across the dead interval that crosses every timer deadline, then
  resume: the device owns absolute deadlines and the resume fires each
  timer at its original deadline, so firedAt == deadline and
  survivedKill are both real facts of the run. offline becomes clock
  advances realizing the scripted offsets WITHOUT goOffline(): the
  harness's phone-offline axis (PhoneOfflineError) models an
  unreachable phone, while the corpus's offline sessions model
  recognition loss with a working local phone -- a different axis the
  harness does not express (documented limitation).
- cameraLook -> requestCameraLook (the runtime's registry name); the
  canned camera fixture is empty observations, which is honest: the
  corpus scripts the look request, not what the camera sees.
- checkFoodSafety arg target -> product (the runtime's arg name).
- Timers, step advances and notes are marked userInitiated: every
  action in this corpus follows a direct user command (or a spoken
  "Save it." approval -- the scripted approval turns stay in the
  corpus for the scorer). Under the joined layer userInitiated is
  device-derived: dictated timers run device-auto and execute at
  submit, so they take no approve action. Every other explicit
  proposal executes only where the session DECLARES consent -- the
  next user turn after the proposal must carry a `consents` list
  naming the call id (a `refusals` list rejects; no declaration --
  silence, a bare "Ok." filler, or no user turn at all -- leaves the
  proposal unanswered on the phone). Approvals sort before same-turn
  device actions so a proposal never sits pending across a kill's
  clock jump (it would pass its TTL and expire unexecuted).
- proposeMealLog / proposeInventoryCorrection are the runtime's plan
- and swap/adaptation application forms; the corpus scripts them directly
  Part 1 runtime's dispatch registry has no such tools yet, so they
  come back status "error" ("unknown tool") and the scorer records the
  gap honestly. No approve/reject actions are emitted for them: the
  replay fails loudly on approvals for calls that never produced a
  proposal.
- design: "unset" -- suite D replays plain runSession, design-agnostic
  (parent steering on the design-contract integration).

Usage: python3 to_harness.py --out <dir>   (default: ../out/harness-scripts)
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

# The corpus's deterministic clock base: generate.py ts() offsets are
# epoch seconds from this instant.
EPOCH_BASE = 1_800_000_000

# Direct-command tools in this corpus: the user asks for each of these
# out loud. device-auto applies to timers; step advances and notes are
# explicit and get a scripted approve action.
USER_COMMAND_TOOLS = frozenset({
    "proposeMealLog", "proposeInventoryCorrection",
    "proposeTimerStart", "proposeTimerAdjust", "proposeStepAdvance",
    "proposeSaveNote",
})
# Explicit-approval tools need a scripted userApproves to execute. Under
# plain replayScript the harness dispatches every call without the
# script's userInitiated flag, so ALL proposals come back explicit --
# timers included -- and each needs one scripted approve.
EXPLICIT_TOOLS = frozenset({
    "proposeMealLog", "proposeInventoryCorrection",
    "proposeTimerStart", "proposeTimerAdjust", "proposeStepAdvance",
    "proposeSaveNote",
})

READ_TOOL_RENAMES = {"cameraLook": "requestCameraLook"}

# Timer tools are device-auto when dictated (a valid device event backs
# them), so they never take a scripted approve/reject action.
TIMER_TOOLS = frozenset({"proposeTimerStart", "proposeTimerAdjust"})

# Action ordering within one afterTurn: approvals before device actions
# so a proposal never waits across a kill's clock jump.
ORDER_APPROVE, ORDER_REJECT = -1, -1
ORDER_KILL, ORDER_KILL_ADVANCE, ORDER_RESUME = 0, 1, 2
ORDER_OFFLINE_ADVANCE, ORDER_RECONNECT_ADVANCE = 3, 4
ORDER_FINAL_ADVANCE = 5


def iso(epoch_seconds: float) -> str:
    """Corpus epoch seconds -> the record's ISO format (Date.toISOString)."""
    return datetime.fromtimestamp(epoch_seconds, tz=timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z")


def convert(session: dict) -> dict:
    turns = session["turns"]
    events = session["events"]

    # --- tool calls: renames, arg names, userInitiated -----------------
    conv_calls: list[list[dict]] = []
    for turn in turns:
        out = []
        for c in turn["toolCalls"]:
            name = READ_TOOL_RENAMES.get(c["name"], c["name"])
            args = dict(c["args"])
            if c["name"] == "checkFoodSafety" and "target" in args:
                args["product"] = args.pop("target")
            if name in TIMER_TOOLS:
                # Dictated timers: the marker must sit in ARGS. The session
                # player's prepareDictatedCall reads args.userInitiated,
                # records the user command as a phone device event at the
                # current revision, and injects the deviceEventId citation
                # the runtime accepts; a bare call-level flag is script
                # material only and never authorizes anything (SPEC 4).
                args["userInitiated"] = True
            out.append({
                "id": c["id"], "name": name, "args": args,
                "userInitiated": name in USER_COMMAND_TOOLS,
            })
        conv_calls.append(out)

    # --- user actions ----------------------------------------------------
    actions: list[tuple[int, dict, int]] = []  # (afterTurn, action, order)
    planned_advance = 0.0  # cumulative minutes the plan will already advance

    def plan_advance(after: int, minutes: float, order: int) -> None:
        nonlocal planned_advance
        actions.append((after, {"kind": "advanceMinutes", "minutes": round(minutes, 3)}, order))
        planned_advance += minutes

    timer_minutes = [c["args"]["minutes"]
                     for calls in conv_calls for c in calls
                     if c["name"] == "proposeTimerStart"]

    # Kill sessions: the bare "..." user turn marks the kill moment.
    kill_index = next((ti for ti, t in enumerate(turns)
                       if t["role"] == "user" and t.get("text") == "\u2026"), None)
    if kill_index is not None:
        gap = (max(timer_minutes) + 1.0) if timer_minutes else 5.0
        actions.append((kill_index, {"kind": "kill"}, ORDER_KILL))
        plan_advance(kill_index, gap, ORDER_KILL_ADVANCE)
        actions.append((kill_index, {"kind": "resume"}, ORDER_RESUME))

    # Offline sessions: realize the scripted offline->reconnect clock
    # offsets. The advance to the offline offset happens BEFORE the turn
    # noted "offline" so its proposal is filed inside the window with its
    # full TTL ahead of it; the reconnect gap advances after the turn
    # that follows the approval.
    offline_noted = [ti for ti, t in enumerate(turns) if t.get("replayNote") == "offline"]
    if offline_noted and events:
        offs = sorted(float(e["at"]) for e in events if e["kind"] == "offline")
        res = sorted(float(e["at"]) for e in events if e["kind"] == "reconnect")
        # The offline window opens at the scripted offset: the clock reaches
        # it before the FIRST offline-noted turn, so every proposal filed
        # inside the window (and its scripted approval) executes in-window.
        # The reconnect jump comes after the last one plus its approval turn.
        anchor_first, anchor_last = offline_noted[0], offline_noted[-1]
        if offs:
            # scripted `at` values are absolute corpus epochs (EPOCH_BASE +
            # offset); the advance moves by the offset alone
            plan_advance(max(0, anchor_first - 1),
                         round((offs[0] - EPOCH_BASE) / 60, 3),
                         ORDER_OFFLINE_ADVANCE)
        if res and offs:
            plan_advance(min(anchor_last + 1, len(turns) - 1),
                         round((res[0] - offs[0]) / 60, 3), ORDER_RECONNECT_ADVANCE)

    # Explicit proposals execute only where the session DECLARES the
    # consent (review fix S3): the next user turn after the model turn
    # must carry a `consents` list naming the call id -- the converter
    # carries real consent events only, never an inferred one. A
    # `refusals` list emits a reject; a turn with neither declaration
    # (silence, a bare "Ok." filler) or no user turn at all leaves the
    # proposal unanswered on the phone. Cancelled calls never produce a
    # proposal, and same-turn duplicate calls dedupe to ONE proposal --
    # the first of each group is the one the declarations name.
    # Dictated timers are device-auto under the joined layer (they
    # execute at submit against a valid device event) and take no
    # approve/reject action.
    for ti, (turn, calls) in enumerate(zip(turns, conv_calls)):
        cancelled = set(turn.get("cancelledToolCallIds", []))
        seen_payloads: list[str] = []
        pending: list[dict] = []
        for c in calls:
            if c["id"] in cancelled or c["name"] not in EXPLICIT_TOOLS:
                continue
            key = json.dumps(c["args"], sort_keys=True)
            if key in seen_payloads:
                continue
            seen_payloads.append(key)
            pending.append(c)
        pending = [c for c in pending
                   if not (c["userInitiated"] and c["name"] in TIMER_TOOLS)]
        if not pending:
            continue
        following_j = next((j for j in range(ti + 1, len(turns))
                            if turns[j]["role"] == "user"
                            and turns[j].get("replayNote") != "oov"), None)
        if following_j is None:
            continue  # unanswered: no user turn that can act follows
        following = turns[following_j]
        consents = set(following.get("consents", []))
        refusals = set(following.get("refusals", []))
        for c in pending:
            if c["id"] in consents:
                actions.append((following_j, {"kind": "approve", "callId": c["id"]},
                                ORDER_APPROVE))
            elif c["id"] in refusals:
                actions.append((following_j, {"kind": "reject", "callId": c["id"]},
                                ORDER_REJECT))

    # Every timer must fire at its deadline: without a kill, nothing else
    # moves the clock, so a final advance carries it past the last
    # deadline (minus whatever the offline plan already advanced).
    if timer_minutes:
        remaining = max(timer_minutes) + 1.0 - planned_advance
        if remaining > 0:
            plan_advance(len(turns) - 1, remaining, ORDER_FINAL_ADVANCE)

    actions.sort(key=lambda a: (a[0], a[2]))

    # --- fixture: the scripted world --------------------------------------
    scenario = session["scenario"]
    recipe = scenario["recipe"]
    fixture: dict = {
        "nowIso": iso(EPOCH_BASE),
        "pantry": scenario["pantry"]["items"],
        "session": {
            "recipeId": recipe["id"], "state": "cooking", "currentStepIndex": 0,
            "eaters": scenario["eaters"], "cameraMode": session["cameraMode"],
        },
        "recipes": [{
            "id": recipe["id"], "revision": recipe["revision"],
            "servings": recipe["servings"],
            "ingredientBill": [
                {"ingredientId": i["ingredientId"], "name": i["name"],
                 "quantity": {"kind": "known", "value": i["quantity"]["value"],
                              "unit": i["quantity"]["unit"]}}
                for i in recipe["ingredients"]
            ],
            "steps": [dict(s) for s in recipe["steps"]],
        }],
    }
    if any(c["name"] == "requestCameraLook" for calls in conv_calls for c in calls):
        fixture["camera"] = {"framesPerLook": 1, "clipSeconds": 2,
                             "observed": [], "cannotAssess": []}

    # --- turns -------------------------------------------------------------
    out_turns = []
    for ti, turn in enumerate(turns):
        t: dict = {"i": ti,
                   "role": "assistant" if turn["role"] == "model" else "user",
                   "text": turn.get("text", "")}
        if conv_calls[ti]:
            t["toolCalls"] = conv_calls[ti]
        if turn.get("cancelledToolCallIds"):
            t["cancelled"] = list(turn["cancelledToolCallIds"])
        out_turns.append(t)

    out: dict = {
        "sessionId": session["id"], "job": session["job"],
        "cameraMode": session["cameraMode"], "design": "unset",
        "fixture": fixture, "turns": out_turns,
    }
    if actions:
        out["userActions"] = [{"afterTurn": a, "action": act} for a, act, _ in actions]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Derive harness scripts from the pinned corpus")
    ap.add_argument("--out", default=str(HERE.parent / "out" / "harness-scripts"))
    ap.add_argument("--sessions", default=str(HERE))
    args = ap.parse_args()

    out_root = Path(args.out)
    count = 0
    for job_dir in sorted(Path(args.sessions).glob("*/")):
        if not job_dir.is_dir() or job_dir.name.startswith((".", "out")):
            continue
        for path in sorted(job_dir.glob("D-*.json")):
            session = json.loads(path.read_text())
            target = out_root / job_dir.name / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(convert(session), indent=1) + "\n")
            count += 1
    print(f"derived {count} harness scripts under {out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
