#!/usr/bin/env python3
"""Check a live bulk `c1next get` against per-field AppleScript reads of the same variant.

Usage: scripts/v2-compare-fields.py --id <variant id> --collection <collection id holding it>

Read-only. Every field the bulk read returns is read again with its own `get <field> of ...`
Apple Event through the given collection, then compared (reals within 1e-5 relative).
Exits non-zero and lists each mismatch.
"""
import argparse
import json
import re
import subprocess
import sys

TOKEN = re.compile(r'\s*(?:(\{)|(\})|(,)|"((?:[^"\\]|\\.)*)"|(-?\d+(?:\.\d+)?(?:E[+-]?\d+)?)|([A-Za-z][A-Za-z0-9 ]*))')


def parse(text):
    """Parses the `osascript -ss` form of a value: lists, strings, numbers, booleans, constants."""
    tokens, position = [], 0
    while position < len(text.rstrip()):
        match = TOKEN.match(text, position)
        if not match:
            raise ValueError(f"cannot parse {text[position:position + 40]!r}")
        tokens.append(match)
        position = match.end()

    def value(index):
        match = tokens[index]
        if match.group(1):
            items, index = [], index + 1
            while not tokens[index].group(2):
                item, index = value(index)
                items.append(item)
                if tokens[index].group(3):
                    index += 1
            return items, index + 1
        if match.group(4) is not None:
            return json.loads(f'"{match.group(4)}"'), index + 1
        if match.group(5):
            number = float(match.group(5))
            return (int(number) if number.is_integer() and "." not in match.group(5) else number), index + 1
        word = match.group(6).strip()
        if word.startswith("file ") or word.startswith("alias "):
            path, index = value(index + 1)
            return path, index
        return {"true": True, "false": False, "missing value": None}.get(word, word), index + 1

    result, _ = value(0)
    return result


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= 1e-5 * max(1, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--id", required=True)
    parser.add_argument("--collection", required=True)
    parser.add_argument("--c1next", default=".build/debug/c1next")
    args = parser.parse_args()

    bulk = json.loads(subprocess.run([args.c1next, "get", json.dumps({"ids": [args.id]})], capture_output=True, text=True, check=True).stdout)
    state = bulk["variants"][0]
    if "error" in state:
        sys.exit(f"bulk read failed: {state['error']}")

    v = f'variant id "{args.id}" of collection id "{args.collection}" of current document'
    reads = [(f"variant.{name}", f"{name} of {v}", value) for name, value in state["variant"].items()]
    reads += [(f"adjustments.{name}", f"{name} of adjustments of {v}", value) for name, value in state["adjustments"].items()]
    reads += [(f"lensCorrection.{name}", f"{name} of lens correction of {v}", value) for name, value in state["lensCorrection"].items()]
    for index, layer in enumerate(state["layers"], start=1):
        reads += [(f"layers[{index}].{name}", f"{name} of layer {index} of {v}", value) for name, value in layer.items() if name != "adjustments"]
        reads += [(f"layers[{index}].adjustments.{name}", f"{name} of adjustments of layer {index} of {v}", value)
                  for name, value in layer.get("adjustments", {}).items()]

    body = "\n".join(f"set end of out to ({expression})" for _, expression, _ in reads)
    script = f'tell application "Capture One"\nwith timeout of 300 seconds\nset out to {{}}\n{body}\nreturn out\nend timeout\nend tell'
    # `file` values print as `file "HD:path"`; ask for POSIX paths so they compare with the bulk read.
    script = script.replace(f"(file of {v})", f"(POSIX path of (get file of {v}))")
    result = subprocess.run(["osascript", "-ss", "-e", script], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"per-field reads failed: {result.stderr}")
    single = parse(result.stdout.strip())
    if len(single) != len(reads):
        sys.exit(f"expected {len(reads)} per-field values, got {len(single)}")

    mismatches = [(label, bulk_value, field) for (label, _, bulk_value), field in zip(reads, single) if not same(bulk_value, field)]
    for label, bulk_value, field in mismatches:
        print(f"MISMATCH {label}: bulk {bulk_value!r}, per-field {field!r}")
    print(f"{len(reads) - len(mismatches)}/{len(reads)} fields match")
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
