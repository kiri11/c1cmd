#!/usr/bin/env python3
"""grade-folder.py: Grade variants in an active Capture One document using c1 CLI.

Demonstrates the safe v0.1 editing workflow:
1. Validates environment (c1 doctor & c1 doc info).
2. Lists variants in the chosen collection.
3. For each original variant:
   a. Prepares editing of the existing variant; --clone creates an optional separate proposal.
   b. Reads state & stateHash (c1 get).
   c. Applies preset adjustments under optimistic concurrency (c1 set --if-state).
   d. Exports and verifies preview render (c1 preview).
   e. Records decision record sidecar in .c1/decisions/<workingRef>.json.
4. Outputs photographer review summary.
"""

import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

def run_c1(args: list[str], c1_bin: Path) -> dict | list:
    cmd = [str(c1_bin)] + args + ["--format", "json"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        err_msg = res.stderr.strip() or res.stdout.strip()
        try:
            parsed = json.loads(res.stderr)
            err_msg = parsed.get("error", {}).get("message", err_msg)
        except Exception:
            pass
        raise RuntimeError(f"c1 command failed ({res.returncode}): {' '.join(cmd)}\n{err_msg}")
    
    stdout = res.stdout.strip()
    if not stdout:
        return {}
    return json.loads(stdout)

def main():
    parser = argparse.ArgumentParser(description="Grade existing variants in the active document using c1.")
    parser.add_argument("--preset", type=Path, default=Path(__file__).parent / "presets" / "daylight.json", help="Path to preset adjustments JSON.")
    parser.add_argument("--collection", type=str, default=None, help="Optional collection name.")
    parser.add_argument("--c1-bin", type=Path, default=None, help="Path to c1 executable.")
    parser.add_argument("--dry-run", action="store_true", help="Predict changes without mutating.")
    parser.add_argument("--clone", action="store_true", help="Create separate proposal variants instead of editing existing variants.")
    args = parser.parse_args()

    # Locate c1 executable
    c1_bin = args.c1_bin
    if c1_bin is None:
        default_bin = Path(__file__).resolve().parents[1] / ".build" / "debug" / "c1"
        if default_bin.exists():
            c1_bin = default_bin
        else:
            c1_bin = Path("c1")

    print("=== c1 Automated Grading Workflow ===")
    print(f"Preset : {args.preset}")
    print(f"Binary : {c1_bin}")
    print(f"Dry run: {args.dry_run}")

    # 1. Doctor check
    print("\n[1/4] Running c1 doctor check...")
    try:
        doc_report = run_c1(["doctor"], c1_bin)
        assert doc_report['allChecksPassed'] and doc_report['writesEnabled'] and doc_report['exactBuildMatched']
        print(f"Capture One {doc_report.get('appVersion')} running. Document: {doc_report.get('docName')}")
    except Exception as e:
        print(f"Doctor check failed: {e}", file=sys.stderr)
        sys.exit(1)

    # 2. Document info
    print("\n[2/4] Inspecting active document info...")
    doc_info = run_c1(["doc", "info"], c1_bin)
    session_dir = Path(doc_info["documentPath"])
    print(f"Document path: {session_dir}")
    print(f"Open token   : {doc_info['openToken']}")

    decisions_dir = session_dir / ".c1" / "decisions"
    decisions_dir.mkdir(parents=True, exist_ok=True)

    # Load preset
    with open(args.preset) as f:
        preset_data = json.load(f)
    print(f"Preset adjustments: {preset_data}")

    # 3. List variants
    list_args = ["variants", "list"]
    if args.collection:
        list_args += ["--collection", args.collection]
    variants = run_c1(list_args, c1_bin)
    print(f"\n[3/4] Found {len(variants)} total variants.")

    # Exclude managed clones; this is not a record of prior processing.
    originals = [v for v in variants if not v.get("isManagedWorkingClone")]
    print(f"Original variants to process: {len(originals)}")

    results = []

    # 4. Grading loop
    print("\n[4/4] Processing variants...")
    for idx, v in enumerate(originals, 1):
        vid = v["id"]
        vname = v["name"]
        print(f"\n--- [{idx}/{len(originals)}] Variant {vid} ({vname}) ---")

        # a. Save a baseline and bind this existing variant (or explicitly clone).
        source = run_c1(["get", vid], c1_bin)
        if args.clone:
            prepared = run_c1(["variant", "clone", vid], c1_bin)
            clone_id = prepared["cloneVariantId"]
        else:
            prepared = run_c1(["variant", "edit", vid, "--if-state", source["stateHash"], "--if-document", doc_info["openToken"]], c1_bin)
            clone_id = None
        wref = prepared["workingRef"]
        print(f"  Editing reference: {wref}")

        # b. Get baseline state
        get_res = run_c1(["get", wref], c1_bin)
        baseline_hash = get_res["stateHash"]
        print(f"  Initial stateHash: {baseline_hash}")

        # c. Mutate (set preset)
        set_args = ["set", wref, "--if-state", baseline_hash, "--file", str(args.preset)]
        if args.dry_run:
            set_args.append("--dry-run")
        print(f"  Applying preset adjustments...")
        mut_res = run_c1(set_args, c1_bin)
        new_hash = mut_res["stateHash"]
        print(f"  Applied! New stateHash: {new_hash}")

        # d. Render preview
        preview_path = None
        if not args.dry_run:
            print(f"  Rendering preview...")
            prev_res = run_c1(["preview", wref], c1_bin)
            preview_path = prev_res["outputPath"]
            print(f"  Preview ready: {preview_path} ({prev_res['width']}x{prev_res['height']} px)")

        # e. Save decision record sidecar
        decision_record = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "workingRef": wref,
            "sourceVariantId": vid,
            "mode": "clone" if args.clone else "existing",
            "cloneVariantId": clone_id,
            "parentImagePath": v.get("parentImagePath"),
            "preset": str(args.preset),
            "beforeAdjustments": mut_res["before"],
            "afterAdjustments": mut_res["after"],
            "diff": mut_res["diff"],
            "previewPath": preview_path,
            "reviewStatus": "pending_photographer_review"
        }
        dec_file = decisions_dir / f"{wref}.json"
        dec_file.write_text(json.dumps(decision_record, indent=2) + "\n")
        print(f"  Saved decision record: {dec_file}")

        results.append(decision_record)

    # Summary
    print("\n=======================================================")
    print("Grading Complete — Summary for Photographer Review:")
    print("=======================================================")
    print(f"{'WORKING REF':<36}  {'SOURCE':<8}  {'STATUS':<10}  {'PREVIEW'}")
    print("-" * 80)
    for r in results:
        prev = r.get("previewPath") or "(dry-run)"
        print(f"{r['workingRef']:<36}  {r['sourceVariantId']:<8}  {'READY':<10}  {prev}")
    if args.clone:
        print("\nReview the clones. To discard one: c1 variant delete <workingRef>")
    else:
        print("\nReview the existing variants and continue editing them in Capture One.")
        print("To restore tone, inspect the saved beforeAdjustments and use set with a fresh stateHash. Do not delete the variants.")

if __name__ == "__main__":
    main()
