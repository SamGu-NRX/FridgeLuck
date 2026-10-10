# dish-ambiguity-v1 report

Mapping: `mapping.food101-v1.json` (sha256 01bde9c3044fe5df...)
Results: benchmarks/dish-ambiguity-v1/results

Food-101 dish labels vs the bundled 166-recipe catalog. A specific recipe
suggestion is emitted only when the predicted class maps to exactly one
bundled recipe ('exact') and its probability clears the dev-selected tau.

## mobilenet-v2-food101

- pinned: `rajkr/mobilenet-v2-food101` @ 0dea82e70d00 (weights sha256 4f972e3ea524f678...); recorded failures: 0
- class accuracy over 2525 test images: top1 0.0614, top5 0.0689
- top1 status mix: exact 608, coarse 0, ambiguous 798, unsupported 1119
- abstention: tau 0.9 selected on dev (0.1053 dev suggestion precision, 0.0941 dev coverage) - TARGET NOT MET (dev could not reach 0.90 suggestion precision; reported tau is the best-effort maximum and is NOT a validated abstention threshold)
- unrestricted suggestions at tau: 265 of 2525 test images, precision 22/265 = 0.083, coverage 0.105
- eligible-only (350 images whose true class is exact/coarse): 57 suggestions, precision 22/57 = 0.386, coverage 0.1629

## vit-base-food101

- pinned: `nateraw/vit-base-food101` @ 55859a2a1349 (weights sha256 61f707d9d423461b...); recorded failures: 0
- class accuracy over 2525 test images: top1 0.8075, top5 0.9620
- top1 status mix: exact 280, coarse 82, ambiguous 50, unsupported 2113
- abstention: tau 0.1 selected on dev (0.9111 dev suggestion precision, 0.0743 dev coverage)
- unrestricted suggestions at tau: 183 of 2525 test images, precision 175/183 = 0.9563, coverage 0.0725
- eligible-only (350 images whose true class is exact/coarse): 175 suggestions, precision 175/175 = 1.0, coverage 0.5

