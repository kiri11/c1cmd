import Foundation
import CaptureOneCore

public struct DumpTests {
    public static func run() {
        print("Running DumpTests...")

        let record = DumpRecord(
            id: "10",
            name: "TestVariant",
            workingRef: nil,
            adjustments: Adjustments(exposure: 0.1, contrast: 5.0, saturation: 10.0, temperature: 5600.0, tint: 2.0),
            metadata: Metadata(camera: "Canon EOS R5", lens: "RF 50mm", iso: "100", shutterSpeed: "1/200", asShotWB: "Shot", captureDate: "2026-01-01", rating: 4, colorTag: 1),
            stateHash: "abc123statehash"
        )

        // 1. JSON encoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record),
              let jsonStr = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to encode DumpRecord to JSON")
            return
        }

        XCTAssertTrue(jsonStr.contains("\"id\":\"10\""), "JSON should contain id")
        XCTAssertTrue(jsonStr.contains("\"name\":\"TestVariant\""), "JSON should contain name")
        XCTAssertTrue(jsonStr.contains("\"stateHash\":\"abc123statehash\""), "JSON should contain stateHash")
        XCTAssertTrue(jsonStr.contains("\"exposure\":0.1"), "JSON should contain exposure")
        XCTAssertTrue(jsonStr.contains("\"camera\":\"Canon EOS R5\""), "JSON should contain camera metadata")

        // 2. JSON Decoding roundtrip
        guard let decoded = try? JSONDecoder().decode(DumpRecord.self, from: data) else {
            XCTFail("Failed to decode DumpRecord from JSON")
            return
        }
        XCTAssertEqual(decoded.id, "10", "Decoded ID")
        XCTAssertEqual(decoded.name, "TestVariant", "Decoded name")
        XCTAssertEqual(decoded.adjustments.exposure, 0.1, "Decoded exposure")
        XCTAssertEqual(decoded.metadata.camera, "Canon EOS R5", "Decoded camera")

