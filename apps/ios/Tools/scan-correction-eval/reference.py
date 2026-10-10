#!/usr/bin/env python3
"""Hand-computed reference model of the current production correction policy.

This mirrors LearningService semantics exactly, written as plain explicit
arithmetic (no cleverness, no reuse of production code):

  key            label.trimmed().lowercased()
  storage        rows keyed (vision_label, corrected_ingredient_id) with
                 correction_count starting at 1, +1 per repeat, and
                 last_used_at = CURRENT_TIMESTAMP of the recording event
  cache/decision argmax over rows of the label by
                 (count, last_used_at, rowid) descending
  auto-correct   argmax row exists and its count >= 2
  suggest        argmax row exists (no threshold)
  restart        state rebuilt from the row table; production loadCache walks
                 rows ORDER BY count DESC, last_used_at DESC, rowid DESC and
                 keeps the first row per label, which equals the same argmax
  timestamps     SQLite CURRENT_TIMESTAMP has 1-second precision and is UTC;
                 events here are >= 1s apart so each feedback has a distinct
                 timestamp and the simulation is exact.

Used by check_histories.py (expected decisions) and by the SwiftReplay
cross-check (tool replica of the current policy must match the real
LearningService 100%).
"""

from __future__ import annotations

from dataclasses import dataclass, field

AUTO_THRESHOLD = 2


def normalized_label(label: str) -> str:
    return label.strip().lower()


@dataclass
class Row:
    product: int
    count: int
    last_used_at: int
    rowid: int


@dataclass
class CurrentPolicy:
    """Explicit model of LearningService. Timestamps are event times in
    seconds; rowids increment over the whole table like SQLite's."""

    rows: dict = field(default_factory=dict)  # norm_label -> {product: Row}
    _next_rowid: int = 1

    def record(self, label: str, product: int, ts: int) -> None:
        key = normalized_label(label)
        bucket = self.rows.setdefault(key, {})
        row = bucket.get(product)
        if row is None:
            bucket[product] = Row(product, 1, ts, self._next_rowid)
            self._next_rowid += 1
        else:
            row.count += 1
            row.last_used_at = ts

    def _argmax(self, label: str):
        bucket = self.rows.get(normalized_label(label))
        if not bucket:
            return None
        return max(bucket.values(), key=lambda r: (r.count, r.last_used_at, r.rowid))

    def auto(self, label: str) -> int | None:
        top = self._argmax(label)
        if top is None or top.count < AUTO_THRESHOLD:
            return None
        return top.product

    def suggested(self, label: str) -> int | None:
        top = self._argmax(label)
        return None if top is None else top.product

    # Restart: rebuild from the row table. Equivalent to production's
    # ORDER BY count DESC, last_used_at DESC, rowid DESC first-wins walk.
    def restarted(self) -> "CurrentPolicy":
        fresh = CurrentPolicy()
        ranked = []
        for key, bucket in self.rows.items():
            for row in bucket.values():
                ranked.append((key, row))
        ranked.sort(key=lambda kr: (-kr[1].count, -kr[1].last_used_at, -kr[1].rowid))
        fresh._next_rowid = self._next_rowid
        for key, row in ranked:
            fresh.rows.setdefault(key, {})[row.product] = Row(
                row.product, row.count, row.last_used_at, row.rowid
            )
        return fresh


def replay_history(history: dict, policy: CurrentPolicy | None = None) -> list[dict]:
    """Run one history through the policy, returning one record per scan:
    {i, truth, label, decision} where decision is the auto-corrected product
    or None (abstain). Restarts rebuild the in-memory cache; delays only
    advance the clock (timestamps on events are already absolute)."""
    policy = policy or CurrentPolicy()
    records = []
    for event in history["events"]:
        etype = event["type"]
        if etype == "scan":
            records.append(
                {
                    "i": event["i"],
                    "t": event["t"],
                    "truth": event["truth"],
                    "label": event["label"],
                    "decision": policy.auto(event["label"]),
                }
            )
        elif etype == "feedback":
            policy.record(event.get("label", history["focal"]), event["product"], event["t"])
        elif etype == "restart":
            policy = policy.restarted()
        elif etype == "delay":
            pass
        else:  # pragma: no cover
            raise ValueError(f"unknown event type {etype}")
    return records


def summarize(records: list[dict], products: dict | None = None) -> dict:
    wrong = sum(1 for r in records if r["decision"] is not None and r["decision"] != r["truth"])
    correct = sum(1 for r in records if r["decision"] == r["truth"])
    abstain = sum(1 for r in records if r["decision"] is None)
    return {"scans": len(records), "wrong_auto": wrong, "correct_auto": correct, "abstained": abstain}
