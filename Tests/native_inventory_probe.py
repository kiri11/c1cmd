#!/usr/bin/env python3
"""Qualify native rating predicates/bulk IDs against legacy per-variant enumeration.

Run sequentially with zero open documents and C1_TEST_RAW_FIXTURE. Output defaults
 to /private/tmp/c1-native-probe.json; override C1_NATIVE_PROBE_EVIDENCE to retain it.
"""
import hashlib
import json
import os
from pathlib import Path
from inventory_integration_test import Harness, osa, apple_literal


def main():
    harness = Harness()
    try:
        harness.create_session()
        rows = harness.ensure_count(24)
        for rating in range(6):
            harness.set_ratings(rows[rating::6], rating)
        harness.set_selection(rows, [row["id"] for index, row in enumerate(rows) if index % 3 != 1])
        document = harness.cli("doc", "info")[0]
        assert document["appVersion"] == "16.8.5.30" and document["isSession"], document
        probe = (Path(__file__).parent / "fixtures/native-inventory-probe.applescript").read_text()
        cases = []
        for collection in [None, "Capture"]:
            for selected in [False, True]:
                reference = harness.reference(document["documentId"], collection, selected)
                for rating, minimum in [(None, None), (0, None), (5, None), (None, 0), (None, 4)]:
                    args = [apple_literal(document["documentId"]),
                            "missing value" if collection is None else apple_literal(collection),
                            str(selected).lower(), "missing value" if rating is None else str(rating),
                            "missing value" if minimum is None else str(minimum)]
                    script = probe + "\nset resultIDs to nativeInventoryIDs(" + ",".join(args) + ")\n"
                    script += "set text item delimiters to linefeed\nreturn resultIDs as text"
                    actual = osa(script, wrapped=False).splitlines()
                    expected = [row["id"] for row in reference
                                if (rating is None or row["rating"] == rating)
                                and (minimum is None or row["rating"] >= minimum)]
                    assert actual == expected, (collection, selected, rating, minimum, actual, expected)
                    cases.append(dict(collection=collection, selected=selected, rating=rating,
                                      minRating=minimum, count=len(actual)))
        output = Path(os.environ.get("C1_NATIVE_PROBE_EVIDENCE", "/private/tmp/c1-native-probe.json"))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({"appVersion": document["appVersion"],
                                     "probeSHA256": hashlib.sha256(probe.encode()).hexdigest(),
                                     "cases": cases}, indent=2) + "\n")
        print(f"PASS native predicate/bulk ID equivalence: {len(cases)} cases; {output}")
    except Exception:
        harness.failed = True
        raise
    finally:
        harness.cleanup()


if __name__ == "__main__":
    main()
