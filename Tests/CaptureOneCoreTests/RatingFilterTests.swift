import Foundation
import CaptureOneCore

struct RatingFilterTests {
    static func run() {
        print("Running RatingFilterTests...")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeScript(directory: dir)
        for rating in 0...5 {
            let id = String(rating + 1)
            fake.values[id] = [0, 0, 0, 5000, 0]
            fake.ratings[id] = rating
        }
        fake.selectedIDs = ["1", "5", "6"]
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" })
        XCTAssertNoThrowBlock {
            let all = try core.listVariants()
            XCTAssertEqual(all.map(\.rating), [0, 1, 2, 3, 4, 5])
            for rating in 0...5 {
                let exact = try core.listVariants(rating: rating)
                let minimum = try core.listVariants(minRating: rating)
                XCTAssertEqual(exact.map(\.id), [String(rating + 1)])
                XCTAssertEqual(minimum.map(\.rating), Array(rating...5))
            }
            let selected = try core.listVariants(collectionName: "Capture", selectedOnly: true, minRating: 4)
            XCTAssertEqual(selected.map(\.id), ["5", "6"])
            XCTAssertTrue(selected.allSatisfy(\.isSelected))
            XCTAssertEqual(fake.listArguments[1].stringValue, "Capture", "Collection scope still reaches the native handler")
            XCTAssertTrue(fake.listArguments[2].booleanValue)
            let empty = try core.listVariants(selectedOnly: true, rating: 3)
            XCTAssertEqual(empty.count, 0, "No match returns an empty list")
            let clone = try core.cloneVariant(sourceRef: "6")
            fake.ratings[clone.cloneVariantId] = 5
            let matches = try core.listVariants(rating: 5)
            XCTAssertEqual(matches.map(\.id), ["6", clone.cloneVariantId], "Keep distinct variants of the same image")
            XCTAssertEqual(matches.last?.workingRef, clone.workingRef, "Preserve managed clone provenance")
            XCTAssertEqual(matches.last?.isManagedWorkingClone, true)
            fake.isSession = false
            let catalogMatches = try core.listVariants(minRating: 4)
            XCTAssertEqual(catalogMatches.map(\.rating), [4, 5, 5], "Catalog inspection supports filters")
            XCTAssertTrue(catalogMatches.allSatisfy { !$0.isManagedWorkingClone && $0.workingRef == nil })
        }
        fake.calls = []
        for invalid in [-1, 6] {
            XCTAssertThrowsError(try core.listVariants(rating: invalid))
            XCTAssertThrowsError(try core.listVariants(minRating: invalid))
        }
        XCTAssertThrowsError(try core.listVariants(rating: 5, minRating: 4))
        XCTAssertTrue(fake.calls.isEmpty, "Invalid filters fail before any Capture One call")
        let validArguments: [[String: Any]] = [["rating": 5], ["rating": 0], ["minRating": 4], ["minRating": 0], ["rating": 5.0]]
        for args in validArguments {
            XCTAssertNoThrow(try ContractSchema.validate(tool: "variants_list", arguments: args))
        }
    }
}
