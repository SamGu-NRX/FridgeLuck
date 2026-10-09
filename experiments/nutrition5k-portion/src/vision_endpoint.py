"""Vision-endpoint arm: a hosted vision model prompted for structured output.

Mirrors the FridgeLuck live-agent budget discipline (per-request conservative
token estimate + returned usage capture + hard spend ceiling; see
backend/gemini-agent/src/liveDecisions.ts): this harness refuses to run past its
declared budget and records every request's usage. The endpoint sees ONLY the
overhead photo and a portion-estimation prompt -- no ingredient lists, no
reference information -- so its numbers are comparable to the local rgb arm.

Usage:
  GEMINI_API_KEY=... python3 vision_endpoint.py --max-images=250 --spend-ceiling-usd=2.0

Refuses to run without GEMINI_API_KEY in the environment. Results land in
outputs/vision_endpoint_predictions.csv and vision_endpoint_summary.json.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

WORK = Path("/home/user/work/n5k-data")
EXPERIMENT = Path(__file__).resolve().parents[1]
OUT = EXPERIMENT / "outputs"
MODEL = "gemini-2.5-flash"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models"

# Conservative per-request ceiling used when the API omits usageMetadata:
# image tokens for a 640x480 frame + output tokens, priced at the published
# 2.5-flash input rate; the ceiling is intentionally generous, not an estimate.
PER_REQUEST_MAX_USD = 0.002

PROMPT = (
    "This is a top-down photo of a meal plate from a fixed, calibrated overhead "
    "camera. Estimate the total weight of food on the plate in grams and the total "
    "food energy in kilocalories. Respond with ONLY a JSON object: "
    '{"mass_g": <number>, "calories_kcal": <number>}'
)


def usage_tokens_to_usd(usage: dict) -> float:
    input_mtok = 0.30  # published USD per 1M input tokens, 2.5-flash
    output_mtok = 2.50  # USD per 1M output tokens
    return (
        usage.get("promptTokenCount", 0) / 1e6 * input_mtok
        + usage.get("candidatesTokenCount", 0) / 1e6 * output_mtok
    )


def test_ids() -> list[str]:
    with (EXPERIMENT / "data" / "dish_targets.csv").open() as fh:
        return [r["dish_id"] for r in csv.DictReader(fh) if r["my_split"] == "test"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-images", type=int, default=250)
    ap.add_argument("--spend-ceiling-usd", type=float, default=2.0)
    args = ap.parse_args()

    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print(
            "REFUSING TO RUN: GEMINI_API_KEY is not set in the environment. "
            "This arm is reported as NOT EXECUTED in the experiment report. "
            "No charge was made; no estimate was fabricated.",
            flush=True,
        )
        return 3

    frozen = json.loads((EXPERIMENT / "FROZEN_CONFIG.json").read_text())
    assert frozen["frozen_before_test_run"] is True

    ids = [d for d in test_ids() if (WORK / "imagery" / d / "rgb.png").exists()]
    ids = ids[: args.max_images]

    spent = 0.0
    results = []
    latencies = []
    for d in ids:
        if spent >= args.spend_ceiling_usd:
            print(f"BUDGET CEILING REACHED at ${spent:.4f}; stopping after {len(results)} images")
            break
        img_b64 = base64.b64encode((WORK / "imagery" / d / "rgb.png").read_bytes()).decode()
        body = json.dumps(
            {
                "contents": [
                    {"parts": [
                        {"text": PROMPT},
                        {"inline_data": {"mime_type": "image/png", "data": img_b64}},
                    ]}
                ],
                "generationConfig": {"temperature": 0.0, "responseMimeType": "application/json"},
            }
        ).encode()
        req = urllib.request.Request(
            f"{ENDPOINT}/{MODEL}:generateContent?key={key}",
            data=body, headers={"Content-Type": "application/json"}, method="POST",
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as exc:
            results.append({"dish_id": d,
                            "error": f"HTTP {exc.code}: {exc.read()[:200].decode(errors='replace')}"})
            continue
        latencies.append((time.time() - t0) * 1000)
        usage = payload.get("usageMetadata", {})
        if "promptTokenCount" in usage and "candidatesTokenCount" in usage:
            spent += usage_tokens_to_usd(usage)  # actual returned usage
        else:
            spent += PER_REQUEST_MAX_USD  # conservative ledger entry
        try:
            text = payload["candidates"][0]["content"]["parts"][0]["text"]
            parsed = json.loads(text)
            results.append({"dish_id": d, "mass_g": parsed.get("mass_g"),
                            "calories_kcal": parsed.get("calories_kcal"),
                            "latency_ms": round(latencies[-1], 1)})
        except (KeyError, IndexError, json.JSONDecodeError) as exc:
            results.append({"dish_id": d, "error": f"parse: {exc}"})

    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "vision_endpoint_predictions.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["dish_id", "mass_g", "calories_kcal", "latency_ms", "error"])
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in w.fieldnames})
    summary = {
        "model": MODEL,
        "images_requested": len(ids),
        "images_answered": sum(1 for r in results if "mass_g" in r),
        "estimated_spend_usd": round(spent, 4),
        "spend_ceiling_usd": args.spend_ceiling_usd,
        "p50_latency_ms": sorted(latencies)[len(latencies) // 2] if latencies else None,
        "context": "endpoint saw only the overhead photo + prompt; no ingredient list, no reference data",
    }
    (OUT / "vision_endpoint_summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
