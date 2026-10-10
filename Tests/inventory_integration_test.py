#!/usr/bin/env python3
"""Live inventory qualification in an owned disposable Session or Catalog.

Requires C1_TEST_RAW_FIXTURE and a built c1 binary.  The suite is deliberately
sequential: it creates one disposable document and requires Capture One to have
no document open before setup. C1_TEST_DOCUMENT_KIND and C1_TEST_CATALOG_LAYOUT
select the fixture. It does not run as part of the offline check or invoke
Capture One unless explicitly launched.

Every case runs the default strategy and C1_INVENTORY_STRATEGY=scan and compares
both with Tests/fixtures/inventory-reference.applescript, which performs the old
full-summary enumeration. Timings compare a standalone osascript handler with
the CLI, including its validation overhead.
"""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from catalog_integration_test import sha
from editing_fixture import EditingFixture

ROOT = Path(__file__).resolve().parents[1]
C1 = Path(os.environ.get("C1_TEST_BIN", str(ROOT / ".build" / "debug" / "c1")))
REFERENCE = ROOT / "Tests" / "fixtures" / "inventory-reference.applescript"
RAW = Path(os.environ["C1_TEST_RAW_FIXTURE"]).resolve() if os.environ.get("C1_TEST_RAW_FIXTURE") else None
SMALL_COUNT = int(os.environ.get("C1_INVENTORY_SMALL_COUNT", "12"))
LARGE_COUNT = int(os.environ.get("C1_INVENTORY_LARGE_COUNT", "120"))
EVIDENCE = Path(os.environ.get("C1_INVENTORY_EVIDENCE", "/private/tmp/c1-inventory-evidence.json")).resolve()
# Per document kind: the strategy the default inventory must report on 16.8.5.30,
# the built-in collection holding every variant and a collection holding none.
DOCUMENTS = {
    "session": dict(strategy="native-filter", allVariants="Capture", noVariants="Selects"),
    "catalog": dict(strategy="native-filter", allVariants="All Images", noVariants="c1-inventory-empty"),
}
STATUS_KEYS = ["requestId", "phase", "status", "elapsedMs", "candidatesScanned", "matchesFound",
               "summariesCompleted", "totalCandidates", "inventoryStrategy", "handlerCalls"]


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
        assert RAW and RAW.is_file(), "Set C1_TEST_RAW_FIXTURE to an existing RAW file"
        assert C1.is_file(), f"Missing c1 binary: {C1}"
        assert REFERENCE.is_file(), f"Missing reference handler: {REFERENCE}"
        self.evidence = []
        self.owned = EditingFixture("inventory", RAW, lambda name, value: self.evidence.append({"label": name, **value}))
        self.kind, self.layout = self.owned.kind, self.owned.layout
        self.document = DOCUMENTS[self.kind]
        self.environment = self.owned.environment
        self.status_dir = self.owned.base / "request-status"
        self.failed = False
        self.reference_mode = "legacy-applescript"
        self.last_reference_elapsed = None
        self.album_ids = []
        self.album_membership = {}
        self.selected_ids = set()

    def cli(self, *args, progress=True, allow_error=False, timeout=300, strategy=None):
        env = dict(self.environment, C1_REQUEST_DIR=str(self.status_dir), C1_DIAGNOSTICS="1")
        env.pop("C1_INVENTORY_STRATEGY", None)
        if strategy == "rating-scan":
            env["C1_INVENTORY_STRATEGY"] = "scan"
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

    def reference(self, collection, selected):
        """Return old-handler records as safe tab-delimited fields."""
        collection_expr = "missing value" if collection is None else apple_literal(collection)
        selected_expr = "true" if selected else "false"
        script = REFERENCE.read_text()
        script += f'''\nset rows to listVariantsReference({apple_literal(self.owned.native_id)}, {collection_expr}, {selected_expr})
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

    def open_document(self):
        self.owned.open(lambda *args: self.cli(*args, progress=False)[0])
        osa(f'set current collection of first document to collection {apple_literal(self.document["allVariants"])} of first document')
        if self.kind == "catalog":
            self.album(self.document["noVariants"], [])

    def album(self, name, records):
        """Create an album holding exactly these variants and keep the all-variant collection current."""
        lines = ["set d to first document",
                 f"tell d to set a to make new collection with properties {{name:{apple_literal(name)}, kind:album}}"]
        if records:
            lines.append("add inside a variants {" + ", ".join(f'variant id {apple_literal(r["id"])} of d' for r in records) + "}")
        lines.append(f'set current collection of d to collection {apple_literal(self.document["allVariants"])} of d')
        osa("\n".join(lines))
        time.sleep(.5)
        return [record["id"] for record in records]

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
        assert len({record["id"] for record in values}) == len(values) == target, (len(values), target)
        assert {Path(record["parentImagePath"]).resolve() for record in values} == {self.owned.fixture}, values
        return values

    def set_ratings(self, records, rating):
        lines = [f'set rating of variant id {apple_literal(record["id"])} of d to {rating}' for record in records]
        osa('set d to first document\n' + "\n".join(lines))
        time.sleep(.5)

    def set_selection(self, records, selected_ids):
        selected_ids = set(selected_ids)
        self.selected_ids = selected_ids
        variants = ", ".join(f'variant id {apple_literal(record["id"])} of d' for record in records if record["id"] in selected_ids)
        osa('set d to first document\nselect d variants {' + variants + '}')
        time.sleep(.5)

    def assert_originals(self, label):
        assert sha(self.owned.fixture) == self.owned.original, f"RAW changed during {label}"
        assert sha(RAW) == self.owned.original, f"Source RAW changed during {label}"

    def inventory(self, label, args, strategy):
        started = time.time()
        actual, elapsed, process = self.cli(*args, strategy=strategy)
        status = self.status_after(started)
        assert status.get("status") == "completed", (label, status)
        assert status.get("inventoryStrategy") == strategy, (label, status)
        progress_events = []
        for line in process.stderr.splitlines():
            try:
                event = json.loads(line)
                if isinstance(event, dict) and "requestId" in event and "elapsedMs" in event:
                    progress_events.append(event)
            except json.JSONDecodeError:
                continue
        return actual, {"strategy": strategy, "elapsedSeconds": elapsed,
                        "firstProgressElapsedMs": progress_events[0].get("elapsedMs") if progress_events else None,
                        "progressEvents": len(progress_events), "status": {key: status.get(key) for key in STATUS_KEYS}}

    def benchmark(self, label, collection, selected, rating=None, min_rating=None):
        if collection is None:
            reference = self.reference(None, selected)
        else:
            reference = self.reference(collection, False)
            members = {record["id"] for record in reference}
            assert set(self.album_ids) <= members, (label, self.album_ids, reference)
            self.album_membership[label] = {"added": self.album_ids, "listed": sorted(members, key=int)}
            if selected:
                reference = self.reference(collection, True)
            else:
                # Summaries report the current collection's selection; the legacy handler reports the album's.
                reference = [dict(record, isSelected=record["id"] in self.selected_ids) for record in reference]
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
        actual, default = self.inventory(label, args, self.document["strategy"])
        scanned, scan = self.inventory(label, args, "rating-scan")
        def compact(record):
            return {key: record.get(key) for key in ["id", "name", "parentImagePath", "isSelected", "rating", "colorTag"]}
        assert [compact(value) for value in actual] == [compact(value) for value in expected], label
        assert [compact(value) for value in scanned] == [compact(value) for value in actual], label
        self.assert_originals(label)
        self.evidence.append({"label": label, "scope": "collection" if collection else "document", "selected": selected,
                              "rating": rating, "minRating": min_rating, "resultCount": len(actual),
                              "referenceElapsedSeconds": self.last_reference_elapsed, "default": default, "scan": scan})
        print(f"PASS {label}: {default['strategy']} {default['elapsedSeconds']:.3f}s; rating-scan {scan['elapsedSeconds']:.3f}s; "
              f"legacy {self.last_reference_elapsed:.3f}s; matches {len(actual)}", flush=True)

    def dump(self, *flags, allow_error=False):
        value, _, process = self.cli("dump", "--dump-format", "json", *flags, allow_error=allow_error)
        return value, process

    def dump_filters(self, records):
        """Sparse ratings: only the first record is rated 5, every other record is unrated."""
        ids = [record["id"] for record in records]
        rated = ids[0]
        def listed(*flags):
            value, _ = self.dump(*flags)
            assert isinstance(value, list), (flags, value)
            return [record["id"] for record in value]
        assert listed("--rating", "5") == [rated]
        assert sorted(listed("--collection", self.document["allVariants"], "--rating", "0")) == sorted(ids[1:])
        assert sorted(listed("--min-rating", "0")) == sorted(listed()) == sorted(ids)
        subset = [ids[1], rated]
        assert listed("--ids", ",".join(subset), "--collection", self.document["allVariants"]) == subset
        assert listed("--ids", ",".join(subset), "--rating", "5") == [rated]
        exact, _ = self.dump("--ids", rated)
        assert exact[0]["rating"] == 5 and "stateHash" in exact[0], exact
        value, process = self.dump("--ids", f"{rated},missing-dump-id", allow_error=True)
        assert process.returncode != 0 and value["error"]["code"] == "variant-not-found", value
        assert value["error"]["missingIds"] == ["missing-dump-id"], value
        value, process = self.dump("--batch-size", "1", "--deadline-seconds", "0.001", allow_error=True)
        assert process.returncode != 0 and value["error"]["code"] in {"deadline-exceeded", "request-cancelled", "timeout"}, value
        self.assert_originals("dump filters")
        self.evidence.append({"label": "dump-filters", "variants": len(ids), "deadlineErrorCode": value["error"]["code"]})
        print(f"PASS dump filters on {len(ids)} variants", flush=True)

    def deadline_safety(self):
        started = time.time()
        value, elapsed, process = self.cli("variants", "list", "--batch-size", "1", "--deadline-seconds", "0.001",
                                           allow_error=True, timeout=60)
        assert process.returncode != 0, value
        assert value.get("error", {}).get("code") in {"deadline-exceeded", "request-cancelled", "timeout"}, value
        status = self.status_after(started)
        assert status.get("status") == "failed", status
        self.assert_originals("deadline-safety")
        self.evidence.append({"label": "deadline-safety", "elapsedSeconds": elapsed,
                              "errorCode": value["error"]["code"], "status": status})

    def run(self):
        self.open_document()
        for count in [SMALL_COUNT, LARGE_COUNT]:
            records = self.ensure_count(count)
            album = f"c1-inventory-{count}"
            self.album_ids = self.album(album, records[::3])
            sparse = records[:1]
            self.set_ratings(records, 0)
            for record in sparse:
                self.set_ratings([record], 5)
            selected_ids = [record["id"] for index, record in enumerate(records) if index % 2 == 0]
            self.set_selection(records, selected_ids)
            self.benchmark(f"{count}-document-sparse-exact5", None, False, rating=5)
            self.benchmark(f"{count}-collection-sparse-rating0", album, False, rating=0)
            self.benchmark(f"{count}-selected-sparse-min0", None, True, min_rating=0)
            if count == SMALL_COUNT:
                self.dump_filters(records)
            self.set_ratings(records, 5)
            self.set_selection(records, selected_ids)
            self.benchmark(f"{count}-document-dense-min5", None, False, min_rating=5)
            self.benchmark(f"{count}-collection-dense-min0", album, False, min_rating=0)
            self.benchmark(f"{count}-selected-dense-exact5", None, True, rating=5)
            self.benchmark(f"{count}-collection-selected-min4", album, True, min_rating=4)
            self.benchmark(f"{count}-empty-exact4", None, False, rating=4)
        from inventory_subset_test import run as test_subset
        self.evidence.append(test_subset(self.variants(), self.status_dir, self.document["allVariants"], self.document["noVariants"]))
        from inventory_mcp_test import run as test_mcp, cli_cancellation
        self.evidence.append(test_mcp(self.status_dir, LARGE_COUNT))
        self.evidence.append(cli_cancellation(self.status_dir, LARGE_COUNT))
        self.deadline_safety()
        self.assert_originals("final")

    def cleanup(self):
        try:
            self.owned.close()
        except Exception as error:
            print(f"Cleanup warning: {error}", file=sys.stderr)
            self.failed = True
        if self.failed:
            print(f"Failed fixture retained at {self.owned.base}", file=sys.stderr)
        else:
            shutil.rmtree(self.owned.base, ignore_errors=True)


def main():
    assert SMALL_COUNT > 0 and LARGE_COUNT >= SMALL_COUNT
    harness = Harness()
    succeeded = False
    try:
        harness.run()
        output = {"generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "documentKind": harness.kind, "catalogLayout": harness.layout if harness.kind == "catalog" else None,
                  "expectedStrategy": harness.document["strategy"],
                  "referenceMode": harness.reference_mode, "rawSHA256": harness.owned.original,
                  "candidateCounts": [SMALL_COUNT, LARGE_COUNT], "cases": harness.evidence, "albumMembership": harness.album_membership,
                  "limitations": ["Legacy timing uses standalone osascript; candidate timing includes CLI and document/batch validation overhead.", "Fixtures contain multiple variants of one copied RAW; timing is indicative, not a throughput guarantee for a whole shoot.", "handlerCalls counts script invocations; individual Apple Event counts and peak memory are not measured."]}
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(output, indent=2) + "\n")
        print(json.dumps(output, indent=2))
        print(f"Evidence: {EVIDENCE}")
        succeeded = True
    except Exception as error:
        harness.failed = True
        failure = {"generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   "status": "failed", "error": str(error), "fixtureRoot": str(harness.owned.base),
                   "documentKind": harness.kind, "referenceMode": harness.reference_mode, "cases": harness.evidence, "albumMembership": harness.album_membership}
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(failure, indent=2) + "\n")
        print(f"Failure evidence: {EVIDENCE}", file=sys.stderr)
        raise
    finally:
        harness.failed = not succeeded
        harness.cleanup()


if __name__ == "__main__":
    main()