        // 3. OutputFormatter.renderDump JSONL
        let jsonlOutput = OutputFormatter.renderDump([record], format: .json, jsonl: true)
        let lines = jsonlOutput.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "Should render 1 line of JSONL")
        XCTAssertTrue(lines[0].contains("\"id\":\"10\""), "JSONL line contains id")

        // 4. OutputFormatter.renderDump Human
        let humanOutput = OutputFormatter.renderDump([record], format: .human, jsonl: false)
        XCTAssertTrue(humanOutput.contains("TestVariant"), "Human output contains variant name")
        XCTAssertTrue(humanOutput.contains("Total variants dumped: 1"), "Human output contains total summary count")

        for native in [true, false] { testFilters(native: native) }
        testIDs()
        testIncompleteAdjustmentReply()
        testDeadlineAndValidation()
    }

    private static func fixture(native: Bool = true) -> (FakeScript, SessionController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = FakeScript(directory: dir)
        fake.values = [:]
        for id in 1...6 {
            fake.values[String(id)] = [Double(id) / 10, 0, 0, 5000, 0]
            fake.ratings[String(id)] = id % 6
        }
        let core = SessionController(lock: testLock, executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" }, nativeInventoryEnabled: native)
        return (fake, core, dir)
    }

    private static func adjustmentReads(_ fake: FakeScript) -> Int { fake.calls.filter { $0 == "getAdjustmentsBatch" }.count }

    /// Rating filters narrow inventory before adjustments are read; an unfiltered scan reads summaries without a ratings pass.
    private static func testFilters(native: Bool) {
        let (fake, core, dir) = fixture(native: native)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrowBlock {
            let exact = try core.dump(rating: 5)
            XCTAssertEqual(exact.map(\.id), ["5"])
            XCTAssertEqual(exact.first?.adjustments.exposure, 0.5)
            XCTAssertEqual(fake.hydrationCounterIDs, ["5"], "Nonmatching variants are never hydrated")
            XCTAssertEqual(adjustmentReads(fake), 1)
            fake.calls = []; fake.hydrationBatches = []
            let minimum = try core.dump(minRating: 4, batchSize: 1)
            XCTAssertEqual(minimum.map(\.id), ["4", "5"])
            XCTAssertEqual(adjustmentReads(fake), 2, "Adjustments are read only for matches")
            let unrated = try core.dump(rating: 0)
            XCTAssertEqual(unrated.map(\.id), ["6"], "Rating zero is a real filter")
            fake.ratingBatches = []
            let all = try core.dump()
            XCTAssertEqual(all.map(\.id), ["1", "2", "3", "4", "5", "6"])
            XCTAssertEqual(all.map(\.rating), [1, 2, 3, 4, 5, 0])
            XCTAssertTrue(fake.ratingBatches.isEmpty, "An unfiltered dump skips the separate ratings pass (native: \(native))")
            XCTAssertTrue(fake.calls.contains(native ? "discoverFilteredVariantIDs" : "discoverVariantIDs"))
        }
    }

    /// ids dump exactly the requested variants through the live subset reader, with the inventory's record shape.
    private static func testIDs() {
        let (fake, core, dir) = fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrowBlock {
            let clone = try core.cloneVariant(sourceRef: "1")
            let all = try core.dump()
            fake.calls = []
            let subset = try core.dump(ids: ["5", clone.cloneVariantId, "2"])
            XCTAssertEqual(subset.map(\.id), ["5", clone.cloneVariantId, "2"], "Requested order is kept")
            XCTAssertEqual(subset, subset.map { record in all.first { $0.id == record.id }! }, "ids and inventory dumps agree field for field")
            XCTAssertEqual(subset[1].isManagedWorkingClone, true)
            XCTAssertEqual(subset[1].workingRef, clone.workingRef)
            XCTAssertTrue(fake.calls.contains("readVariantSubset"))
            XCTAssertFalse(fake.calls.contains("discoverVariantIDs") || fake.calls.contains("discoverFilteredVariantIDs"), "ids never enumerate the scope")
            let rated = try core.dump(ids: ["5", "6", "2"], minRating: 2)
            XCTAssertEqual(rated.map(\.id), ["5", "2"])
            fake.outsideCollection = ["6"]
            let scoped = try core.dump(collectionName: "Capture", ids: ["5", "2"])
            XCTAssertEqual(scoped.map(\.id), ["5", "2"])
        }
        fake.calls = []
        XCTAssertThrowsError(try core.dump(collectionName: "Capture", ids: ["5", "6", "7212"])) { error in
            XCTAssertEqual((error as? VariantsNotFound)?.missingIds, ["7212"])
            XCTAssertEqual((error as? VariantsNotFound)?.outOfScopeIds, ["6"])
        }
        XCTAssertEqual(adjustmentReads(fake), 0, "Missing or out-of-scope ids produce no partial dump")
        XCTAssertThrowsError(try core.dump(ids: ["7212"])) { error in
            XCTAssertEqual((error as? VariantsNotFound)?.missingIds, ["7212"])
        }
    }

    /// An adjustments reply that omits a requested variant fails the whole dump.
    private static func testIncompleteAdjustmentReply() {
        let (fake, core, dir) = fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.adjustmentResponseIDs = { $0.filter { $0 != "3" } }
        for dump in [{ try core.dump() }, { try core.dump(ids: ["2", "3"]) }] {
            XCTAssertThrowsError(try dump()) { error in
                XCTAssertEqual((error as? C1Error)?.errorCode, "state-changed", "A missing adjustments row fails instead of returning a partial dump")
            }
        }
    }

    private static func testDeadlineAndValidation() {
        let (fake, core, dir) = fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.beforeHandler = { if $0 == "getAdjustmentsBatch" { Thread.sleep(forTimeInterval: 0.03) } }
        XCTAssertThrowsError(try core.dump(batchSize: 1, deadlineSeconds: 0.05)) { error in
            XCTAssertEqual((error as? C1Error)?.errorCode, "deadline-exceeded", "The deadline covers adjustment reads too")
        }
        XCTAssertTrue((1..<6).contains(adjustmentReads(fake)), "Adjustment reads stop at the deadline")
        fake.beforeHandler = nil
        let invalid: [(String?, [String]?, Int?, Int?, Int, Double?)] = [
            (nil, nil, 5, 4, 100, nil), (nil, [], nil, nil, 100, nil), (nil, ["1", "1"], nil, nil, 100, nil),
            (nil, (1...513).map(String.init), nil, nil, 100, nil), (nil, nil, 6, nil, 100, nil), (nil, nil, nil, -1, 100, nil),
            (nil, nil, nil, nil, 0, nil), (nil, nil, nil, nil, 1001, nil), (nil, nil, nil, nil, 100, 0), (nil, nil, nil, nil, 100, 86401),
        ]
        for (collection, ids, rating, minRating, batchSize, deadline) in invalid {
            fake.calls = []
            XCTAssertThrowsError(try core.dump(collectionName: collection, ids: ids, rating: rating, minRating: minRating,
                                               batchSize: batchSize, deadlineSeconds: deadline))
            XCTAssertTrue(fake.calls.isEmpty, "Invalid dump options fail before Capture One calls")
        }
    }
}
