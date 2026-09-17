#!/usr/bin/env python3
"""Live read-only MCP progress/status/cancellation checks inside the inventory harness's disposable Session."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MCP = Path(os.environ.get("C1_TEST_MCP_BIN", ROOT / ".build/debug/c1-mcp"))


class Wire:
    def __init__(self, env):
        self.process = subprocess.Popen([str(MCP)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def read(self, timeout=30):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and self.selector.select(remaining), "MCP response/progress timed out"
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, "MCP disconnected"
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.selector.close()


def run(status_dir, expected_count):
    wire = Wire(dict(os.environ, C1_REQUEST_DIR=str(status_dir), C1_PROGRESS="quiet"))
    try:
        wire.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                 "clientInfo": {"name": "inventory-live-test", "version": "1"}}, 1)
        assert wire.read()["id"] == 1
        wire.send("notifications/initialized", {})
        started = time.monotonic()
        wire.send("tools/call", {"name": "variants_list", "arguments": {"rating": 5, "batchSize": 1},
                                 "_meta": {"progressToken": "cancel-scan"}}, 2)
        first = wire.read()
        assert first.get("method") == "notifications/progress", first
        assert first["params"]["progressToken"] == "cancel-scan"
        request_id = first["params"]["message"].split(":", 1)[0]
        first_progress = time.monotonic() - started
        # Wait for real completed work: the synchronous inventory loop now owns
        # the main actor, so the following status request must bypass that actor.
        while first["params"]["progress"] == 0:
            first = wire.read()
            assert first.get("method") == "notifications/progress", first
            assert first["params"]["progressToken"] == "cancel-scan", first
        wire.send("tools/call", {"name": "request_status", "arguments": {"requestId": request_id}}, 3)
        while True:
            message = wire.read()
            assert message.get("id") != 2, "Inventory completed before concurrent status was served"
            if message.get("id") == 3:
                status = json.loads(message["result"]["content"][0]["text"])
                assert status["status"] == "running", status
                break
        wire.send("notifications/cancelled", {"requestId": 2, "reason": "live read cancellation test"})
        # Status reads are entirely local; no competing Capture One operation is sent.
        path = Path(status_dir) / (request_id + ".json")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = json.loads(path.read_text())
            if status["status"] != "running":
                break
            time.sleep(.05)
        assert status["status"] == "cancelled", status
        assert status["summariesCompleted"] < expected_count, status

        wire.send("tools/call", {"name": "variants_list", "arguments": {"rating": 5, "batchSize": 8},
                                 "_meta": {"progressToken": 77}}, 4)
        values = []
        while True:
            message = wire.read(timeout=120)
            if message.get("method") == "notifications/progress" and message["params"]["progressToken"] == 77:
                values.append(message["params"]["progress"])
            if message.get("id") == 4:
                assert not message["result"].get("isError"), message
                result = json.loads(message["result"]["content"][0]["text"])
                assert len(result) == expected_count, len(result)
                break
        assert values and all(a < b for a, b in zip(values, values[1:])), values
        return {"label": "mcp-progress-status-cancellation", "firstProgressSeconds": first_progress,
                "statusDuringRead": "running", "cancelledStatus": status["status"],
                "completedCount": len(result), "progressValues": values}
    finally:
        wire.close()


def cli_cancellation(status_dir, expected_count):
    import signal
    cli = Path(os.environ.get("C1_TEST_BIN", ROOT / ".build/debug/c1"))
    process = subprocess.Popen([str(cli), "variants", "list", "--rating", "5", "--batch-size", "1", "--format", "json", "--quiet"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               env=dict(os.environ, C1_REQUEST_DIR=str(status_dir)))
    try:
        deadline = time.monotonic() + 30
        status = None
        while time.monotonic() < deadline:
            for path in Path(status_dir).glob("req-*.json"):
                try:
                    item = json.loads(path.read_text())
                except (OSError, json.JSONDecodeError):
                    continue
                if item["processId"] == process.pid:
                    status = item
                    break
            if status and status["candidatesScanned"] > 0:
                break
            assert process.poll() is None, "Inventory exited before cancellation checkpoint"
            time.sleep(.05)
        assert status and status["status"] == "running", status
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=30)
        assert not stdout.strip(), "Cancelled inventory must not publish a partial result"
        error = json.loads(stderr)["error"]
        assert error["code"] == "request-cancelled", error
        final = json.loads((Path(status_dir) / (status["requestId"] + ".json")).read_text())
        assert final["status"] == "cancelled" and final["summariesCompleted"] < expected_count, final
        return {"label": "cli-sigint-cancellation", "status": final["status"], "summariesCompleted": final["summariesCompleted"]}
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
