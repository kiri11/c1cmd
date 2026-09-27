#!/usr/bin/env python3
"""mcp_test.py: live smoke test for the c1-mcp stdio adapter.

Tool behaviour is covered by the CLI suites through the same core dispatcher. This
suite checks only what the MCP server adds: tool registration, JSON-RPC results and
errors, preview image content, and that one server process compiles the AppleScript
handlers once and reuses them for every later call."""

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
    def __init__(self, bin_path: Path, env=None, stderr=subprocess.PIPE):
        self.proc = subprocess.Popen(
            [str(bin_path)],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
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
            stderr_out = self.proc.stderr.read() if self.proc.stderr else "(redirected to a file)"
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
    print("=== c1-mcp stdio smoke test ===")
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

    # C1_PROFILE traces each compile and Apple Event on stderr, without arguments or paths.
    environment = {k: v for k, v in os.environ.items() if k not in ("C1_TOOL_PROFILE", "C1_MCP_PROFILE", "C1_READ_WORKFLOW")}
    environment["C1_PROFILE"] = "1"
    trace_path = TEST_ROOT / "mcp-trace.jsonl"
    trace = open(trace_path, "w")
    client = MCPClient(MCP_BIN, env=environment, stderr=trace)

    try:
        print("\n[Step 1] Handshake and tool registration...")
        init_resp = client.send_request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "c1-mcp-test", "version": "1.0.0"}
        })
        assert "result" in init_resp, f"Initialize failed: {init_resp}"
        server_info = init_resp["result"].get("serverInfo", {})
        assert server_info.get("name") == "c1-mcp" and server_info.get("version") == "0.1.0", server_info
        assert "tools" in init_resp["result"].get("capabilities", {}), "Missing tools capability"
        client.send_notification("notifications/initialized")
        tools = client.send_request("tools/list", {}).get("result", {}).get("tools", [])
        schema = parse_text_content(client.call_tool("schema").get("content", []))
        client.contract = schema
        assert {t["name"] for t in tools} == set(schema["requests"]) and len(tools) == 35, [t["name"] for t in tools]
        for t in tools:
            assert t.get("description"), f"Tool {t['name']} missing description"
            assert t["inputSchema"] == schema["requests"][t["name"]], t["name"]
        print(f"  ✓ {len(tools)} tools registered from the contract schema")

        print("\n[Step 2] Doctor, document and read tools...")
        doctor = parse_text_content(client.call_tool("doctor").get("content", []))
        assert doctor.get("allChecksPassed") is True, f"Doctor failed: {doctor}"
        doc_data = parse_text_content(client.call_tool("doc_info").get("content", []))
        assert doc_data.get("isSession") is True and doc_data.get("openToken"), doc_data
        variants = []
        for _ in range(12):
            variants = parse_text_content(client.call_tool("variants_list").get("content", []))
            if isinstance(variants, list) and variants:
                break
            time.sleep(0.5)
        assert isinstance(variants, list) and variants, f"Expected variants list, got: {variants}"
        source_id = variants[0]["id"]
        source = parse_text_content(client.call_tool("get", {"ref": source_id}).get("content", []))
        assert len(source.get("stateHash", "")) == 64, source
        for _ in range(2):
            native = parse_text_content(client.call_tool("get", {"ref": source_id, "nativeTargets": [{"scope": "adjustments"}]}).get("content", []))
            assert native["nativeSnapshots"][0]["nativeStateHash"], native
        print(f"  ✓ Doctor passed on build {doctor.get('appVersion')}; read source variant {source_id}")

        print("\n[Step 3] Guard errors come back as tool results...")
        err_res = client.call_tool("set", {"workingRef": source_id, "ifState": source["stateHash"], "adjustments": {"exposure": 0.5}})
        err_payload = parse_text_content(err_res.get("content", []))
        assert err_res.get("isError") is True and err_payload["error"]["code"] == "unmanaged-variant", err_res
        print(f"  ✓ Unmanaged variant mutation blocked: [{err_payload['error']['code']}]")

        print("\n[Step 4] Preview image content on a managed clone...")
        clone_res = client.call_tool("variant_clone", {"sourceRef": source_id})
        assert clone_res.get("isError") is not True, f"Clone failed: {clone_res}"
        clone_data = parse_text_content(clone_res.get("content", []))
        working_ref = clone_data["workingRef"]
        assert working_ref.startswith("c1_wrk_"), clone_data
        preview_res = client.call_tool("preview", {"ref": working_ref, "timeout": 35.0})
        assert preview_res.get("isError") is not True, f"Preview failed: {preview_res}"
        content_items = preview_res.get("content", [])
        preview_data = parse_text_content(content_items)
        assert preview_data["nativeVariantId"] == clone_data["cloneVariantId"], preview_data
        img_block = find_image_content(content_items)
        assert img_block is not None and img_block.get("mimeType") == "image/jpeg", content_items
        raw_bytes = base64.b64decode(img_block.get("data", ""))
        assert len(raw_bytes) == preview_data["fileSizeBytes"], (len(raw_bytes), preview_data["fileSizeBytes"])
        assert raw_bytes[:3] == b"\xff\xd8\xff", "Image content block lacks a JPEG header"
        del_data = parse_text_content(client.call_tool("variant_delete", {"workingRef": working_ref}).get("content", []))
        assert del_data.get("deleted") is True, f"Delete failed: {del_data}"
        print(f"  ✓ Preview returned {len(raw_bytes)} JPEG bytes as image content; clone deleted")

        client.close()
        trace.close()
        print("\n[Step 5] Compiled AppleScript reuse...")
        records = [json.loads(line) for line in trace_path.read_text().splitlines() if line.startswith('{"')]
        records = [r for r in records if r.get("type") == "c1-profile"]
        compiles = [r for r in records if r["phase"] == "script_compile"]
        events = [r for r in records if r["phase"] == "apple_event"]
        assert len({r["pid"] for r in records}) == 1, "Every call must run in one server process"
        # Base and native handlers are separate scripts; each compiles on first use only.
        assert sorted(r["handler"] for r in compiles) == ["base", "native"], compiles
        assert len(events) >= 8, f"Expected Apple Events for every Capture One call, saw {len(events)}"
        print(f"  ✓ Handlers compiled once and reused for {len(events)} Apple Events")

        print("\nALL c1-mcp SMOKE TESTS PASSED SUCCESSFULLY!")

    finally:
        client.close()
        trace.close()
        try:
            run_applescript(f'''
                try
                    close document "{SESSION_NAME}" without saving
                end try
            ''')
            if initial_doc_path and os.path.exists(initial_doc_path):
                run_applescript(f'open POSIX file "{initial_doc_path}"')
        except Exception:
            pass
        time.sleep(1.0)
        shutil.rmtree(TEST_ROOT, ignore_errors=True)

if __name__ == "__main__":
    main()
