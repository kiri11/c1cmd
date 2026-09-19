#!/usr/bin/env python3
"""Read-only planning from explicit crop/bounds JSON; never contacts Capture One."""
import argparse
import json
import math

KEYS = ("centerX", "centerY", "width", "height")


def propose(crop, bounds):
    for rect in (crop, bounds):
        if any(type(rect[k]) not in (int, float) or not math.isfinite(rect[k]) for k in KEYS):
            raise ValueError("Rectangles require finite numeric coordinates")
        if rect["width"] < 1 or rect["height"] < 1:
            raise ValueError("Rectangles require dimensions of at least one pixel")
    scale = min(1.0, bounds["width"] / crop["width"], bounds["height"] / crop["height"])
    # A tiny inward margin avoids an empty floating-point center interval at a
    # full-width fit. It is reported in the deltas, never hidden as an exact copy.
    for _ in range(32):
        w, h = crop["width"] * scale, crop["height"] * scale
        if w < 1 or h < 1:
            raise ValueError("No proportional fit with dimensions of at least one pixel")
        out = dict(width=w, height=h)
        valid = True
        for center, size in (("centerX", "width"), ("centerY", "height")):
            room = (bounds[size] - out[size]) / 2
            low, high = bounds[center] - room, bounds[center] + room
            out[center] = min(max(crop[center], low), high)
            valid &= room >= 0 and abs(out[center] - bounds[center]) + out[size] / 2 <= bounds[size] / 2
        if valid:
            return {"status": "unchanged" if out == crop else "normalized-proposal",
                    "original": crop, "bounds": bounds, "proposed": out,
                    "delta": {k: out[k] - crop[k] for k in KEYS}, "scale": scale,
                    "originalAspectRatio": crop["width"] / crop["height"],
                    "proposedAspectRatio": w / h,
                    "applied": False}
        scale = math.nextafter(scale, 0.0)
    raise ValueError("Cannot construct a numerically contained proportional rectangle")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help='JSON file containing explicit "crop" and "bounds" rectangles')
    args = parser.parse_args()
    with open(args.input) as source:
        data = json.load(source)
    print(json.dumps(propose(data["crop"], data["bounds"]), indent=2, allow_nan=False))
