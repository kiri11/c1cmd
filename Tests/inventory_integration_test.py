#!/usr/bin/env python3
"""Live inventory benchmark for an isolated Capture One Session.

Requires C1_TEST_RAW_FIXTURE and a built c1 binary.  The suite is deliberately
sequential: it creates one disposable Session and requires Capture One to have
no document open before setup. It does not run as part
of the offline check or invoke Capture One unless explicitly launched.

The reference path uses Tests/fixtures/inventory-reference.applescript, which
performs the old full-summary enumeration. Timings compare a standalone
osascript handler with the new CLI, including its validation overhead.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
C1 = Path(os.environ.get("C1_TEST_BIN", str(ROOT / ".build" / "debug" / "c1")))
REFERENCE = ROOT / "Tests" / "fixtures" / "inventory-reference.applescript"
RAW = Path(os.environ["C1_TEST_RAW_FIXTURE"]).resolve() if os.environ.get("C1_TEST_RAW_FIXTURE") else None
SMALL_COUNT = int(os.environ.get("C1_INVENTORY_SMALL_COUNT", "12"))
LARGE_COUNT = int(os.environ.get("C1_INVENTORY_LARGE_COUNT", "120"))
EVIDENCE = Path(os.environ.get("C1_INVENTORY_EVIDENCE", "/private/tmp/c1-inventory-evidence.json")).resolve()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def apple_literal(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def osa(body, wrapped=True, timeout=120):
    script = body
    if wrapped:
        script = 'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'
    result = subprocess.run(["osascript", "-e", script], capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "osascript failed")
    output = result.stdout.strip()
    # osascript -s s quotes scalar text results. Decode that outer string so
    # `none` and document names are compared as values rather than literals.
    try:
        decoded = json.loads(output)
        return decoded if isinstance(decoded, str) else output
    except json.JSONDecodeError:
        return output


def open_document_path():
    value = osa('''
        if (count of documents) is 0 then return "none"
        set d to first document
        set documentID to id of d as text
        set documentName to name of d as text
        if documentName ends with ".cosessiondb" and documentID does not end with ".cosessiondb" then
            return documentID & "/" & documentName
        end if
        return documentID
    ''')
    return None if value == "none" else value


def parse_json(text):
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    decoder = json.JSONDecoder()
    # Pretty JSON errors and line oriented progress can share stderr.  Find a
    # complete object containing an error, preferring the last such object.
    candidates = []
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            candidates.append(value)
    errors = [value for value in candidates if "error" in value]
    return errors[-1] if errors else (candidates[-1] if candidates else None)


class Harness:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="c1-inventory-", dir="/private/tmp"))
        self.session_name = "c1-inventory"
        self.session = self.root / self.session_name
        self.raw = None
        self.failed = False
        self.status_dir = self.root / "request-status"
        self.reference_mode = "legacy-applescript"
        self.last_reference_elapsed = None
        self.evidence = []
        self.original_fixture_sha = None
        self.source_fixture_sha = None

    def cli(self, *args, progress=True, allow_error=False, timeout=300):
        env = dict(os.environ, C1_REQUEST_DIR=str(self.status_dir), C1_DIAGNOSTICS="1")
        if progress:
            env["C1_PROGRESS"] = "json"
        started = time.monotonic()
        result = subprocess.run([str(C1), *args, "--format", "json"], capture_output=True,
                                text=True, timeout=timeout, env=env)
        elapsed = time.monotonic() - started
        value = parse_json(result.stdout)
        if value is None:
            value = parse_json(result.stderr)
        if value is None:
            raise AssertionError(f"No JSON response for {args}: {result.stdout}\n{result.stderr}")
        if not allow_error:
            assert result.returncode == 0, (args, result.returncode, value, result.stderr)
        return value, elapsed, result

    def status_after(self, started):
        deadline = time.monotonic() + 5
        latest = None
        while time.monotonic() < deadline:
            files = [p for p in self.status_dir.glob("req-*.json") if p.stat().st_mtime >= started - 1]
            if files:
                candidate = max(files, key=lambda p: p.stat().st_mtime_ns)
                try:
                    latest = json.loads(candidate.read_text())
                except (OSError, json.JSONDecodeError):
                    latest = None
                if latest and latest.get("status") != "running":
                    return latest
            time.sleep(.05)
        return latest or {}

    def reference(self, document_id, collection, selected):
        """Return old-handler records as safe tab-delimited fields."""
        collection_expr = "missing value" if collection is None else apple_literal(collection)
        selected_expr = "true" if selected else "false"
        script = REFERENCE.read_text()
        script += f'''\nset rows to listVariantsReference({apple_literal(document_id)}, {collection_expr}, {selected_expr})
set resultRows to {{}}
repeat with row in rows
    set end of resultRows to (variantId of row as text) & tab & (variantName of row as text) & tab & (parentImagePath of row as text) & tab & (isSelected of row as text) & tab & (starRating of row as text) & tab & (colorTagVal of row as text)
end repeat
set text item delimiters to linefeed
return resultRows as text
'''
        started = time.monotonic()
        output = osa(script, wrapped=False, timeout=600)
        self.last_reference_elapsed = time.monotonic() - started
        records = []
        for line in output.splitlines():
            fields = line.split("\t")
            if len(fields) != 6:
                raise RuntimeError(f"Unexpected reference row: {line!r}")
            records.append({"id": fields[0], "name": fields[1], "parentImagePath": fields[2],
                            "isSelected": fields[3].lower() == "true", "rating": int(fields[4]),
                            "colorTag": int(fields[5])})
        return records

    def create_session(self):
        assert RAW and RAW.is_file(), "Set C1_TEST_RAW_FIXTURE to an existing RAW file"
        assert C1.is_file(), f"Missing c1 binary: {C1}"
        assert REFERENCE.is_file(), f"Missing reference handler: {REFERENCE}"
        if open_document_path() is not None:
            raise RuntimeError("Refusing to run inventory qualification while a Capture One document is open.")
        osa(f'make new document with properties {{name:{apple_literal(self.session_name)}, kind:session, path:{apple_literal(self.root)}}}')
        time.sleep(1)
        capture = self.session / "Capture"
        capture.mkdir(parents=True, exist_ok=True)
        self.raw = capture / ("fixture" + RAW.suffix)
        shutil.copy2(RAW, self.raw)
        self.original_fixture_sha = sha(self.raw)
        self.source_fixture_sha = sha(RAW)
        assert self.original_fixture_sha == self.source_fixture_sha
        osa(f'set current collection of first document to collection "Capture" of first document')
        time.sleep(1)
        doctor = self.cli("doctor", progress=False)[0]
        assert doctor["allChecksPassed"] and doctor["writesEnabled"] and doctor["exactBuildMatched"], doctor

    def variants(self):
        values, _, _ = self.cli("variants", "list")
        assert isinstance(values, list) and values, values
        return values

    def ensure_count(self, target):
        values = self.variants()
        assert len(values) <= target, (len(values), target)
        source = values[0]["id"]
        missing = target - len(values)
        if missing:
            osa(f'''set d to first document
set sourceVariant to variant id {apple_literal(source)} of d
repeat {missing} times
    set clonedVariant to clone variant sourceVariant
end repeat''', timeout=600)
            values = self.variants()
        assert len(values) == target, (len(values), target)
        return values

    def set_ratings(self, records, rating):
        lines = [f'set rating of variant id {apple_literal(record["id"])} of d to {rating}' for record in records]
        osa('set d to first document\n' + "\n".join(lines))
        time.sleep(.5)

    def set_selection(self, records, selected_ids):
        selected_ids = set(selected_ids)
        variants = ", ".join(f'variant id {apple_literal(record["id"])} of d' for record in records if record["id"] in selected_ids)
        osa('set d to first document\nselect d variants {' + variants + '}')
        time.sleep(.5)

    def benchmark(self, label, records, collection, selected, rating=None, min_rating=None):
        document = self.cli("doc", "info", progress=False)[0]
        reference = self.reference(document["documentId"], collection, selected)
        expected = [record for record in reference
                    if (rating is None or record["rating"] == rating)
                    and (min_rating is None or record["rating"] >= min_rating)]
        args = ["variants", "list", "--batch-size", "32", "--deadline-seconds", "300"]
        if collection is not None:
            args += ["--collection", collection]
        if selected:
            args += ["--selected"]
        if rating is not None:
            args += ["--rating", str(rating)]
        if min_rating is not None:
            args += ["--min-rating", str(min_rating)]
        started = time.time()
        actual, elapsed, process = self.cli(*args)
        status = self.status_after(started)
        assert status.get("status") == "completed", status
        def compact(record):
            return {key: record.get(key) for key in ["id", "name", "parentImagePath", "isSelected", "rating", "colorTag"]}
        assert [compact(value) for value in actual] == [compact(value) for value in expected], label
        assert sha(self.raw) == self.original_fixture_sha, f"RAW changed during {label}"
        assert sha(RAW) == self.source_fixture_sha, f"Source RAW changed during {label}"
        progress_events = []
        for line in process.stderr.splitlines():
            try:
                event = json.loads(line)
                if isinstance(event, dict) and "requestId" in event and "elapsedMs" in event:
                    progress_events.append(event)
            except json.JSONDecodeError:
                continue
        first_progress = progress_events[0].get("elapsedMs") if progress_events else None
        result = {"label": label, "scope": "collection" if collection else "document", "selected": selected,
                  "rating": rating, "minRating": min_rating, "resultCount": len(actual),
                  "referenceElapsedSeconds": self.last_reference_elapsed,
                  "referenceOverheadDifferenceSeconds": (self.last_reference_elapsed - elapsed) if self.last_reference_elapsed is not None else None,
                  "firstProgressElapsedMs": first_progress,
                  "elapsedSeconds": elapsed, "status": {key: status.get(key) for key in
                  ["requestId", "phase", "status", "elapsedMs", "candidatesScanned", "matchesFound", "summariesCompleted", "totalCandidates", "inventoryStrategy", "handlerCalls"]},
                  "progressEvents": len(progress_events)}
        self.evidence.append(result)
        print(f"PASS {label}: {elapsed:.3f}s; legacy {self.last_reference_elapsed:.3f}s; matches {len(actual)}", flush=True)

    def deadline_safety(self):
        started = time.time()
        value, elapsed, process = self.cli("variants", "list", "--batch-size", "1", "--deadline-seconds", "0.001",
                                           allow_error=True, timeout=60)
        assert process.returncode != 0, value
        assert value.get("error", {}).get("code") in {"deadline-exceeded", "request-cancelled", "timeout"}, value
        status = self.status_after(started)
        assert status.get("status") == "failed", status
        assert sha(self.raw) == self.original_fixture_sha
        assert sha(RAW) == self.source_fixture_sha
        self.evidence.append({"label": "deadline-safety", "elapsedSeconds": elapsed,
                              "errorCode": value["error"]["code"], "status": status})

    def run(self):
        self.create_session()
        for count in [SMALL_COUNT, LARGE_COUNT]:
            records = self.ensure_count(count)
            sparse = records[:1]
            self.set_ratings(records, 0)
            for record in sparse:
                self.set_ratings([record], 5)
            selected_ids = [record["id"] for index, record in enumerate(records) if index % 2 == 0]
            self.set_selection(records, selected_ids)
            self.benchmark(f"{count}-document-sparse-exact5", records, None, False, rating=5)
            self.benchmark(f"{count}-collection-sparse-rating0", records, "Capture", False, rating=0)
            self.benchmark(f"{count}-selected-sparse-min0", records, None, True, min_rating=0)
            self.set_ratings(records, 5)
            self.set_selection(records, selected_ids)
            self.benchmark(f"{count}-document-dense-min5", records, None, False, min_rating=5)
            self.benchmark(f"{count}-collection-dense-min0", records, "Capture", False, min_rating=0)
            self.benchmark(f"{count}-selected-dense-exact5", records, None, True, rating=5)
            self.benchmark(f"{count}-collection-selected-min4", records, "Capture", True, min_rating=4)
            self.benchmark(f"{count}-empty-exact4", records, None, False, rating=4)
        from inventory_subset_test import run as test_subset
        self.evidence.append(test_subset(self.variants()))
        from inventory_mcp_test import run as test_mcp, cli_cancellation
        self.evidence.append(test_mcp(self.status_dir, LARGE_COUNT))
        self.evidence.append(cli_cancellation(self.status_dir, LARGE_COUNT))
        self.deadline_safety()
        assert sha(self.raw) == self.original_fixture_sha

    def cleanup(self):
        try:
            # Close only the disposable document by its actual native name.
            # Never close an unrelated/current document as part of cleanup.
            session_document = self.session / (self.session_name + ".cosessiondb")
            if session_document.exists() or self.session.exists():
                osa(f'if exists document {apple_literal(session_document.name)} then close document {apple_literal(session_document.name)} without saving')
                remaining = osa(f'if exists document {apple_literal(session_document.name)} then\nreturn "open"\nelse\nreturn "closed"\nend if')
                if remaining != "closed":
                    raise RuntimeError(f"Disposable document remained open: {session_document.name}")
        except Exception as error:
            print(f"Cleanup warning: {error}", file=sys.stderr)
            self.failed = True
        if self.failed:
            print(f"Failed fixture retained at {self.root}", file=sys.stderr)
        else:
            shutil.rmtree(self.root, ignore_errors=True)


def main():
    assert SMALL_COUNT > 0 and LARGE_COUNT >= SMALL_COUNT
    harness = Harness()
    succeeded = False
    try:
        harness.run()
        output = {"generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "referenceMode": harness.reference_mode, "rawSHA256": harness.original_fixture_sha,
                  "sourceRawSHA256": harness.source_fixture_sha,
                  "candidateCounts": [SMALL_COUNT, LARGE_COUNT], "cases": harness.evidence,
                  "limitations": ["Legacy timing uses standalone osascript; candidate timing includes CLI and document/batch validation overhead.", "Fixtures contain multiple variants of one copied RAW; timing is indicative, not a throughput guarantee for a whole shoot.", "handlerCalls counts script invocations; individual Apple Event counts and peak memory are not measured."]}
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(output, indent=2) + "\n")
        print(json.dumps(output, indent=2))
        print(f"Evidence: {EVIDENCE}")
        succeeded = True
    except Exception as error:
        harness.failed = True
        failure = {"generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   "status": "failed", "error": str(error), "fixtureRoot": str(harness.root),
                   "referenceMode": harness.reference_mode, "cases": harness.evidence}
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(failure, indent=2) + "\n")
        print(f"Failure evidence: {EVIDENCE}", file=sys.stderr)
        raise
    finally:
        harness.failed = not succeeded
        harness.cleanup()


if __name__ == "__main__":
    main()
