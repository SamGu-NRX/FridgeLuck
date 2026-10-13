"""Fixture table renderer: group rows in, canonical TSV bytes out."""

from cellfmt import fmt_count, fmt_ratio

HEADER = ("food_group", "dishes", "kcal_total", "kcal_mean", "share_pct")


def render_table(rows: list) -> bytes:
    grand = sum(row["kcal_total"] for row in rows)
    lines = ["\t".join(HEADER)]
    for row in rows:
        lines.append(
            "\t".join(
                [
                    row["food_group"],
                    fmt_count(row["dishes"]),
                    fmt_count(row["kcal_total"]),
                    fmt_ratio(row["kcal_total"], row["dishes"]),
                    fmt_ratio(row["kcal_total"] * 100, grand),
                ]
            )
        )
    return ("\n".join(lines) + "\n").encode("utf-8")
# r2: comment added after the digest was pinned (simulated drift)
