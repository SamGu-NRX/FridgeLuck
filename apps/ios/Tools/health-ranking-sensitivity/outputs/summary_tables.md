Profiles: P1 | P2 | P3 | P4 | P5 · recipes: 62 · seed: 20261010 · base: 8c9c88f

## Full-run aggregates (engine-recorded, verified where windowed)

Plausible arms (within the locked uncertainty bounds):

| arm | profile | rank-moving draws | rank moves | rating flips | reasoning changes | interval overlaps |
|---|---|---|---|---|---|---|
| plausible_macros | P1 | 400/400 | 21594 | 6272 | 11901 | 1556/1891 |
| plausible_macros | P2 | 400/400 | 22486 | 6665 | 11824 | 1571/1891 |
| plausible_macros | P3 | 400/400 | 21419 | 4288 | 11838 | 1220/1891 |
| plausible_macros | P4 | 400/400 | 21834 | 6514 | 11882 | 1649/1891 |
| plausible_macros | P5 | 400/400 | 14628 | 595 | 11965 | 1350/1891 |
| plausible_portion | P1 | 400/400 | 19249 | 4426 | 4843 | 1251/1891 |
| plausible_portion | P2 | 400/400 | 19626 | 2984 | 4817 | 1128/1891 |
| plausible_portion | P3 | 400/400 | 19472 | 2420 | 4786 | 611/1891 |
| plausible_portion | P4 | 400/400 | 18979 | 2755 | 4725 | 1235/1891 |
| plausible_portion | P5 | 394/400 | 12787 | 514 | 4770 | 1233/1891 |
| plausible_both | P1 | 400/400 | 21986 | 7083 | 12065 | 1694/1891 |
| plausible_both | P2 | 400/400 | 22881 | 7585 | 12143 | 1782/1891 |
| plausible_both | P3 | 400/400 | 21643 | 5265 | 12228 | 1622/1891 |
| plausible_both | P4 | 400/400 | 22257 | 6894 | 12208 | 1730/1891 |
| plausible_both | P5 | 400/400 | 15754 | 639 | 12067 | 1493/1891 |

Stress arms (adversarial, OUTSIDE plausible uncertainty — separately labeled, never mixed):

| arm | profile | rank-moving draws | rank moves | rating flips | reasoning changes | interval overlaps |
|---|---|---|---|---|---|---|
| stress_macros | P1 | 200/200 | 11717 | 6363 | 7496 | 1800/1891 |
| stress_macros | P2 | 200/200 | 11676 | 6748 | 7506 | 1813/1891 |
| stress_macros | P3 | 200/200 | 11626 | 5495 | 7459 | 1781/1891 |
| stress_macros | P4 | 200/200 | 11824 | 5911 | 7457 | 1810/1891 |
| stress_macros | P5 | 200/200 | 10973 | 984 | 7495 | 1710/1891 |
| stress_portion | P1 | 200/200 | 11671 | 6075 | 5236 | 1765/1891 |
| stress_portion | P2 | 200/200 | 11680 | 6523 | 5184 | 1826/1891 |
| stress_portion | P3 | 200/200 | 11587 | 4473 | 5225 | 1727/1891 |
| stress_portion | P4 | 200/200 | 11798 | 4408 | 5170 | 1762/1891 |
| stress_portion | P5 | 200/200 | 10838 | 571 | 5221 | 1566/1891 |
| stress_both | P1 | 200/200 | 11658 | 7984 | 8787 | 1828/1891 |
| stress_both | P2 | 200/200 | 11697 | 7886 | 8849 | 1830/1891 |
| stress_both | P3 | 200/200 | 11709 | 6549 | 8730 | 1829/1891 |
| stress_both | P4 | 200/200 | 11631 | 7086 | 8814 | 1829/1891 |
| stress_both | P5 | 200/200 | 11511 | 1801 | 8866 | 1776/1891 |

## Headline instability numbers (plausible arms)

- Rank moved in 394-400 of 400 draws for every plausible arm-profile cell — at least one recipe changes position in essentially every plausible draw.
- Joint plausible arm: 1493-1782 of 1891 recipe pairs have overlapping plausible score intervals (rank order between them is not determined by the data).
- Window recomputation from committed raw samples: PASS (exact equality with engine summaries)
- Control bit-exactness: 310 records re-derived from the frozen matrix reproduce the committed control output exactly.

## Hand-verified rank swap (production formulas)

- Pair: R06 (control rank 33, score 113.5) vs R38 (control rank 34, score 112.5), profile P1.
- Under the committed plausible perturbation of draw 0, R38 gains +4.0 points by crossing the 24 g protein ranking threshold (23.9 g -> 27.40 g) and its order flips. Hand arithmetic in hand_swap.md; machine-verified by score.py.
- The same pair flips in raw-sample draws: 0, 2, 5, 8, 9.

