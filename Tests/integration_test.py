#!/usr/bin/env python3
"""integration_test.py: End-to-end integration test for c1 CLI in a disposable Session."""

import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
C1_BIN = ROOT / ".build" / "debug" / "c1"
SESSION_DIR = Path("/private/tmp/c1-m1-e2e")
SESSION_NAME = "c1-m1-e2e.cosessiondb"
SOURCE_CR3 = Path("/Users/kiri11/Desktop/papochka/2U6A7082.CR3")

def run_applescript(script: str) -> str:
    res = subprocess.run(["osascript", "-s", "s", "-e", f'tell application "/Applications/Capture One.app"\n{script}\nend tell'], capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"AppleScript error: {res.stderr.strip()}")
    return res.stdout.strip()

def compute_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def run_c1(args: list[str]) -> tuple[int, dict]:
    cmd = [str(C1_BIN)] + args + ["--format", "json"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    parsed = {}
    out = res.stdout.strip()
    if out:
        try:
            parsed = json.loads(out)
        except Exception:
            pass
    if not parsed and res.stderr.strip():
        try:
            parsed = json.loads(res.stderr.strip())
        except Exception:
            pass
    return res.returncode, parsed

def main():
    print("=== c1 M1 End-to-End Integration Verification ===")
    assert C1_BIN.exists(), f"Binary {C1_BIN} does not exist. Run swift build first."
    assert SOURCE_CR3.exists(), f"Source RAW fixture {SOURCE_CR3} does not exist."

    # Record initial open document
    initial_doc = run_applescript('''
        set d to missing value
        try
            set d to current document
        on error
            try
                set d to first document
            end try
        end try
        if d is not missing value then
            return {name of d, path of d}
        else
            return "none"
        end if
    ''')
    print(f"Initial document: {initial_doc}")

    try:
        # 1. Setup disposable session
        print("\n[Step 1] Creating disposable Session at /private/tmp/c1-m1-e2e...")
        if SESSION_DIR.exists():
            shutil.rmtree(SESSION_DIR)
        
        run_applescript(f'make new document with properties {{name:"c1-m1-e2e", kind:session, path:"/private/tmp"}}')
        time.sleep(1.0)
        
        capture_dir = SESSION_DIR / "Capture"
        capture_dir.mkdir(parents=True, exist_ok=True)
        fixture_raw = capture_dir / "fixture.CR3"
        shutil.copy2(SOURCE_CR3, fixture_raw)
        
        baseline_raw_sha = compute_sha256(fixture_raw)
        print(f"Copied RAW fixture: {fixture_raw} (SHA-256: {baseline_raw_sha})")

        # Select collection
        run_applescript(f'''
            set d to document "{SESSION_NAME}"
            set current collection of d to collection "Capture" of d
        ''')
        time.sleep(1.0)

        # 2. c1 doctor
        print("\n[Step 2] Testing c1 doctor...")
        code, doc_res = run_c1(["doctor"])
        assert code == 0, f"doctor failed: {doc_res}"
        assert doc_res.get("allChecksPassed") is True, f"doctor checks failed: {doc_res}"
        print(f"PASS: doctor healthy on {doc_res.get('appVersion')} for session {doc_res.get('docName')}")

        # 3. c1 doc info
        print("\n[Step 3] Testing c1 doc info...")
        code, info_res = run_c1(["doc", "info"])
        assert code == 0, f"doc info failed: {info_res}"
        assert info_res.get("isSession") is True
        assert "c1-m1-e2e" in info_res.get("documentName", "")
        open_token = info_res.get("openToken")
        print(f"PASS: doc info verified (token: {open_token})")

        # 4. c1 variants list
        print("\n[Step 4] Testing c1 variants list...")
        code, vars_res = run_c1(["variants", "list"])
        assert code == 0, f"variants list failed: {vars_res}"
        assert len(vars_res) >= 1, f"Expected at least 1 variant, got {len(vars_res)}"
        source_id = vars_res[0]["id"]
        print(f"PASS: found variant ID {source_id} ({vars_res[0]['name']})")

        # 5. c1 get on original
        print(f"\n[Step 5] Testing c1 get on original variant {source_id}...")
        code, get_orig = run_c1(["get", source_id])
        assert code == 0, f"get failed: {get_orig}"
        baseline_hash = get_orig["stateHash"]
        baseline_adj = get_orig["adjustments"]
        print(f"PASS: initial stateHash: {baseline_hash}, adjustments: {baseline_adj}")

        # 6. c1 variant clone
        print(f"\n[Step 6] Testing c1 variant clone {source_id}...")
        code, clone_res = run_c1(["variant", "clone", source_id])
        assert code == 0, f"variant clone failed: {clone_res}"
        working_ref = clone_res["workingRef"]
        clone_id = clone_res["cloneVariantId"]
        assert working_ref.startswith("c1_wrk_"), f"Invalid working ref: {working_ref}"
        assert clone_id != source_id, "Clone ID must differ from source ID"
        print(f"PASS: created working clone {working_ref} (native ID: {clone_id})")

        # 7. Safety check: reject mutating original variant
        print(f"\n[Step 7] Testing safety check: rejecting mutation to original variant {source_id}...")
        code, rej_res = run_c1(["set", source_id, "--if-state", baseline_hash, "exposure=0.5"])
        assert code == 1, "Direct mutation on original variant must fail!"
        assert rej_res.get("error", {}).get("code") == "unmanaged-variant"
        print(f"PASS: core rejected mutation on original: {rej_res.get('error', {}).get('message')}")

        # 8. c1 set on working variant
        print(f"\n[Step 8] Testing c1 set on working variant {working_ref}...")
        code, set_res = run_c1([
            "set", working_ref,
            "--if-state", baseline_hash,
            "exposure=0.75", "contrast=15.0", "saturation=-10.0", "kelvin=5600", "tint=5.0"
        ])
        assert code == 0, f"set failed: {set_res}"
        after_set_hash = set_res["stateHash"]
        assert after_set_hash != baseline_hash
        assert abs(set_res["after"]["exposure"] - 0.75) < 1e-4
        assert abs(set_res["after"]["contrast"] - 15.0) < 1e-4
        assert abs(set_res["after"]["saturation"] - (-10.0)) < 1e-4
        assert abs(set_res["after"]["temperature"] - 5600.0) < 0.1
        assert abs(set_res["after"]["tint"] - 5.0) < 0.01
        print(f"PASS: set applied accurately (new hash: {after_set_hash})")

        # 9. c1 add on working variant
        print(f"\n[Step 9] Testing c1 add on working variant {working_ref}...")
        code, add_res = run_c1([
            "add", working_ref,
            "--if-state", after_set_hash,
            "exposure=-0.25", "kelvin=+200"
        ])
        assert code == 0, f"add failed: {add_res}"
        after_add_hash = add_res["stateHash"]
        assert after_add_hash != after_set_hash
        assert abs(add_res["after"]["exposure"] - 0.50) < 1e-4
        assert abs(add_res["after"]["temperature"] - 5800.0) < 0.1
        print(f"PASS: add delta applied accurately (0.75 - 0.25 = {add_res['after']['exposure']}, new hash: {after_add_hash})")

        # 10. Optimistic concurrency check: stale hash rejected
        print(f"\n[Step 10] Testing optimistic concurrency conflict detection...")
        code, stale_res = run_c1(["set", working_ref, "--if-state", baseline_hash, "exposure=0.1"])
        assert code == 3, f"Expected exit code 3 for concurrency conflict, got {code}"
        assert stale_res.get("error", {}).get("code") == "state-changed"
        print(f"PASS: stale hash rejected: {stale_res.get('error', {}).get('message')}")

        # 11. c1 preview
        print(f"\n[Step 11] Testing c1 preview on working variant {working_ref}...")
        code, prev_res = run_c1(["preview", working_ref])
        assert code == 0, f"preview failed: {prev_res}"
        preview_file = Path(prev_res["outputPath"])
        assert preview_file.exists(), f"Preview file does not exist: {preview_file}"
        assert preview_file.stat().st_size > 0, "Preview file is empty"
        assert prev_res["width"] > 0 and prev_res["height"] > 0
        assert len(prev_res["pixelSha256"]) == 64
        print(f"PASS: preview generated and decoded: {preview_file} ({prev_res['width']}x{prev_res['height']} px, size: {prev_res['fileSizeBytes']} B)")

        # 12. Invariance verification
        print(f"\n[Step 12] Verifying core invariants (Original variant & RAW file)...")
        code, get_orig_after = run_c1(["get", source_id])
        assert code == 0
        assert get_orig_after["adjustments"] == baseline_adj, f"Original variant changed! Before: {baseline_adj}, After: {get_orig_after['adjustments']}"
        assert get_orig_after["stateHash"] == baseline_hash, "Original variant stateHash changed!"
        
        current_raw_sha = compute_sha256(fixture_raw)
        assert current_raw_sha == baseline_raw_sha, f"RAW file corrupted! Baseline: {baseline_raw_sha}, Current: {current_raw_sha}"
        print("PASS: Original variant adjustments and RAW SHA-256 strictly preserved!")

        # 13. c1 variant delete
        print(f"\n[Step 13] Testing c1 variant delete {working_ref}...")
        code, del_res = run_c1(["variant", "delete", working_ref])
        assert code == 0, f"variant delete failed: {del_res}"
        assert del_res["deleted"] is True
        
        # Verify clone no longer in list
        code, vars_after_del = run_c1(["variants", "list"])
        assert not any(v["id"] == clone_id for v in vars_after_del)
        print(f"PASS: working variant {working_ref} (clone {clone_id}) cleanly deleted.")

        # Re-verify RAW integrity after delete
        assert compute_sha256(fixture_raw) == baseline_raw_sha, "RAW file corrupted after deletion!"
        print("PASS: RAW file still 100% byte-for-byte identical after variant deletion.")

        # 14. Run grade-folder.py workflow
        print("\n[Step 14] Testing examples/grade-folder.py workflow...")
        preset_path = ROOT / "examples" / "presets" / "daylight.json"
        grade_res = subprocess.run([
            sys.executable, str(ROOT / "examples" / "grade-folder.py"),
            "--preset", str(preset_path),
            "--c1-bin", str(C1_BIN)
        ], capture_output=True, text=True)
        assert grade_res.returncode == 0, f"grade-folder.py failed:\n{grade_res.stderr}\n{grade_res.stdout}"
        print(grade_res.stdout)
        print("PASS: examples/grade-folder.py completed successfully!")

        print("\n=======================================================")
        print("ALL M1 INTEGRATION VERIFICATIONS PASSED SUCCESSFULLY!")
        print("=======================================================")

    finally:
        # Cleanup
        print("\n[Cleanup] Cleaning up test session...")
        try:
            run_applescript(f'''
                if exists document "{SESSION_NAME}" then
                    close document "{SESSION_NAME}" without saving
                end if
                if not (exists document "Capture One Catalog") then
                    open POSIX file "/Users/kiri11/Pictures/Capture One Catalog.cocatalog"
                end if
            ''')
        except Exception as e:
            print(f"Cleanup warning: {e}")
        
        if SESSION_DIR.exists():
            shutil.rmtree(SESSION_DIR, ignore_errors=True)
        print("Cleanup completed.")

if __name__ == "__main__":
    main()
