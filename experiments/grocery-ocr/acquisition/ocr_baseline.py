#!/usr/bin/env python3
"""Run the tesseract OCR baseline over the fetched images and emit OCR lines.

This is the baseline text producer standing in for the on-device Vision OCR pass
(Apple Vision is unavailable off-device). It reconstructs per-line text and line
bounding boxes from tesseract's word-level TSV, in the geometry the production
pipeline expects: pixel coordinates here; the harness normalizes to Vision's
bottom-left-origin unit space using the image dimensions recorded per record.

Line reconstruction: group words by (block, paragraph, line); the line box is the
union of its word boxes; text is words joined with single spaces; words reported
with negative confidence are dropped (tesseract marks non-text rows that way).

Usage: python3 ocr_baseline.py --manifest manifest.csv --cache imgcache \
         --hashes image_hashes.csv --out ocr_lines.jsonl
"""
import argparse
import csv
import json
import os
import struct
import subprocess
import tempfile
from concurrent.futures import ProcessPoolExecutor

TESS_LANG = {"en": "eng", "fr": "fra", "de": "deu", "es": "spa", "it": "ita",
             "nl": "nld", "pt": "por", "pl": "pol"}


def tess_lang(product_lang):
    return TESS_LANG.get((product_lang or "en")[:2], "eng")


def image_size(path):
    """Pure-python JPEG/PNG dimension reader (no Pillow dependency)."""
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", head[16:24])
        return w, h
    if head[:2] == b"\xff\xd8":
        with open(path, "rb") as f:
            data = f.read()
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
            i += 2 + seglen
    raise ValueError(f"cannot read dimensions of {path}")


def run_one(job):
    code, role, img_lang, path, product_lang = job
    try:
        w, h = image_size(path)
        with tempfile.NamedTemporaryFile(suffix=".tsv", delete=False) as tf:
            outbase = tf.name[:-4]
        cmd = ["tesseract", path, outbase, "-l", tess_lang(product_lang), "--psm", "3", "tsv"]
        subprocess.run(cmd, check=True, capture_output=True, timeout=180)
        with open(outbase + ".tsv", encoding="utf-8") as f:
            rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))
        groups = {}
        for r in rows:
            try:
                conf = float(r["conf"])
            except (KeyError, ValueError):
                continue
            if conf < 0 or not (r.get("text") or "").strip():
                continue
            key = (r["block_num"], r["par_num"], r["line_num"])
            groups.setdefault(key, []).append(
                (int(r["left"]), int(r["top"]), int(r["width"]), int(r["height"]), r["text"], conf))
        lines = []
        for key in sorted(groups, key=lambda k: min(w0[1] for w0 in groups[k])):
            words = groups[key]
            x0 = min(w0[0] for w0 in words)
            y0 = min(w0[1] for w0 in words)
            x1 = max(w0[0] + w0[2] for w0 in words)
            y1 = max(w0[1] + w0[3] for w0 in words)
            text = " ".join(w0[4] for w0 in words).strip()
            conf = sum(w0[5] for w0 in words) / len(words)
            if len(text) >= 2 and x1 > x0 and y1 > y0:
                lines.append({"text": text, "x0": x0, "y0": y0, "x1": x1, "y1": y1,
                              "conf": round(conf, 1)})
        os.unlink(outbase + ".tsv")
        return {"code": code, "role": role, "image_lang": img_lang, "tesseract_lang": tess_lang(product_lang),
                "width": w, "height": h, "lines": lines, "status": "ok"}
    except Exception as e:
        return {"code": code, "role": role, "image_lang": img_lang, "lines": [],
                "status": f"error: {type(e).__name__}: {e}"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--hashes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    langs = {}
    with open(args.manifest, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            langs[row["code"]] = row.get("lang") or "en"

    jobs = []
    with open(args.hashes, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["status"] != "ok":
                continue
            p = os.path.join(args.cache, f"{row['code']}__{row['role']}_{row['lang']}_{row['rev']}.jpg")
            if os.path.exists(p):
                jobs.append((row["code"], row["role"], row["lang"], p, langs.get(row["code"], "en")))

    done = set()
    if os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    done.add((rec["code"], rec["role"]))
                except Exception:
                    pass

    todo = [j for j in jobs if (j[0], j[1]) not in done]
    n = 0
    with open(args.out, "a", encoding="utf-8") as out:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            for res in pool.map(run_one, todo):
                out.write(json.dumps(res, ensure_ascii=False) + "\n")
                n += 1
                if n % 100 == 0:
                    out.flush()
                    print(f"{n} images OCR'd", flush=True)
    print(f"OCR pass complete: {n} new records, {len(done)} already present")


if __name__ == "__main__":
    main()
