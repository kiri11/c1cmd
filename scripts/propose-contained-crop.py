#!/usr/bin/env python3
"""Read-only planning from a crop and a fresh `get` geometry; never contacts Capture One.

Uncorrected images use exact containment in the rotated image, the same test c1
applies (Sources/CaptureOneCore/Geometry.swift, CropContainment; both run
Tests/fixtures/crop-containment.json). Corrected images use the native
`maximumCrop` rectangle at the current rotation.
"""
import argparse
import json
import math

KEYS = ("centerX", "centerY", "width", "height")
TOLERANCE = 2.0


def _check(crop):
    if any(type(crop[k]) not in (int, float) or not math.isfinite(crop[k]) for k in KEYS):
        raise ValueError("Rectangles require finite numeric coordinates")
    if crop["width"] < 1 or crop["height"] < 1:
        raise ValueError("Rectangles require dimensions of at least one pixel")


def _frame(rotation, width, height):
    r = math.radians(rotation)
    c, s = math.cos(r), math.sin(r)
    return c, s, (width*abs(c) + height*abs(s)) / 2, (width*abs(s) + height*abs(c)) / 2


def exposed_corners(crop, rotation, width, height, tolerance=TOLERANCE):
    """Crop corners outside the `width` x `height` image rotated clockwise by `rotation`
    degrees about the centre of its bounding canvas (bottom-left origin)."""
    c, s, cx, cy = _frame(rotation, width, height)
    exposed = []
    for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        dx = (crop["centerX"] - cx) + sx*crop["width"]/2
        dy = (crop["centerY"] - cy) + sy*crop["height"]/2
        u = abs(dx*c - dy*s) - width/2
        v = abs(dx*s + dy*c) - height/2
        if u > tolerance or v > tolerance:
            exposed.append(dict(x=crop["centerX"] + sx*crop["width"]/2, y=crop["centerY"] + sy*crop["height"]/2,
                                distance=math.hypot(max(u, 0), max(v, 0))))
    return exposed


def _result(crop, out, scale, **context):
    return {"status": "unchanged" if out == crop else "normalized-proposal",
            "original": crop, **context, "proposed": out,
            "delta": {k: out[k] - crop[k] for k in KEYS}, "scale": scale,
            "originalAspectRatio": crop["width"] / crop["height"],
            "proposedAspectRatio": out["width"] / out["height"],
            "applied": False}


def propose(crop, rotation, width, height):
    """Scale by one factor (never enlarging), then move the centre the minimum distance
    so every corner lies inside the rotated image."""
    _check(crop)
    if not all(type(x) in (int, float) and math.isfinite(x) for x in (rotation, width, height)) or width < 1 or height < 1:
        raise ValueError("Rotation and canvas size must be finite; the canvas at least one pixel")
    context = dict(rotation=rotation, canvas=dict(width=width, height=height),
                   exposedCorners=exposed_corners(crop, rotation, width, height, tolerance=0))
    if not context["exposedCorners"]:
        return _result(crop, dict(crop), 1.0, **context)
    c, s, cx, cy = _frame(rotation, width, height)
    ac, as_ = abs(c), abs(s)
    scale = min(1.0, width / (crop["width"]*ac + crop["height"]*as_), height / (crop["width"]*as_ + crop["height"]*ac))
    # A micro-pixel inward margin keeps a boundary-hugging centre contained despite
    # rounding; it is reported in the deltas, never hidden as an exact copy.
    margin = 1e-9 * max(width, height)
    for _ in range(32):
        w, h = crop["width"] * scale, crop["height"] * scale
        if w < 1 or h < 1:
            raise ValueError("No proportional fit with dimensions of at least one pixel")
        # Centres keeping every corner inside form a rectangle in the image frame.
        a = max(0.0, (width - w*ac - h*as_) / 2 - margin)
        b = max(0.0, (height - w*as_ - h*ac) / 2 - margin)
        dx, dy = crop["centerX"] - cx, crop["centerY"] - cy
        pu = min(max(dx*c - dy*s, -a), a)
        pv = min(max(dx*s + dy*c, -b), b)
        out = dict(centerX=cx + pu*c + pv*s, centerY=cy - pu*s + pv*c, width=w, height=h)
        if not exposed_corners(out, rotation, width, height, tolerance=0):
            return _result(crop, out, scale, **context)
        scale *= 1 - 1e-9
    raise ValueError("Cannot construct a numerically contained proportional rectangle")


def propose_in_bounds(crop, bounds):
    """Corrected geometry: fit inside the native bounds rectangle at the current rotation."""
    for rect in (crop, bounds):
        _check(rect)
    scale = min(1.0, bounds["width"] / crop["width"], bounds["height"] / crop["height"])
    for _ in range(32):
        w, h = crop["width"] * scale, crop["height"] * scale
        if w < 1 or h < 1:
            raise ValueError("No proportional fit with dimensions of at least one pixel")
        out = dict(width=w, height=h)
        valid = True
        for center, size in (("centerX", "width"), ("centerY", "height")):
            room = (bounds[size] - out[size]) / 2
            out[center] = min(max(crop[center], bounds[center] - room), bounds[center] + room)
            valid &= room >= 0 and abs(out[center] - bounds[center]) + out[size] / 2 <= bounds[size] / 2
        if valid:
            return _result(crop, {k: out[k] for k in KEYS}, scale, bounds=bounds)
        scale = math.nextafter(scale, 0.0)
    raise ValueError("Cannot construct a numerically contained proportional rectangle")


def plan(crop, geometry):
    """Normalize `crop` against the `geometry` object of the same fresh `get`."""
    corrected = (geometry["lensGeometry"][0] != 0 or any(geometry["keystone"][1:])
                 or any(geometry["lensGeometry"][2:]))
    if corrected:
        return propose_in_bounds(crop, geometry["maximumCrop"])
    portrait = geometry["orientation"] in (90, 270)
    width, height = geometry["imageWidth"], geometry["imageHeight"]
    return propose(crop, geometry["rotation"], *((height, width) if portrait else (width, height)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", help='JSON file with a "crop" rectangle and the "geometry" object of a fresh get')
    args = parser.parse_args()
    with open(args.input) as source:
        data = json.load(source)
    print(json.dumps(plan(data["crop"], data["geometry"]), indent=2, allow_nan=False))
