#!/usr/bin/env python3
"""Generate Sources/C1Kit/Resources/Defaults.json from a live `c1next get` of an unedited variant.

Usage: scripts/v2-defaults.py --id <variant id> [--c1next .build/debug/c1next]

Run it against a freshly imported, unedited RAW variant in a disposable document. It only reads.
Fields in ALWAYS_REPORTED depend on the camera, lens or image, so `get` with `changed: true`
reports them without comparing.
"""
import argparse
import json
import pathlib
import subprocess
import sys

ALWAYS_REPORTED = {
    "variant": [
        "id", "name", "file", "engine", "exposure meter", "latitude", "longitude", "altitude",
        "available crop aspect ratios", "crop", "crop size", "crop width", "crop height",
        "crop center", "crop centerX", "crop centerY", "crop orientation",
    ],
    "adjustments": [
        "temperature", "tint", "white balance preset", "color profile", "film curve", "orientation",
        "dehaze color", "sharpening amount", "sharpening radius", "sharpening threshold",
        "noise reduction luminance", "noise reduction details", "noise reduction color",
    ],
    "lensCorrection": ["lens profile", "aperture", "focal length"],
    "layer": ["name", "kind"],
}

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Sources/C1Kit/Resources/Defaults.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--id", required=True)
    parser.add_argument("--c1next", default=".build/debug/c1next")
    args = parser.parse_args()

    result = subprocess.run([args.c1next, "get", json.dumps({"ids": [args.id]})], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"c1next get failed:\n{result.stdout}{result.stderr}")
    state = json.loads(result.stdout)["variants"][0]
    if "error" in state:
        sys.exit(f"cannot read variant {args.id}: {state['error']}")
    layers = state["layers"]
    if len(layers) != 1 or layers[0].get("kind") != "background":
        sys.exit(f"variant {args.id} has layers beyond the Image layer; use an unedited variant")

    sections = {
        "variant": state["variant"],
        "adjustments": state["adjustments"],
        "lensCorrection": state["lensCorrection"],
        "layer": layers[0],
    }
    for section, names in ALWAYS_REPORTED.items():
        unknown = sorted(set(names) - set(sections[section]))
        if unknown:
            sys.exit(f"ALWAYS_REPORTED[{section!r}] names fields Capture One did not return: {unknown}")
    defaults = {
        section: {name: value for name, value in fields.items() if name not in ALWAYS_REPORTED[section]}
        for section, fields in sections.items()
    }
    OUTPUT.write_text(json.dumps({"alwaysReported": ALWAYS_REPORTED, "defaults": defaults}, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
