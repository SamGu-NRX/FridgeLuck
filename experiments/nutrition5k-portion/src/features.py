"""Lightweight RGB and RGB+D feature extraction for Nutrition5k overhead views.

Frozen view policy: the single calibrated overhead realsense frame per dish
(rgb.png, plus depth_raw.png when available). Side-angle videos are not used.

Design constraints: CPU-only, milliseconds per image, no learned backbone --
the point is to measure how far cheap handcrafted features go, not to win the
benchmark. All features are deterministic given the image.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

RGB_SIZE = (320, 240)  # (w, h) working resolution
DEPTH_SCALE = 10_000.0  # raw units per meter (README: 1 m = 10,000 units)
DEPTH_SENTINEL = 65_535  # invalid-pixel sentinel observed in raw depth
DEPTH_CAP_M = 0.4  # README: values rounded to max 0.4 m

RGB_FEATURE_NAMES: list[str] = (
    [f"lab_{c}_mean" for c in ("L", "a", "b")]
    + [f"lab_{c}_std" for c in ("L", "a", "b")]
    + ["hsv_sin_h_mean", "hsv_cos_h_mean", "hsv_s_mean", "hsv_s_std", "hsv_v_mean", "hsv_v_std"]
    + [f"hs_hist_{r}_{s}" for r in range(12) for s in range(8)]
    + ["sat_p50", "sat_p90", "val_p50", "food_mask_fraction", "edge_density"]
    + [f"ring_occupancy_{i}" for i in range(5)]
    + [f"grid_L_mean_{i}" for i in range(16)]
)

DEPTH_FEATURE_NAMES: list[str] = [
    "depth_valid_fraction",
    "food_mask_depth_valid_fraction",
    "depth_food_p05_m",
    "depth_food_p25_m",
    "depth_food_p50_m",
    "depth_food_p75_m",
    "depth_food_p95_m",
    "ref_depth_m",
    "height_mean_m",
    "height_p90_m",
    "height_max_m",
    "volume_proxy",
]

FOOD_SAT_MIN = 0.2
FOOD_VAL_MIN = 0.15
FOOD_VAL_MAX = 0.95


def _food_mask(hsv: np.ndarray) -> np.ndarray:
    s, v = hsv[..., 1], hsv[..., 2]
    return (s > FOOD_SAT_MIN) & (v > FOOD_VAL_MIN) & (v < FOOD_VAL_MAX)


def rgb_features(img: Image.Image) -> np.ndarray:
    """134 deterministic handcrafted features from one overhead RGB frame."""
    img = img.convert("RGB").resize(RGB_SIZE, Image.BILINEAR)
    arr = np.asarray(img, dtype=np.float64) / 255.0
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]

    # Lab via simple sRGB -> Lab (D65). skimage-free implementation.
    def srgb_to_linear(c: np.ndarray) -> np.ndarray:
        return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

    lin = srgb_to_linear(arr)
    xyz = np.stack(
        [
            0.4124 * lin[..., 0] + 0.3576 * lin[..., 1] + 0.1805 * lin[..., 2],
            0.2126 * lin[..., 0] + 0.7152 * lin[..., 1] + 0.0722 * lin[..., 2],
            0.0193 * lin[..., 0] + 0.1192 * lin[..., 1] + 0.9505 * lin[..., 2],
        ],
        axis=-1,
    )
    xyz /= np.array([0.95047, 1.0, 1.08883])

    def f(t: np.ndarray) -> np.ndarray:
        return np.where(t > 0.008856, np.cbrt(t), 7.787 * t + 16.0 / 116.0)

    fx, fy, fz = (f(xyz[..., i]) for i in range(3))
    L = 116.0 * fy - 16.0
    a = 500.0 * (fx - fy)
    bstar = 200.0 * (fy - fz)

    # HSV
    maxc = arr.max(-1)
    minc = arr.min(-1)
    v = maxc
    delta = maxc - minc
    s = np.where(maxc > 0, delta / np.maximum(maxc, 1e-12), 0.0)
    h = np.zeros_like(maxc)
    nz = delta > 1e-12
    rc = np.where(nz, (maxc - r) / np.maximum(delta, 1e-12), 0.0)
    gc = np.where(nz, (maxc - g) / np.maximum(delta, 1e-12), 0.0)
    bc = np.where(nz, (maxc - b) / np.maximum(delta, 1e-12), 0.0)
    h = np.where(maxc == r, bc - gc, np.where(maxc == g, 2.0 + rc - bc, 4.0 + gc - rc))
    h = (h / 6.0) % 1.0

    mask = _food_mask(np.stack([h, s, v], axis=-1))

    hs_hist, _, _ = np.histogram2d(
        h.ravel(), s.ravel(), bins=[12, 8], range=[[0, 1], [0, 1]]
    )
    hs_hist = hs_hist / max(hs_hist.sum(), 1.0)

    # Sobel edge density on L
    kx = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=np.float64)
    ky = kx.T
    pad = np.pad(L, 1, mode="edge")
    gx = sum(pad[i : i + 3, j : j + 3] * kx[i, j] for i in range(3) for j in range(3))
    gy = sum(pad[i : i + 3, j : j + 3] * ky[i, j] for i in range(3) for j in range(3))
    grad = np.hypot(gx, gy)
    edge_density = float((grad > 0.1).mean())

    # radial occupancy of the food mask in 5 rings
    hh, ww = L.shape
    yy, xx = np.mgrid[0:hh, 0:ww]
    rad = np.hypot((xx - ww / 2) / (ww / 2), (yy - hh / 2) / (hh / 2))
    rings = []
    for i in range(5):
        sel = (rad >= i * 0.2) & (rad < (i + 1) * 0.2)
        rings.append(float(mask[sel].mean()))

    grid = []
    for i in range(4):
        for j in range(4):
            cell = L[i * hh // 4 : (i + 1) * hh // 4, j * ww // 4 : (j + 1) * ww // 4]
            grid.append(float(cell.mean()))

    feats = np.concatenate(
        [
            [L.mean(), a.mean(), bstar.mean(), L.std(), a.std(), bstar.std()],
            [
                np.sin(2 * np.pi * h).mean(),
                np.cos(2 * np.pi * h).mean(),
                s.mean(),
                s.std(),
                v.mean(),
                v.std(),
            ],
            hs_hist.ravel(),
            [np.percentile(s, 50), np.percentile(s, 90), np.percentile(v, 50)],
            [float(mask.mean()), edge_density],
            rings,
            grid,
        ]
    )
    assert len(feats) == len(RGB_FEATURE_NAMES), (len(feats), len(RGB_FEATURE_NAMES))
    return feats


def decode_depth(depth_img: Image.Image) -> tuple[np.ndarray, np.ndarray]:
    """Return (meters, valid) from a raw 16-bit depth PNG."""
    raw = np.asarray(depth_img, dtype=np.uint16)
    if raw.ndim == 3:  # defensively drop any duplicated-channel encoding
        raw = raw[..., 0]
    valid = (raw > 0) & (raw < DEPTH_SENTINEL)
    meters = np.where(valid, raw.astype(np.float64) / DEPTH_SCALE, np.nan)
    return meters, valid


def depth_features(depth_img: Image.Image, rgb_img: Image.Image) -> np.ndarray:
    """12 features combining raw depth with the RGB color food mask."""
    # Real depth frames are 640x480 while RGB works at 320x240: bring the raw
    # 16-bit depth onto the RGB grid with NEAREST (preserves sentinel values and
    # validity semantics; BILINEAR would blend food/plate boundaries).
    depth_img = depth_img if depth_img.size == RGB_SIZE else depth_img.resize(RGB_SIZE, Image.NEAREST)
    meters, valid = decode_depth(depth_img)
    rgb_img = rgb_img.convert("RGB").resize(RGB_SIZE, Image.BILINEAR)
    arr = np.asarray(rgb_img, dtype=np.float64) / 255.0
    maxc = arr.max(-1)
    minc = arr.min(-1)
    v = maxc
    delta = maxc - minc
    s = np.where(maxc > 0, delta / np.maximum(maxc, 1e-12), 0.0)
    mask = (s > FOOD_SAT_MIN) & (v > FOOD_VAL_MIN) & (v < FOOD_VAL_MAX)

    hh, ww = mask.shape
    yy, xx = np.mgrid[0:hh, 0:ww]
    rad = np.hypot((xx - ww / 2) / (ww / 2), (yy - hh / 2) / (hh / 2))

    outer = valid & (rad > 0.75)  # plate rim / table ring
    ref = np.nanpercentile(meters[outer], 50) if outer.sum() > 50 else np.nan
    food = mask & valid
    in_mask = meters[food]
    if in_mask.size > 0 and np.isfinite(ref):
        qs = np.nanpercentile(in_mask, [5, 25, 50, 75, 95])
        height = ref - meters  # positive = closer to camera = taller than rim
        height_masked = np.where(food, np.maximum(height, 0.0), 0.0)
        feats = np.array(
            [
                float(valid.mean()),
                float(food.sum() / max(mask.sum(), 1)),
                qs[0],
                qs[1],
                qs[2],
                qs[3],
                qs[4],
                ref,
                float(np.nanmean(height_masked)),
                float(np.nanpercentile(height_masked[food] if food.sum() else np.array([0.0]), 90)),
                float(np.nanmax(height_masked)),
                float(height_masked.sum() / height_masked.size),
            ]
        )
    else:
        feats = np.full(len(DEPTH_FEATURE_NAMES), np.nan)
    assert len(feats) == len(DEPTH_FEATURE_NAMES)
    return feats
