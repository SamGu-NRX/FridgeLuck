#!/usr/bin/env bash
# Full pipeline: sample -> fetch -> OCR -> prepare -> harness -> score.
# Resumable at every step (sampler is deterministic; fetch/OCR skip existing).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXP="$(dirname "$HERE")"           # experiments/grocery-ocr
DATA="$EXP/data"
CACHE="$EXP/imagecache"            # large, not committed
HARNESS="$EXP/harness"
REPO="$(cd "$EXP/../../.." && pwd)" # repo root
export PATH="$HOME/.local/share/swiftly/bin:$PATH"
export LD_LIBRARY_PATH=/usr/local/lib
CATALOG="$REPO/apps/ios/Resources/usda_ingredient_catalog.sqlite"

mkdir -p "$DATA"

[ -f "$DATA/manifest.csv" ] || python3 "$HERE/sample_products.py" --out-dir "$DATA"

if [ ! -f "$DATA/image_hashes.csv" ]; then
  python3 "$HERE/fetch_images.py" --manifest "$DATA/manifest.csv" --cache "$CACHE" --out "$DATA/image_hashes.csv" --workers 6
fi

if [ ! -f "$DATA/ocr_lines.jsonl" ]; then
  python3 "$HERE/ocr_baseline.py" --manifest "$DATA/manifest.csv" --cache "$CACHE" \
    --hashes "$DATA/image_hashes.csv" --out "$DATA/ocr_lines.jsonl" --workers 4
fi

python3 "$HERE/prepare_inputs.py" --manifest "$DATA/manifest.csv" --ocr-traces "$DATA/ocr_lines.jsonl" --out-dir "$DATA"

cd "$HARNESS"
swift test 2>&1 | tee "$DATA/harness_tests.log"

swift run GroceryOCRHarness --catalog "$CATALOG" --mode targets \
  --input "$DATA/targets_input.jsonl" --output "$DATA/targets_out.jsonl"
swift run GroceryOCRHarness --catalog "$CATALOG" --mode ocr \
  --input "$DATA/reference_input.jsonl" --output "$DATA/reference_out.jsonl"
[ -f "$DATA/harness_ocr_input.jsonl" ] && swift run GroceryOCRHarness --catalog "$CATALOG" --mode ocr \
  --input "$DATA/harness_ocr_input.jsonl" --output "$DATA/ocr_out.jsonl"

python3 "$HERE/score.py" --manifest "$DATA/manifest.csv" \
  --targets "$DATA/targets_out.jsonl" --reference "$DATA/reference_out.jsonl" \
  --ocr "$DATA/ocr_out.jsonl" --out-dir "$DATA/scores"
echo "PIPELINE COMPLETE"
