import Foundation
import CaptureOneCore

struct OperationJournalTests {
    static func run() {
        print("Running OperationJournalTests...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let journal = OperationJournal(sessionDirectory: tempDir)

        let entry = OperationRecord(
            operationId: "op-test-1",
            operationType: "set",
            workingRef: "c1_wrk_test",
            documentPath: tempDir.path,
            status: "pending"
        )
        XCTAssertNoThrow(try journal.append(entry: entry))

        let loaded = journal.find(operationId: "op-test-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.status, "pending")

        XCTAssertNoThrow(try journal.update(operationId: "op-test-1", status: "succeeded"))
        let updated = journal.find(operationId: "op-test-1")
        XCTAssertEqual(updated?.status, "succeeded")

        let entry1 = OperationRecord(operationId: "op-1", operationType: "set", workingRef: nil, documentPath: tempDir.path, status: "succeeded")
        let entry2 = OperationRecord(operationId: "op-2", operationType: "add", workingRef: nil, documentPath: tempDir.path, status: "pending")
        let entry3 = OperationRecord(operationId: "op-3", operationType: "set", workingRef: nil, documentPath: tempDir.path, status: "partial-failure")

        XCTAssertNoThrow(try journal.append(entry: entry1))
        XCTAssertNoThrow(try journal.append(entry: entry2))
        XCTAssertNoThrow(try journal.append(entry: entry3))

        let unresolved = journal.unresolvedEntries()
        XCTAssertEqual(unresolved.count, 2)
        XCTAssertTrue(unresolved.contains { $0.operationId == "op-2" })
        XCTAssertTrue(unresolved.contains { $0.operationId == "op-3" })
    }
}
