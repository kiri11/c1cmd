#!/usr/bin/env python3
"""mcp_test.py: Automated integration test suite for c1-mcp stdio Model Context Protocol server."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
from contract_test import validate_response

sys.stdout.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[1]
MCP_BIN = Path(os.environ.get("C1_TEST_MCP_BIN", str(ROOT / ".build" / "debug" / "c1-mcp")))
TEST_ROOT = Path(tempfile.mkdtemp(prefix="c1-mcp-e2e-", dir="/private/tmp"))
SESSION_DIR = TEST_ROOT / "c1-mcp-e2e"
SESSION_NAME = "c1-mcp-e2e.cosessiondb"
DISPOSABLE_CAT_NAME = "c1-cat-guard-test"
DISPOSABLE_CAT_DIR = TEST_ROOT / f"{DISPOSABLE_CAT_NAME}.cocatalog"

raw_fixture_env = os.environ.get("C1_TEST_RAW_FIXTURE")
SOURCE_CR3 = Path(raw_fixture_env) if raw_fixture_env else None

def run_applescript(script: str) -> str:
    res = subprocess.run(
        ["osascript", "-s", "s", "-e", f'tell application "/Applications/Capture One.app"\n{script}\nend tell'],
        capture_output=True,
        text=True
    )
    if res.returncode != 0:
        raise RuntimeError(f"AppleScript error: {res.stderr.strip()}")
    return res.stdout.strip()

class MCPClient:
    def __init__(self, bin_path: Path):
        self.proc = subprocess.Popen(
            [str(bin_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=0
        )
        self.msg_id = 0
        self.contract = None

    def send_request(self, method: str, params: dict | None = None) -> dict:
        self.msg_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self.msg_id,
            "method": method
        }
        if params is not None:
            payload["params"] = params
        
        line = json.dumps(payload) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        
        resp_line = self.proc.stdout.readline()
        if not resp_line:
            stderr_out = self.proc.stderr.read()
            raise RuntimeError(f"Server closed connection unexpectedly. Stderr: {stderr_out}")
        
        return json.loads(resp_line.strip())

    def send_notification(self, method: str, params: dict | None = None):
        payload = {
            "jsonrpc": "2.0",
            "method": method
        }
        if params is not None:
            payload["params"] = params
        line = json.dumps(payload) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()

    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        params = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        resp = self.send_request("tools/call", params)
        if "error" in resp:
            raise RuntimeError(f"JSON-RPC protocol error: {resp['error']}")
        result = resp.get("result", {})
        if self.contract is not None:
            payload = parse_text_content(result.get("content", []))
            spec = self.contract['definitions']['Error'] if result.get('isError') else self.contract['responses'][name]
            validate_response(payload, spec, name)
        return result

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()

def parse_text_content(content_items: list[dict]) -> dict | list | str:
    for item in content_items:
        if item.get("type") == "text":
            text = item.get("text", "")
            try:
                return json.loads(text)
            except Exception:
                return text
    return {}

def find_image_content(content_items: list[dict]) -> dict | None:
    for item in content_items:
        if item.get("type") == "image":
            return item
    return None

def main():
    print("=== c1-mcp Stdio Server Comprehensive Test Suite ===")
    assert MCP_BIN.exists(), f"Binary {MCP_BIN} does not exist. Run 'swift build' first."
    if SOURCE_CR3 is None or not SOURCE_CR3.exists():
        print("\n[ERROR] C1_TEST_RAW_FIXTURE environment variable not set or file not found.")
        print("Live MCP integration tests require a local RAW image (e.g. Canon CR3, Nikon NEF, Sony ARW).")
        print("Usage:")
        print("  export C1_TEST_RAW_FIXTURE=/path/to/image.CR3")
        print("  python3 Tests/mcp_test.py\n")
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

    # Setup disposable session
    print("\n[Step 0] Creating disposable Session at /private/tmp/c1-mcp-e2e...")
    try:
        run_applescript(f'''
            try
                close document "{SESSION_NAME}" without saving
            end try
        ''')
    except Exception:
        pass
    if SESSION_DIR.exists():
        shutil.rmtree(SESSION_DIR, ignore_errors=True)
    
    run_applescript(f'make new document with properties {{name:"c1-mcp-e2e", kind:session, path:"{TEST_ROOT}"}}')
    time.sleep(1.0)
    
    capture_dir = SESSION_DIR / "Capture"
    capture_dir.mkdir(parents=True, exist_ok=True)
    fixture_raw = capture_dir / ("fixture" + SOURCE_CR3.suffix)
    shutil.copy2(SOURCE_CR3, fixture_raw)
    
    run_applescript(f'''
        set d to document "{SESSION_NAME}"
        set current collection of d to collection "Capture" of d
    ''')
    time.sleep(1.0)

    print("Waiting for Capture One to index fixture variant...")
    for _ in range(20):
        res = subprocess.run([os.environ.get("C1_TEST_BIN", str(ROOT / ".build" / "debug" / "c1")), "variants", "list", "--format", "json"], capture_output=True, text=True)
        if "fixture" in res.stdout:
            print("  ✓ RAW variant indexed by Capture One")
            break
        time.sleep(0.5)

    client = MCPClient(MCP_BIN)
    passed_tests = 0
    total_tests = 0

    try:
        # 1. Initialize Handshake
        print("\n[Step 1] Testing MCP initialization handshake...")
        total_tests += 1
        init_resp = client.send_request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "c1-mcp-test", "version": "1.0.0"}
        })
        assert "result" in init_resp, f"Initialize failed: {init_resp}"
        result = init_resp["result"]
        server_info = result.get("serverInfo", {})
        assert server_info.get("name") == "c1-mcp", f"Unexpected server name: {server_info}"
        assert server_info.get("version") == "0.1.0", f"Unexpected server version: {server_info}"
        assert "tools" in result.get("capabilities", {}), "Missing tools capability"
        client.send_notification("notifications/initialized")
        print("  ✓ Handshake successful: c1-mcp v0.1.0 ready")
        passed_tests += 1

        # 2. Tools List & Schema Verification
        print("\n[Step 2] Testing tools/list and schema inspection...")
        total_tests += 1
        tools_resp = client.send_request("tools/list", {})
        tools = tools_resp.get("result", {}).get("tools", [])
        tool_names = {t["name"] for t in tools}
        expected_tools = {
            "doctor", "doc_info", "capabilities", "schema",
            "variants_list", "variant_edit", "geometry_restore", "variant_clone", "variant_delete", "variant_baseline",
            "get", "set", "add", "reset", "diff", "dump", "preview", "operation_status"
        }
        missing = expected_tools - tool_names
        assert not missing, f"Missing required tools in tools/list: {missing}"
        assert len(tools) == 19, f"Expected 19 tools, found {len(tools)}"
        for t in tools:
            assert "description" in t and t["description"], f"Tool {t['name']} missing description"
            assert "inputSchema" in t and isinstance(t["inputSchema"], dict), f"Tool {t['name']} invalid schema"
        print(f"  ✓ All 19 tools discovered with complete schemas: {sorted(list(tool_names))}")
        passed_tests += 1

        # 3. Read-Only Tools (capabilities, schema, doc_info)
        print("\n[Step 3] Testing read-only metadata tools...")
        total_tests += 1
        caps_res = client.call_tool("capabilities")
        caps_data = parse_text_content(caps_res.get("content", []))
        assert "pinnedBuild" in caps_data and "supportedFields" in caps_data, f"Invalid capabilities output: {caps_data}"

        schema_res = client.call_tool("schema")
        schema_data = parse_text_content(schema_res.get("content", []))
        client.contract = schema_data
        assert schema_data.get("title") == "c1-contract-schema", f"Invalid schema title: {schema_data}"

        doc_res = client.call_tool("doc_info")
        doc_data = parse_text_content(doc_res.get("content", []))
        assert "documentName" in doc_data and "openToken" in doc_data, f"Invalid doc_info: {doc_data}"
        assert doc_data.get("isSession") is True
        print(f"  ✓ Metadata tools verified. Active Session: '{doc_data['documentName']}' (token: {doc_data['openToken']})")
        passed_tests += 1

        # 4. Doctor Tool
        print("\n[Step 4] Testing doctor tool...")
        total_tests += 1
        doc_report_res = client.call_tool("doctor")
        doc_report = parse_text_content(doc_report_res.get("content", []))
        assert doc_report.get("appRunning") is True, f"Doctor failed: {doc_report}"
        assert doc_report.get("hasDocument") is True, f"Doctor failed: {doc_report}"
        assert doc_report.get("allChecksPassed") is True, f"Doctor failed: {doc_report}"
        print(f"  ✓ Doctor diagnostic passed. Build: {doc_report.get('appVersion')} (matched: {doc_report.get('exactBuildMatched')})")
        passed_tests += 1

        # 5. Variants List & Dump Tools
        print("\n[Step 5] Testing variants_list and dump tools...")
        total_tests += 1
        variants = []
        for _ in range(12):
            list_res = client.call_tool("variants_list")
            variants = parse_text_content(list_res.get("content", []))
            if isinstance(variants, list) and len(variants) > 0:
                break
            time.sleep(0.5)
        assert isinstance(variants, list) and len(variants) > 0, f"Expected variants list, got: {variants}"
        source_variant = variants[0]
        source_id = source_variant["id"]
        print(f"  ✓ Listed {len(variants)} variant(s). Source ID '{source_id}', Name '{source_variant.get('name')}'")

        dump_res = client.call_tool("dump", {"batchSize": 5})
        dump_records = parse_text_content(dump_res.get("content", []))
        assert isinstance(dump_records, list) and len(dump_records) > 0, f"Dump failed: {dump_records}"
        assert "adjustments" in dump_records[0] and "metadata" in dump_records[0], "Dump record missing adjustments/metadata"
        print(f"  ✓ Dump returned {len(dump_records)} comprehensive record(s)")
        passed_tests += 1

        # 6. Safety & Guard Verification (Mutating unmanaged variant must fail closed)
        print("\n[Step 6] Testing safety guard: rejecting mutation on unmanaged variant...")
        total_tests += 1
        err_res = client.call_tool("set", {
            "workingRef": source_id,
            "ifState": "dummyhash",
            "adjustments": {"exposure": 0.5}
        })
        assert err_res.get("isError") is True, f"Expected isError=True on unmanaged variant, got: {err_res}"
        err_payload = parse_text_content(err_res.get("content", []))
        assert isinstance(err_payload, dict) and err_payload.get("error", {}).get("code") == "unmanaged-variant", (
            f"Expected error code 'unmanaged-variant', got: {err_payload}"
        )
        print(f"  ✓ Unmanaged variant mutation blocked: [{err_payload['error']['code']}] {err_payload['error']['message']}")
        passed_tests += 1

        # 7. Working Variant Clone & Baseline Creation
        print("\n[Step 7] Testing variant_clone, variant_baseline, and get tools...")
        total_tests += 1
        # Test clone
        clone_res = client.call_tool("variant_clone", {"sourceRef": source_id})
        assert clone_res.get("isError") is not True, f"Clone failed: {clone_res}"
        clone_data = parse_text_content(clone_res.get("content", []))
        working_ref = clone_data.get("workingRef")
        baseline_hash = clone_data.get("baselineStateHash")
        assert working_ref and working_ref.startswith("c1_wrk_"), f"Invalid workingRef: {clone_data}"
        assert baseline_hash and len(baseline_hash) == 64, f"Invalid baseline hash: {clone_data}"
        print(f"  ✓ Created working clone: {working_ref} (baseline hash: {baseline_hash[:12]}...)")

        # Test baseline variant
        base_res = client.call_tool("variant_baseline", {"sourceRef": source_id})
        assert base_res.get("isError") is not True, f"Baseline failed: {base_res}"
        base_data = parse_text_content(base_res.get("content", []))
        base_ref = base_data.get("workingRef")
        print(f"  ✓ Created managed baseline variant: {base_ref}")

        # Test get
        get_res = client.call_tool("get", {"ref": working_ref})
        get_data = parse_text_content(get_res.get("content", []))
        assert get_data.get("workingRef") == working_ref, f"Mismatched workingRef: {get_data}"
        assert get_data.get("stateHash") == baseline_hash, f"Initial stateHash != baseline: {get_data}"
        passed_tests += 1

        # 8. Mutation (Set, Add, Diff, Reset)
        print("\n[Step 8] Testing set, add, diff, and reset tools on working clone...")
        total_tests += 1
        # Set mutation
        set_res = client.call_tool("set", {
            "workingRef": working_ref,
            "ifState": baseline_hash,
            "adjustments": {
                "exposure": 0.35,
                "contrast": 8.0,
                "saturation": -5.0
            }
        })
        assert set_res.get("isError") is not True, f"Set failed: {set_res}"
        set_data = parse_text_content(set_res.get("content", []))
        after_hash = set_data.get("stateHash")
        assert after_hash != baseline_hash, f"State hash did not change after set: {set_data}"
        assert abs(set_data.get("diff", {}).get("exposure", {}).get("after", 0) - 0.35) < 1e-4, f"Unexpected exposure diff: {set_data.get('diff')}"
        print(f"  ✓ 'set' applied successfully. New stateHash: {after_hash[:12]}...")

        # Diff against baseline
        diff_res = client.call_tool("diff", {"ref1": working_ref})
        diff_data = parse_text_content(diff_res.get("content", []))
        assert "exposure" in diff_data.get("diff", {}), f"Diff missing exposure change: {diff_data}"
        print("  ✓ 'diff' against baseline confirmed changed adjustments")

        # Add relative delta
        add_res = client.call_tool("add", {
            "workingRef": working_ref,
            "ifState": after_hash,
            "adjustments": {
                "exposure": -0.10
            }
        })
        assert add_res.get("isError") is not True, f"Add failed: {add_res}"
        add_data = parse_text_content(add_res.get("content", []))
        final_hash = add_data.get("stateHash")
        assert final_hash != after_hash, f"State hash did not change after add: {add_data}"
        current_exp = add_data.get("after", {}).get("exposure")
        assert current_exp is not None and abs(current_exp - 0.25) < 1e-4, f"Expected exposure 0.25, got {current_exp}"
        print(f"  ✓ 'add' delta applied (-0.10 EV -> {current_exp} EV)")

        # Reset mutation
        reset_res = client.call_tool("reset", {
            "workingRef": working_ref,
            "ifState": final_hash
        })
        assert reset_res.get("isError") is not True, f"Reset failed: {reset_res}"
        reset_data = parse_text_content(reset_res.get("content", []))
        assert reset_data.get("stateHash") == baseline_hash, f"Reset hash != baseline: {reset_data}"
        print(f"  ✓ 'reset' restored adjustments to baseline stateHash: {reset_data.get('stateHash')[:12]}...")
        passed_tests += 1

        # 9. Preview (with Image Block) & Variant Delete
        print("\n[Step 9] Testing preview (with MCP image block) and variant_delete...")
        total_tests += 1
        custom_preview_dir = SESSION_DIR / "custom-preview"
        custom_preview_dir.mkdir()
        (custom_preview_dir / "stale.jpg").write_bytes(b"not the requested image")
        preview_res = client.call_tool("preview", {
            "ref": working_ref,
            "outputDir": str(custom_preview_dir),
            "timeout": 35.0
        })
        assert preview_res.get("isError") is not True, f"Preview failed: {preview_res}"
        content_items = preview_res.get("content", [])
        
        # Verify JSON metadata text block
        preview_data = parse_text_content(content_items)
        assert Path(preview_data["outputPath"]).is_relative_to(custom_preview_dir / "c1-previews")
        assert preview_data["nativeVariantId"] == clone_data["cloneVariantId"]
        assert preview_data["stateHash"] == reset_data["stateHash"]
        assert "outputPath" in preview_data and "pixelSha256" in preview_data, f"Invalid preview metadata: {preview_data}"
        assert preview_data.get("width", 0) > 0 and preview_data.get("height", 0) > 0
        print(f"  ✓ Preview metadata: {preview_data['width']}x{preview_data['height']} ({preview_data['fileSizeBytes']} bytes), SHA-256: {preview_data['pixelSha256'][:12]}...")

        # Verify binary JPEG Image content block
        img_block = find_image_content(content_items)
        assert img_block is not None, f"Missing image content block in preview response: {content_items}"
        assert img_block.get("mimeType") == "image/jpeg", f"Expected mimeType 'image/jpeg', got {img_block.get('mimeType')}"
        img_b64 = img_block.get("data", "")
        raw_bytes = base64.b64decode(img_b64)
        assert len(raw_bytes) == preview_data["fileSizeBytes"], f"Decoded image size {len(raw_bytes)} != file size {preview_data['fileSizeBytes']}"
        assert raw_bytes[:3] == b"\xff\xd8\xff", "Image content block lacks valid JPEG magic header (FF D8 FF)"
        print(f"  ✓ Image content block validated: {len(raw_bytes)} bytes base64-decoded, valid JPEG header confirmed")

        # Delete working clone
        del_res = client.call_tool("variant_delete", {"workingRef": working_ref})
        assert del_res.get("isError") is not True, f"Delete failed: {del_res}"
        del_data = parse_text_content(del_res.get("content", []))
        assert del_data.get("deleted") is True, f"Delete returned false: {del_data}"
        print(f"  ✓ Cleaned up working clone {working_ref}")

        # Delete baseline clone
        del_base_res = client.call_tool("variant_delete", {"workingRef": base_ref})
        assert del_base_res.get("isError") is not True, f"Baseline delete failed: {del_base_res}"
        print(f"  ✓ Cleaned up baseline variant {base_ref}")
        passed_tests += 1

        client.close()

        # 10. Catalog Read-Only Guard Verification over MCP
        print("\n[Step 10] Testing Catalog fail-closed mutation guard over MCP...")
        total_tests += 1
        # Close test session and create disposable test Catalog
        if DISPOSABLE_CAT_DIR.exists():
            shutil.rmtree(DISPOSABLE_CAT_DIR, ignore_errors=True)
        run_applescript(f'''
            try
                close document "{SESSION_NAME}" without saving
            end try
            make new document with properties {{name:"{DISPOSABLE_CAT_NAME}", kind:catalog, path:"{TEST_ROOT}"}}
        ''')
        time.sleep(1.5)

        # Launch fresh MCP client on Catalog
        cat_client = MCPClient(MCP_BIN)
        try:
            cat_client.send_request("initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "c1-mcp-cat-test", "version": "1.0.0"}
            })
            cat_client.send_notification("notifications/initialized")

            cat_doc = cat_client.call_tool("doc_info")
            cat_doc_data = parse_text_content(cat_doc.get("content", []))
            assert cat_doc_data.get("isSession") is False, f"Expected Catalog, got session: {cat_doc_data}"
            print(f"  ✓ Open document is Catalog: '{cat_doc_data['documentName']}'")

            # Try mutating a Catalog variant -> must be rejected by session writable guard
            cat_err = cat_client.call_tool("variant_clone", {"sourceRef": "1"})
            assert cat_err.get("isError") is True, f"Expected mutation on Catalog to fail, got: {cat_err}"
            cat_err_data = parse_text_content(cat_err.get("content", []))
            assert "Catalogs are strictly read-only" in cat_err_data.get("error", {}).get("message", ""), (
                f"Expected 'Catalogs are strictly read-only' error message, got: {cat_err_data}"
            )
            print(f"  ✓ Catalog mutation guard verified over MCP: {cat_err_data['error']['message']}")
            geometry_err = cat_client.call_tool("geometry_set", {"workingRef":"1", "ifGeometryState":"dummy", "rotation":1})
            assert geometry_err.get("isError")
            assert "Catalogs are strictly read-only" in parse_text_content(geometry_err['content'])['error']['message']
            passed_tests += 1
        finally:
            cat_client.close()

        print("\n=======================================================")
        print("ALL c1-mcp INTEGRATION TESTS PASSED SUCCESSFULLY!")
        print(f"Total Test Steps : {total_tests}")
        print(f"Passed           : {passed_tests}")
        print("=======================================================")

    finally:
        try:
            run_applescript(f'''
                try
                    close document "{SESSION_NAME}" without saving
                end try
                if exists document "{DISPOSABLE_CAT_NAME}" then
                    close document "{DISPOSABLE_CAT_NAME}" without saving
                end if
            ''')
            if initial_doc_path and os.path.exists(initial_doc_path):
                run_applescript(f'open POSIX file "{initial_doc_path}"')
        except Exception:
            pass
        time.sleep(1.0)
        if SESSION_DIR.exists():
            shutil.rmtree(SESSION_DIR, ignore_errors=True)
        if DISPOSABLE_CAT_DIR.exists():
            shutil.rmtree(DISPOSABLE_CAT_DIR, ignore_errors=True)

        shutil.rmtree(TEST_ROOT, ignore_errors=True)

if __name__ == "__main__":
    main()
