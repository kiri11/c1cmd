import Foundation
import CaptureOneCore

struct ReadWorkflowTests {
    static func assertNil(_ value: Any?, _ message: String = "") { XCTAssertNil(value, message) }
    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") { XCTAssertEqual(a, b, message) }

    static func run() {
        print("Running ReadWorkflowTests...")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeScript(directory: dir)
        fake.values["2"] = [1, 2, 3, 5000, 0]
        fake.ratings = ["1": 0, "2": 3]
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "db-1" })
        var workflowID: String?
        let workflow = ReadWorkflow(core: core, indexURL: dir.appendingPathComponent("active"), workflowID: { workflowID })
        let journal = OperationJournal(sessionDirectory: dir)
        XCTAssertNoThrowBlock {
            assertNil(try workflow.get(ref: "1"), "Inactive workflows must not alter legacy get")
            XCTAssertTrue(fake.calls.isEmpty, "No extra Apple Events when optimization is inactive")
            let started = try workflow.begin()
            workflowID = started["workflowId"] as? String
            assertEqual(started["active"] as? Bool, true)
            assertEqual(started["sqliteEnabled"] as? Bool, false, "Sessions use native-confirmed cache, never Catalog SQL")
            let outsider = ReadWorkflow(core: core, indexURL: dir.appendingPathComponent("active"), workflowID: { nil })
            assertNil(try outsider.get(ref: "1"), "An unrelated caller must not inherit the agent cache")
            assertNil(try workflow.get(ref: "1", workflowID: "wrong-id"))
            let first = try workflow.get(ref: "1")!
            assertNil(first["stateHash"], "Browsing must never issue a mutation token")
            assertNil(first["geometryStateHash"])
            let reads = fake.calls.filter { $0 == "getAdjustmentsBatch" }.count
            _ = try workflow.get(ref: "1")
            assertEqual(fake.calls.filter { $0 == "getAdjustmentsBatch" }.count, reads, "Warm get avoids native value reads")
            assertNil(try workflow.get(ref: "c1_edit_test"), "Editing references always bypass caching")
            var metadata = OperationRecord(operationType: "metadata_set", workingRef: "test", documentPath: dir.path, status: "succeeded")
            metadata.appInstance = fake.generation; metadata.documentIdentity = "db-1"
            metadata.nativeVariantId = "1"; metadata.parentImagePath = fake.parent
            metadata.afterMetadata = VariantMetadata(rating: 5, colorTag: 2)
            try journal.append(entry: metadata)
            // Deliberately leave the fake native/SQL baseline at zero: only the
            // acknowledged journal projection should admit this newly rated variant.
            let filtered = try workflow.variants(collection: nil, selected: false, rating: nil, minRating: 4)!
            assertEqual(filtered.count, 1)
            assertEqual(filtered.first?["id"] as? String, "1")
            assertEqual(filtered.first?["rating"] as? Int, 5)
            let changed = try workflow.get(ref: "1")!
            assertEqual((changed["metadata"] as? [String: Any])?["rating"] as? Int, 5)
            assertEqual(fake.calls.filter { $0 == "getAdjustmentsBatch" }.count, reads)
            var tonal = OperationRecord(operationType: "set", workingRef: "test", documentPath: dir.path, afterAdjustments: Adjustments(exposure: 0.25, contrast: 4, saturation: -3, temperature: 5100, tint: 2), status: "succeeded")
            tonal.appInstance = fake.generation; tonal.documentIdentity = "db-1"; tonal.nativeVariantId = "1"; tonal.parentImagePath = fake.parent
            try journal.append(entry: tonal)
            let after = try workflow.get(ref: "1")!
            assertEqual((after["adjustments"] as? [String: Any])?["exposure"] as? Double, 0.25)
            assertEqual((after["adjustments"] as? [String: Any])?["temperature"] as? Double, 5100)
            assertNil(try workflow.variants(collection: "Other", selected: false, rating: nil, minRating: nil), "Scope mismatch must be native")
            let diff = try workflow.diff(ref1: "1", ref2: "1")!
            assertNil(diff["stateHash1"])
            // A fresh workflow instance must reuse the disk state across CLI processes.
            let other = ReadWorkflow(core: core, indexURL: dir.appendingPathComponent("active"), workflowID: { workflowID })
            assertEqual((try other.get(ref: "1")?["adjustments"] as? [String: Any])?["exposure"] as? Double, 0.25)
            fake.generation = "app-2"
            assertNil(try workflow.get(ref: "1"), "Restart invalidates the entire browsing baseline")
            assertEqual(try workflow.status()["active"] as? Bool, false)
            _ = try workflow.end()
        }
        for status in ["pending", "outcome-unknown", "failed", "partial-failure", "reconciled"] {
            XCTAssertNoThrowBlock {
                try? FileManager.default.removeItem(at: journal.journalFile)
                workflowID = try workflow.begin()["workflowId"] as? String
                var op = OperationRecord(operationType: "set", workingRef: "test", documentPath: dir.path, status: status)
                op.appInstance = fake.generation; op.documentIdentity = "db-1"; op.nativeVariantId = "1"; op.parentImagePath = fake.parent
                try journal.append(entry: op)
                assertNil(try workflow.get(ref: "1"), "\(status) must never be overlaid as confirmed state")
                _ = try workflow.end()
            }
        }
        for operation in ["clone", "delete", "preview", "geometry", "native"] {
            XCTAssertNoThrowBlock {
                try? FileManager.default.removeItem(at: journal.journalFile)
                workflowID = try workflow.begin()["workflowId"] as? String
                var op = OperationRecord(operationType: operation, workingRef: "test", documentPath: dir.path, status: "succeeded")
                op.appInstance = fake.generation; op.documentIdentity = "db-1"; op.nativeVariantId = "1"; op.parentImagePath = fake.parent
                try journal.append(entry: op)
                assertNil(try workflow.variants(collection: nil, selected: false, rating: nil, minRating: nil), "Structural/unsupported actions invalidate scope")
                _ = try workflow.end()
            }
        }
        for damage in ["truncated-journal", "corrupt-journal", "corrupt-cache", "wrong-parent"] {
            XCTAssertNoThrowBlock {
                try? FileManager.default.removeItem(at: journal.journalFile)
                var op = OperationRecord(operationType: "metadata_set", workingRef: "test", documentPath: dir.path, status: "succeeded")
                op.appInstance = fake.generation; op.documentIdentity = "db-1"; op.nativeVariantId = "1"; op.parentImagePath = fake.parent
                op.afterMetadata = VariantMetadata(rating: 0, colorTag: 0)
                try journal.append(entry: op)
                workflowID = try workflow.begin()["workflowId"] as? String
                if damage == "truncated-journal" { try FileManager.default.removeItem(at: journal.journalFile) }
                if damage == "corrupt-journal" { try Data("invalid-json\n".utf8).write(to: journal.journalFile) }
                if damage == "corrupt-cache" { try Data("invalid-json".utf8).write(to: dir.appendingPathComponent(".c1/read-workflow.json")) }
                if damage == "wrong-parent" {
                    var changed = OperationRecord(operationType: "metadata_set", workingRef: "test", documentPath: dir.path, status: "succeeded")
                    changed.appInstance = fake.generation; changed.documentIdentity = "db-1"; changed.nativeVariantId = "1"
                    changed.parentImagePath = "/different.CR3"; changed.afterMetadata = op.afterMetadata
                    try journal.append(entry: changed)
                }
                assertNil(try workflow.get(ref: "1"), "\(damage) must discard cached browsing results")
            }
        }
    }
}