## Label-service defect reproducer (documented, NOT fixed)

Ranking grants the high-protein bonus on absolute grams (protein >= 24 g or the `high_protein` tag) while reasoning strings use calorie-share bands (protein kcal share > 30%/25%). The two disagree on the same input:

| profile | bonus w/o reasoning note | reasoning note w/o bonus |
|---|---|---|
| P1 | 45/62 | 1/62 |
| P2 | 45/62 | 1/62 |
| P3 | 45/62 | 1/62 |
| P4 | 45/62 | 1/62 |
| P5 | 45/62 | 1/62 |

Failing-input example R07 (P1 control): ranking_reasons includes 'High protein', reasoning is 'Hearty portion' with no protein note. Reproduce: re-derive the P1 control and inspect R07, or run `python3 score.py --verify-report` which asserts this example.

## Boundary flips with point impact (plausible_both, full run)

| indicator | profile | flips | points per flip |
|---|---|---|---|
| reasoning_protein_band none->good | P1 | 5532 | no ranking points |
| calorie_bucket 30->20 | P1 | 3134 | -10 |
| reasoning_protein_band good->high | P1 | 2532 | no ranking points |
| calorie_bucket 30->15 | P1 | 1001 | -15 |
| sugar_bonus on->off | P1 | 998 | -10 |
| ranking_high_protein on->off | P1 | 997 | -4 |
| reasoning_cal_band hearty->mid | P1 | 984 | no ranking points |
| reasoning_protein_band high->good | P1 | 890 | no ranking points |
| reasoning_cal_band mid->hearty | P1 | 792 | no ranking points |
| calorie_bucket 15->30 | P1 | 788 | +15 |
| calorie_bucket 20->5 | P1 | 692 | -15 |
| calorie_bucket 20->30 | P1 | 670 | +10 |
| calorie_bucket 15->5 | P1 | 640 | -10 |
| reasoning_cal_band light->mid | P1 | 622 | no ranking points |
| ranking_high_protein off->on | P1 | 555 | +4 |
| reasoning_protein_band good->none | P1 | 475 | no ranking points |
| reasoning_protein_band none->high | P1 | 474 | no ranking points |
| calorie_bucket 5->15 | P1 | 393 | +10 |
| fiber_bonus on->off | P1 | 369 | -10 |
| sodium_bonus on->off | P1 | 358 | -10 |
| reasoning_cal_band mid->light | P1 | 267 | no ranking points |
| sugar_bonus off->on | P1 | 255 | +10 |
| sodium_bonus off->on | P1 | 202 | +10 |
| fiber_bonus off->on | P1 | 190 | +10 |
| calorie_bucket 5->20 | P1 | 176 | +15 |
| reasoning_protein_band high->none | P1 | 52 | no ranking points |
| calorie_bucket 5->30 | P1 | 7 | +25 |
| reasoning_protein_band none->good | P2 | 5547 | no ranking points |
| goal_band on->off | P2 | 3159 | goal-dependent |
| reasoning_protein_band good->high | P2 | 2585 | no ranking points |
| calorie_bucket 30->15 | P2 | 1537 | -15 |
| calorie_bucket 15->30 | P2 | 1206 | +15 |
| reasoning_cal_band hearty->mid | P2 | 1022 | no ranking points |
| calorie_bucket 15->5 | P2 | 1003 | -10 |
| ranking_high_protein on->off | P2 | 990 | -4 |
| sugar_bonus on->off | P2 | 981 | -10 |
| reasoning_protein_band high->good | P2 | 881 | no ranking points |
| goal_band off->on | P2 | 838 | goal-dependent |
| reasoning_cal_band mid->hearty | P2 | 775 | no ranking points |
| calorie_bucket 5->15 | P2 | 689 | +10 |
| reasoning_cal_band light->mid | P2 | 593 | no ranking points |
| ranking_high_protein off->on | P2 | 573 | +4 |
| reasoning_protein_band good->none | P2 | 475 | no ranking points |
| reasoning_protein_band none->high | P2 | 470 | no ranking points |
| calorie_bucket 20->30 | P2 | 428 | +10 |
| sodium_bonus on->off | P2 | 381 | -10 |
| fiber_bonus on->off | P2 | 373 | -10 |
| reasoning_cal_band mid->light | P2 | 260 | no ranking points |
| sugar_bonus off->on | P2 | 230 | +10 |
| calorie_bucket 30->20 | P2 | 222 | -10 |
| sodium_bonus off->on | P2 | 194 | +10 |
| fiber_bonus off->on | P2 | 182 | +10 |
| reasoning_protein_band high->none | P2 | 46 | no ranking points |
| calorie_bucket 20->5 | P2 | 41 | -15 |
| calorie_bucket 5->30 | P2 | 14 | +25 |
| reasoning_protein_band none->good | P3 | 5566 | no ranking points |
| reasoning_protein_band good->high | P3 | 2526 | no ranking points |
| calorie_bucket 20->30 | P3 | 1621 | +10 |
| calorie_bucket 30->20 | P3 | 1184 | -10 |
| calorie_bucket 20->5 | P3 | 1155 | -15 |
| reasoning_cal_band hearty->mid | P3 | 1058 | no ranking points |
| ranking_high_protein on->off | P3 | 994 | -4 |
| sugar_bonus on->off | P3 | 987 | -10 |
| reasoning_protein_band high->good | P3 | 915 | no ranking points |
| reasoning_cal_band mid->hearty | P3 | 765 | no ranking points |
| reasoning_cal_band light->mid | P3 | 591 | no ranking points |
| ranking_high_protein off->on | P3 | 585 | +4 |
| calorie_bucket 15->30 | P3 | 570 | +15 |
| calorie_bucket 30->15 | P3 | 557 | -15 |
| reasoning_protein_band good->none | P3 | 518 | no ranking points |
| reasoning_protein_band none->high | P3 | 482 | no ranking points |
| fiber_bonus on->off | P3 | 392 | -10 |
| sodium_bonus on->off | P3 | 384 | -10 |
| reasoning_cal_band mid->light | P3 | 281 | no ranking points |
| sugar_bonus off->on | P3 | 234 | +10 |
| calorie_bucket 5->20 | P3 | 197 | +15 |
| sodium_bonus off->on | P3 | 192 | +10 |
| fiber_bonus off->on | P3 | 172 | +10 |
| reasoning_protein_band high->none | P3 | 43 | no ranking points |
| calorie_bucket 15->5 | P3 | 10 | -10 |
| reasoning_protein_band none->good | P4 | 5618 | no ranking points |
| goal_band on->off | P4 | 4021 | goal-dependent |
| calorie_bucket 20->30 | P4 | 3392 | +10 |
| reasoning_protein_band good->high | P4 | 2537 | no ranking points |
| calorie_bucket 30->20 | P4 | 1729 | -10 |
| ranking_high_protein on->off | P4 | 1052 | -4 |
| reasoning_cal_band hearty->mid | P4 | 1052 | no ranking points |
| sugar_bonus on->off | P4 | 1001 | -10 |
| reasoning_protein_band high->good | P4 | 900 | no ranking points |
| reasoning_cal_band mid->hearty | P4 | 780 | no ranking points |
| calorie_bucket 30->15 | P4 | 708 | -15 |
| ranking_high_protein off->on | P4 | 597 | +4 |
| reasoning_cal_band light->mid | P4 | 594 | no ranking points |
| goal_band off->on | P4 | 551 | goal-dependent |
| reasoning_protein_band good->none | P4 | 521 | no ranking points |
| calorie_bucket 5->20 | P4 | 504 | +15 |
| reasoning_protein_band none->high | P4 | 489 | no ranking points |
| calorie_bucket 15->30 | P4 | 391 | +15 |
| calorie_bucket 15->5 | P4 | 388 | -10 |
| fiber_bonus on->off | P4 | 376 | -10 |
| sodium_bonus on->off | P4 | 359 | -10 |
| reasoning_cal_band mid->light | P4 | 274 | no ranking points |
| sugar_bonus off->on | P4 | 242 | +10 |
| fiber_bonus off->on | P4 | 186 | +10 |
| calorie_bucket 20->5 | P4 | 173 | -15 |
| sodium_bonus off->on | P4 | 170 | +10 |
| reasoning_protein_band high->none | P4 | 37 | no ranking points |
| reasoning_protein_band none->good | P5 | 5536 | no ranking points |
| reasoning_protein_band good->high | P5 | 2529 | no ranking points |
| sugar_bonus on->off | P5 | 1015 | -10 |
| reasoning_cal_band hearty->mid | P5 | 1004 | no ranking points |
| ranking_high_protein on->off | P5 | 934 | -4 |
| reasoning_protein_band high->good | P5 | 899 | no ranking points |
| reasoning_cal_band mid->hearty | P5 | 799 | no ranking points |
| reasoning_cal_band light->mid | P5 | 586 | no ranking points |
| ranking_high_protein off->on | P5 | 584 | +4 |
| reasoning_protein_band good->none | P5 | 493 | no ranking points |
| reasoning_protein_band none->high | P5 | 455 | no ranking points |
| sodium_bonus on->off | P5 | 381 | -10 |
| fiber_bonus on->off | P5 | 380 | -10 |
| reasoning_cal_band mid->light | P5 | 277 | no ranking points |
| sugar_bonus off->on | P5 | 229 | +10 |
| sodium_bonus off->on | P5 | 198 | +10 |
| fiber_bonus off->on | P5 | 173 | +10 |
| reasoning_protein_band high->none | P5 | 55 | no ranking points |

