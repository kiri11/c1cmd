import Foundation
import CaptureOneCore

/// Offline qualification for the two phase inventory reader.  The fake
/// executor in ReleaseSafetyTests models the native calls and lets these
/// tests exercise the safety checks without launching Capture One.
struct InventoryTests {
    private static func fixture(_ count: Int = 6, native: Bool = true) -> (FakeScript, SessionController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = FakeScript(directory: dir)
        fake.values = [:]
        for id in 1...count {
            fake.values[String(id)] = [0, 0, 0, 5000, 0]
            fake.ratings[String(id)] = id % 6
        }
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" }, nativeInventoryEnabled: native)
        return (fake, core, dir)
    }

    static func run() {
        print("Running InventoryTests...")
        testSubset()
        testFiltersBeforeHydration()
        testDuplicateAndSharedParentIDs()
        testMalformedAndVanishedResponsesFailClosed()
        testRatingAndMembershipDriftFailClosed()
        testDocumentDriftFailsClosed()
        testInvalidOptionsFailBeforeNativeCalls()
    }

    private static func testSubset() {
        let (fake, core, dir) = fixture(512)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrowBlock {
            let rows = try core.listVariantSubset(ids: ["5", "6", "11"], rating: 5, batchSize: 2)
            XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["5", "11"])
            XCTAssertTrue(rows.allSatisfy { Set($0.keys) == Set(["id", "rating", "parentImagePath"]) })
            XCTAssertTrue(fake.hydrationBatches.isEmpty)
            XCTAssertEqual(fake.ratingBatches, [["5", "6"], ["11"], ["5", "6"], ["11"]])
            XCTAssertFalse(fake.calls.contains("discoverFilteredVariantIDs"))
            XCTAssertFalse(fake.calls.contains("discoverVariantIDs"))
            let rich = try core.listVariantSubset(ids: ["5", "6"], rating: 5, fields: "summary")
            let absent = try core.listVariantSubset(ids: ["5"], parentPath: "/other.CR3")
            let present = try core.listVariantSubset(ids: ["5"], parentPath: fake.parent)
            XCTAssertEqual(absent.count, 0)
            XCTAssertEqual(present.count, 1)
            XCTAssertEqual(rich.count, 1)
            XCTAssertEqual(fake.hydrationCounterIDs, ["5"])
        }
        for ids in [[], [""], ["1", "1"], (1...513).map(String.init)] {
            let before = fake.calls.count
            XCTAssertThrowsError(try core.listVariantSubset(ids: ids))
            XCTAssertEqual(fake.calls.count, before)
        }
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"], fields: "unknown"))
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"], parentPath: "relative.CR3"))
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"], deadlineSeconds: 0.000001))
        XCTAssertNoThrowBlock {
            fake.ratingBatches = []
            let known = (1...100).map(String.init)
            let hundred = try core.listVariantSubset(ids: known, batchSize: 32)
            XCTAssertEqual(hundred.count, 100)
            XCTAssertEqual(fake.ratingBatches.map(\.count), [32, 32, 32, 4, 32, 32, 32, 4])
        }
        XCTAssertNoThrowBlock {
            fake.ratingBatches = []
            let known = (1...512).map(String.init)
            let rows = try core.listVariantSubset(ids: known)
            XCTAssertEqual(rows.compactMap { $0["id"] as? String }, known)
            XCTAssertEqual(fake.ratingBatches.map(\.count), Array(repeating: 32, count: 32))
        }
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["missing"]))
        var reads = 0
        fake.beforeHandler = { handler in
            if handler == "readVariantSubset" {
                reads += 1
                if reads == 2 { fake.ratings["5"] = 1 }
            }
        }
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"], rating: 5))
        fake.beforeHandler = nil
        fake.ratingResponseIDs = { _ in ["6"] }
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"]))
        fake.ratingResponseIDs = nil
        fake.documentDrift = { fake.generation = "app-2" }
        XCTAssertThrowsError(try core.listVariantSubset(ids: ["5"]))
    }

    private static func testFiltersBeforeHydration() {
        let (fake, core, dir) = fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.selectedIDs = ["2", "4", "6"]
        XCTAssertNoThrowBlock {
            let matches = try core.listVariants(collectionName: "Capture", selectedOnly: true, minRating: 4, batchSize: 2)
            XCTAssertEqual(matches.map(\.id), ["4"])
            XCTAssertEqual(fake.hydrationCounterIDs, ["4"], "Nonmatching variants are never hydrated")
            XCTAssertTrue(fake.calls.contains("discoverFilteredVariantIDs"), "Native discovery applies filters")
            XCTAssertTrue(fake.ratingBatches.isEmpty, "Native discovery does not scan ratings separately")
            XCTAssertTrue(fake.ratingBatches.isEmpty, "Native discovery avoids rating batches")
            XCTAssertTrue(fake.hydrationBatches.allSatisfy { $0.count <= 2 }, "Summary requests obey batchSize")
            XCTAssertEqual(fake.listArguments[1].stringValue, "Capture")
            XCTAssertTrue(fake.listArguments[2].booleanValue)
        }

        for rating in 0...5 {
            XCTAssertNoThrowBlock {
                let exact = try core.listVariants(rating: rating, batchSize: 2)
                XCTAssertTrue(exact.allSatisfy { $0.rating == rating }, "Native exact rating (rating) is applied")
            }
        }
        XCTAssertNoThrowBlock {
            let empty = try core.listVariants(selectedOnly: true, rating: 3, batchSize: 2)
            XCTAssertTrue(empty.isEmpty, "Native discovery returns empty results without hydration")
        }

        fake.hydrationBatches = []
        fake.listArguments = []
        XCTAssertNoThrowBlock {
            let zero = try core.listVariants(rating: 0, batchSize: 2)
            XCTAssertEqual(zero.map(\.id), ["6"])
            XCTAssertEqual(fake.hydrationCounterIDs, ["6"], "Rating zero is a real filter")
            XCTAssertTrue(fake.hydrationBatches.allSatisfy { $0.count <= 2 })
        }
        fake.hydrationBatches = []
        XCTAssertNoThrowBlock {
            let zero = try core.listVariants(minRating: 0, batchSize: 2)
            XCTAssertEqual(zero.count, 6)
            XCTAssertEqual(fake.hydrationCounterIDs.count, 6)
            XCTAssertEqual(fake.listArguments[1].descriptorType, NSAppleEventDescriptor.missingValue().descriptorType,
                           "An omitted collection is passed as a missing Apple Event value")
            XCTAssertFalse(fake.listArguments[2].booleanValue)
        }
    }

    private static func testDuplicateAndSharedParentIDs() {
        let (fake, core, dir) = fixture(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.ratings = ["1": 5, "2": 1, "3": 5]
        fake.discoveredVariantIDs = ["3", "1", "3", "2"]
        XCTAssertThrowsError(try core.listVariants(minRating: 5, batchSize: 2), "Duplicate native IDs are malformed")

        fake.discoveredVariantIDs = ["1", "3"]
        XCTAssertNoThrowBlock {
            let result = try core.listVariants(minRating: 5, batchSize: 2)
            XCTAssertEqual(result.map(\.id), ["1", "3"], "Distinct native variants remain separate")
            XCTAssertEqual(result.map(\.parentImagePath), [fake.parent, fake.parent], "Variants sharing a parent image are preserved")
        }
    }

    private static func testMalformedAndVanishedResponsesFailClosed() {
        let (fake, core, dir) = fixture(2, native: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        fake.ratingResponseIDs = { _ in ["1"] }
        XCTAssertThrowsError(try core.listVariants(batchSize: 2), "A vanished ID cannot be silently dropped")

        fake.ratingResponseIDs = { _ in ["1", "1"] }
        XCTAssertThrowsError(try core.listVariants(batchSize: 2), "Duplicate rating records are malformed")

        fake.ratingResponseIDs = nil
        fake.summaryResponseIDs = { _ in ["2"] }
        XCTAssertThrowsError(try core.listVariants(batchSize: 2), "Misaligned summary records are malformed")
    }

    private static func testRatingAndMembershipDriftFailClosed() {
        let (fake, core, dir) = fixture(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.ratings = ["1": 5, "2": 1]
        fake.ratingDrift = { fake.ratings["1"] = 4 }
        XCTAssertThrowsError(try core.listVariants(minRating: 5, batchSize: 2), "A rating changed after the scan")

        let membership = fixture(2)
        defer { try? FileManager.default.removeItem(at: membership.2) }
        membership.0.discoveredVariantIDs = ["1", "2"]
        membership.0.membershipDrift = { membership.0.discoveredVariantIDs = ["1"] }
        XCTAssertThrowsError(try membership.1.listVariants(batchSize: 2), "Membership changes are detected before returning inventory")
    }

    private static func testDocumentDriftFailsClosed() {
        let (fake, core, dir) = fixture(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        fake.documentDrift = { fake.generation = "app-2" }
        XCTAssertThrowsError(try core.listVariants(batchSize: 1), "Every batch rechecks document identity")
    }

    private static func testInvalidOptionsFailBeforeNativeCalls() {
        let (fake, core, dir) = fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for batchSize in [-1, 0, 257] {
            fake.calls = []
            XCTAssertThrowsError(try core.listVariants(batchSize: batchSize))
            XCTAssertTrue(fake.calls.isEmpty, "Invalid batchSize (batchSize) fails before Capture One calls")
        }
        for deadline in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            fake.calls = []
            XCTAssertThrowsError(try core.listVariants(deadlineSeconds: deadline))
            XCTAssertTrue(fake.calls.isEmpty, "Invalid deadline fails before Capture One calls")
        }
    }
}
