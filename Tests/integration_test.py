#!/usr/bin/env python3
"""integration_test.py: End-to-end integration test for c1 CLI in a disposable Session."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
from contract_test import validate_response

ROOT = Path(__file__).resolve().parents[1]
C1_BIN = Path(os.environ.get("C1_TEST_BIN", str(ROOT / ".build" / "debug" / "c1")))
TEST_ROOT = Path(tempfile.mkdtemp(prefix="c1-m1-e2e-", dir="/private/tmp"))
SESSION_DIR = TEST_ROOT / "c1-m1-e2e"
SESSION_NAME = "c1-m1-e2e.cosessiondb"
DISPOSABLE_CAT_NAME = "c1-cat-guard-test"
DISPOSABLE_CAT_DIR = TEST_ROOT / f"{DISPOSABLE_CAT_NAME}.cocatalog"

raw_fixture_env = os.environ.get("C1_TEST_RAW_FIXTURE")
SOURCE_CR3 = Path(raw_fixture_env) if raw_fixture_env else None
CONTRACT = None

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
    if CONTRACT is not None and parsed:
        name = {'doc': 'doc_info', 'variants': 'variants_list', 'variant': 'variant_' + args[1]}.get(args[0], args[0]) if len(args) > 1 else args[0]
        schema = CONTRACT['definitions']['Error'] if 'error' in parsed else CONTRACT['responses'].get(name)
        if schema: validate_response(parsed, schema, name)
    return res.returncode, parsed

def run_c1_raw(args: list[str]) -> tuple[int, str, str]:
    cmd = [str(C1_BIN)] + args
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode, res.stdout.strip(), res.stderr.strip()

def main():
    global CONTRACT
    CONTRACT = json.loads(subprocess.check_output([str(C1_BIN), "schema"], text=True))
    print("=== c1 M1 End-to-End Integration Verification ===")
    assert C1_BIN.exists(), f"Binary {C1_BIN} does not exist. Run swift build first."
    if SOURCE_CR3 is None or not SOURCE_CR3.exists():
        print("\n[ERROR] C1_TEST_RAW_FIXTURE environment variable not set or file not found.")
        print("Live integration tests require a local RAW image (e.g. Canon CR3, Nikon NEF, Sony ARW).")
        print("Usage:")
        print("  export C1_TEST_RAW_FIXTURE=/path/to/image.CR3")
        print("  python3 Tests/integration_test.py\n")
        sys.exit(1)

    # Record initial open document
    initial_doc_path = None
    try:
        doc_path_out = run_applescript('''
            set d to missing value
            try
                set d to current document
            on error
                try
                    set d to first document
                end try
            end try
            if d is not missing value then
                set docIdentity to id of d as text
                set docTitle to name of d as text
                if docTitle ends with ".cosessiondb" and docIdentity does not end with ".cosessiondb" then
                    return docIdentity & "/" & docTitle
                end if
                return docIdentity
            else
                return "none"
            end if
        ''')
        doc_path_out = json.loads(doc_path_out) if doc_path_out.startswith('"') else doc_path_out
        if doc_path_out and doc_path_out != "none":
            initial_doc_path = doc_path_out
    except Exception:
        pass
    print(f"Initial document path: {initial_doc_path}")

    try:
        # 1. Setup disposable session
        print("\n[Step 1] Creating disposable Session at /private/tmp/c1-m1-e2e...")
        if SESSION_DIR.exists():
            shutil.rmtree(SESSION_DIR)
        
        run_applescript(f'make new document with properties {{name:"c1-m1-e2e", kind:session, path:"{TEST_ROOT}"}}')
        time.sleep(1.0)
        
        capture_dir = SESSION_DIR / "Capture"
        capture_dir.mkdir(parents=True, exist_ok=True)
        fixture_raw = capture_dir / ("fixture" + SOURCE_CR3.suffix)
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
        vars_res = []
        code = 1
        for _ in range(12):
            code, vars_res = run_c1(["variants", "list"])
            if code == 0 and len(vars_res) >= 1:
                break
            time.sleep(0.5)
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

        custom_dir = SESSION_DIR / "custom-preview"
        custom_dir.mkdir()
        stale = custom_dir / "old.jpg"
        shutil.copy2(preview_file, stale)
        code, custom_preview = run_c1(["preview", working_ref, "--output-dir", str(custom_dir)])
        assert code == 0, custom_preview
        assert Path(custom_preview["outputPath"]).is_relative_to(custom_dir / "c1-previews")
        assert custom_preview["outputPath"] != str(stale)
        assert custom_preview["nativeVariantId"] == clone_id
        assert custom_preview["stateHash"] == after_add_hash
        print("PASS: custom output routing ignores stale JPEG and associates variant/state")

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
            "--preset", str(preset_path), "--clone",
            "--c1-bin", str(C1_BIN)
        ], capture_output=True, text=True)
        assert grade_res.returncode == 0, f"grade-folder.py failed:\n{grade_res.stderr}\n{grade_res.stdout}"
        print(grade_res.stdout)
        print("PASS: examples/grade-folder.py completed successfully!")

        # =========================================================================
        # MILESTONE 2 VERIFICATION STEPS
        # =========================================================================

        # 15. Baseline Variant Creation (c1 variant baseline)
        print("\n[Step 15] Testing c1 variant baseline on source variant...")
        code, base_res = run_c1(["variant", "baseline", source_id])
        assert code == 0, f"variant baseline failed: {base_res}"
        base_wrk_ref = base_res["workingRef"]
        base_variant_id = base_res["cloneVariantId"]
        assert base_wrk_ref.startswith("c1_wrk_")
        assert base_variant_id != source_id
        base_hash = base_res["baselineStateHash"]
        print(f"PASS: created managed baseline variant {base_wrk_ref} (native ID: {base_variant_id})")

        code, get_base = run_c1(["get", base_wrk_ref])
        assert code == 0
        assert get_base["workingRef"] == base_wrk_ref
        print(f"PASS: retrieved baseline adjustments: {get_base['adjustments']}")

        # 16. Adjustment Diffing (c1 diff)
        print(f"\n[Step 16] Testing c1 diff on mutated working variant...")
        # Mutate the baseline variant first
        code, set_m2_res = run_c1([
            "set", base_wrk_ref,
            "--if-state", base_hash,
            "exposure=0.60", "contrast=12.0", "saturation=-8.0", "kelvin=6100", "tint=4.0"
        ])
        assert code == 0, f"set failed on baseline variant: {set_m2_res}"
        mutated_m2_hash = set_m2_res["stateHash"]

        # Single-reference diff (working variant vs its baseline)
        code, diff_res = run_c1(["diff", base_wrk_ref])
        assert code == 0, f"diff failed: {diff_res}"
        assert diff_res["ref1"] == "baseline"
        assert diff_res["ref2"] == base_wrk_ref
        assert "exposure" in diff_res["diff"]
        assert abs(diff_res["diff"]["exposure"]["delta"] - 0.60) < 1e-4
        assert "contrast" in diff_res["diff"]
        assert "saturation" in diff_res["diff"]
        print("PASS: single-ref diff accurately computed against baseline")

        # Two-reference diff (source variant vs baseline variant)
        code, diff_2res = run_c1(["diff", source_id, base_variant_id])
        assert code == 0, f"two-ref diff failed: {diff_2res}"
        assert diff_2res["ref1"] == source_id
        assert diff_2res["ref2"] == base_variant_id
        print(f"PASS: two-ref diff accurately computed between native variants {source_id} and {base_variant_id}")

        # Human-formatted diff
        code, human_diff_out, _ = run_c1_raw(["diff", base_wrk_ref, "--format", "human"])
        assert code == 0
        assert "Variant Adjustments Diff" in human_diff_out
        assert "exposure" in human_diff_out
        print("PASS: human-formatted diff output verified")

        # 17. Adjustment Reset (c1 reset)
        print(f"\n[Step 17] Testing c1 reset on mutated working variant...")
        # Selective reset: exposure only
        code, reset_sel_res = run_c1(["reset", base_wrk_ref, "--if-state", mutated_m2_hash, "exposure"])
        assert code == 0, f"selective reset failed: {reset_sel_res}"
        after_sel_hash = reset_sel_res["stateHash"]
        assert abs(reset_sel_res["after"]["exposure"] - 0.0) < 1e-4
        assert abs(reset_sel_res["after"]["contrast"] - 12.0) < 1e-4  # contrast untouched
        print("PASS: selective reset of exposure verified (contrast remained untouched)")

        # Full reset: all fields back to baseline
        code, reset_full_res = run_c1(["reset", base_wrk_ref, "--if-state", after_sel_hash])
        assert code == 0, f"full reset failed: {reset_full_res}"
        assert abs(reset_full_res["after"]["exposure"] - 0.0) < 1e-4
        assert abs(reset_full_res["after"]["contrast"] - 0.0) < 1e-4
        assert abs(reset_full_res["after"]["saturation"] - 0.0) < 1e-4
        assert reset_full_res["stateHash"] == base_hash, f"Full reset stateHash ({reset_full_res['stateHash']}) does not match baseline ({base_hash})"
        print(f"PASS: full reset restored all fields and returned stateHash to baseline {base_hash}")

        # Delete baseline variant
        code, del_base_res = run_c1(["variant", "delete", base_wrk_ref])
        assert code == 0

        # 18. Bulk JSONL Dump (c1 dump)
        print("\n[Step 18] Testing c1 dump in Session...")
        code, dump_raw, _ = run_c1_raw(["dump"])
        assert code == 0, f"dump failed: {dump_raw}"
        dump_lines = [line.strip() for line in dump_raw.splitlines() if line.strip()]
        assert len(dump_lines) >= 1, f"Expected at least 1 dump record, got {len(dump_lines)}"
        first_record = json.loads(dump_lines[0])
        assert "id" in first_record
        assert "name" in first_record
        assert "adjustments" in first_record
        assert "metadata" in first_record
        assert "stateHash" in first_record
        print(f"PASS: c1 dump produced {len(dump_lines)} valid JSONL records")

        # Dump human format
        code, human_dump_out, _ = run_c1_raw(["dump", "--dump-format", "human"])
        assert code == 0
        assert "Total variants dumped:" in human_dump_out
        print("PASS: c1 dump human table verified")

        # 19. Catalog Read-Only Detection & Mutation Guards
        print("\n[Step 19] Testing Catalog read-only detection & mutation guards...")
        # Close test session and create disposable test Catalog
        if DISPOSABLE_CAT_DIR.exists():
            shutil.rmtree(DISPOSABLE_CAT_DIR, ignore_errors=True)
        run_applescript(f'''
            if exists document "{SESSION_NAME}" then
                close document "{SESSION_NAME}" without saving
            end if
            make new document with properties {{name:"{DISPOSABLE_CAT_NAME}", kind:catalog, path:"{TEST_ROOT}"}}
        ''')
        cat_doc_res = {}
        code = 1
        for _ in range(10):
            code, cat_doc_res = run_c1(["doctor"])
            if code == 0 and cat_doc_res.get("allChecksPassed") and not cat_doc_res.get("isSession"):
                break
            time.sleep(0.5)
        assert code == 0, f"doctor failed on catalog: {cat_doc_res}"
        assert cat_doc_res.get("allChecksPassed") is True
        assert cat_doc_res.get("isSession") is False
        assert DISPOSABLE_CAT_NAME in cat_doc_res.get("docName", "")
        print("PASS: c1 doctor passes on Catalog (isSession=False, allChecksPassed=True)")

        # doc info on catalog
        code, cat_info_res = run_c1(["doc", "info"])
        assert code == 0
        assert cat_info_res.get("isSession") is False
        assert DISPOSABLE_CAT_NAME in cat_info_res.get("documentName", "")
        print("PASS: c1 doc info returns isSession=False on Catalog")

        # Test mutation guards on Catalog
        # 1. clone
        code, err_res = run_c1(["variant", "clone", "1"])
        assert code != 0
        err_code = err_res.get("error", {}).get("code")
        assert err_code == "invalid-request", f"Expected 'invalid-request', got {err_code}"
        print(f"PASS: Catalog guard strictly blocked clone ({err_res.get('error', {}).get('message')})")

        # 2. mutate (set)
        code, err_res = run_c1(["set", "1", "exposure=0.5", "--if-state", "dummy"])
        assert code != 0
        err_code = err_res.get("error", {}).get("code")
        assert err_code == "invalid-request", f"Expected 'invalid-request', got {err_code}"
        print(f"PASS: Catalog guard strictly blocked set ({err_res.get('error', {}).get('message')})")

        # 3. reset
        code, err_res = run_c1(["reset", "1", "exposure", "--if-state", "dummy"])
        assert code != 0
        err_code = err_res.get("error", {}).get("code")
        assert err_code == "invalid-request", f"Expected 'invalid-request', got {err_code}"
        print(f"PASS: Catalog guard strictly blocked reset ({err_res.get('error', {}).get('message')})")

        # 4. baseline
        code, err_res = run_c1(["variant", "baseline", "1"])
        assert code != 0
        err_code = err_res.get("error", {}).get("code")
        assert err_code == "invalid-request", f"Expected 'invalid-request', got {err_code}"
        print(f"PASS: Catalog guard strictly blocked baseline ({err_res.get('error', {}).get('message')})")

        # 5. delete
        code, err_res = run_c1(["variant", "delete", "1"])
        assert code != 0
        err_code = err_res.get("error", {}).get("code")
        assert err_code == "invalid-request", f"Expected 'invalid-request', got {err_code}"
        print(f"PASS: Catalog guard strictly blocked delete ({err_res.get('error', {}).get('message')})")

        # Test all remaining mutation subcommands
        for op_name, op_args in [("add", ["add", "1", "exposure=0.1", "--if-state", "dummy"]), ("geometry", ["geometry", "set", "1", "--if-geometry-state", "dummy", "--rotation", "1"])]:
            code, err_res = run_c1(op_args)
            assert code != 0
            err_code = err_res.get("error", {}).get("code")
            err_msg = err_res.get("error", {}).get("message", "")
            assert err_code == "invalid-request", f"Expected 'invalid-request' for {op_name}, got {err_code}"
            assert "read-only" in err_msg.lower() or "catalog" in err_msg.lower(), f"Unexpected error msg: {err_msg}"
            print(f"PASS: Catalog guard strictly blocked '{op_name}' ({err_msg})")

        print("\n=======================================================")
        print("ALL M1 & M2 INTEGRATION VERIFICATIONS PASSED SUCCESSFULLY!")
        print("=======================================================")

    finally:
        # Cleanup
        print("\n[Cleanup] Cleaning up test session and temporary documents...")
        try:
            run_applescript(f'''
                if exists document "{SESSION_NAME}" then
                    close document "{SESSION_NAME}" without saving
                end if
                if exists document "{DISPOSABLE_CAT_NAME}" then
                    close document "{DISPOSABLE_CAT_NAME}" without saving
                end if
            ''')
            if initial_doc_path and os.path.exists(initial_doc_path):
                run_applescript(f'open POSIX file "{initial_doc_path}"')
        except Exception as e:
            print(f"Cleanup warning: {e}")
        
        if SESSION_DIR.exists():
            shutil.rmtree(SESSION_DIR, ignore_errors=True)
        if DISPOSABLE_CAT_DIR.exists():
            shutil.rmtree(DISPOSABLE_CAT_DIR, ignore_errors=True)
        shutil.rmtree(TEST_ROOT, ignore_errors=True)
        print("Cleanup completed.")

if __name__ == "__main__":
    main()
