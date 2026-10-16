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

        var ended = entry
        ended.status = "succeeded"
        XCTAssertNoThrow(try journal.append(entry: ended))
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

        incrementalReads()
        consentTimeoutHint()
    }

    /// The hint follows the recorded -1712 code, so entries written before the hint existed qualify too.
    private static func consentTimeoutHint() {
        let older = "timeout: Capture One Apple Event timed out (-1712): AppleEvent timed out."
        func blocked(_ entry: OperationRecord) -> String {
            var message = ""
            withJournal { journal in
                try journal.append(entry: entry)
                XCTAssertThrowsError(try journal.assertReady()) { message = String(describing: $0) }
            }
            return message
        }
        let covered = blocked(record("covered", "outcome-unknown", error: older))
        XCTAssertTrue(covered.contains("Inspect operation status; it reconciles this write once Capture One answers, without a restart. " + AppleScriptExecutor.timeoutHint), covered)
        XCTAssertFalse(covered.contains("Restart"), "A covered write needs no restart: \(covered)")
        let previewMessage = blocked(OperationRecord(operationId: "preview", operationType: "preview", workingRef: nil,
                                                     documentPath: "/tmp/doc", status: "outcome-unknown", error: older))
        XCTAssertTrue(previewMessage.contains("otherwise restart Capture One first. " + AppleScriptExecutor.timeoutHint), previewMessage)
        let other = blocked(record("other", "outcome-unknown", error: "timeout: injected late reply"))
        XCTAssertTrue(other.contains("without a restart."), other)
        XCTAssertFalse(other.contains(AppleScriptExecutor.timeoutHint), "Only a -1712 entry gets the hint: \(other)")
    }

    private static func record(_ id: String, _ status: String, error: String? = nil) -> OperationRecord {
        OperationRecord(operationId: id, timestamp: "2026-01-01T00:00:00Z", operationType: "set", workingRef: nil, documentPath: "/tmp/doc", status: status, error: error)
    }

    private static func line(_ entry: OperationRecord) -> Data {
        var data = try! JSONEncoder().encode(entry)
        data.append(0x0a)
        return data
    }

    private static func rawAppend(_ data: Data, to file: URL) {
        let handle = try! FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
    }

    private static func truncate(_ file: URL, to length: Int) {
        let handle = try! FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try! handle.truncate(atOffset: UInt64(length))
    }

    private static func ids(_ journal: OperationJournal) -> [String] {
        ((try? journal.validatedEntries()) ?? []).map { "\($0.operationId):\($0.status)" }
    }

    /// Journals are fresh per case because the read cache is process-wide and keyed by path.
    private static func withJournal(_ body: (OperationJournal) throws -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try body(OperationJournal(sessionDirectory: dir)))
    }

    private static func incrementalReads() {
        withJournal { journal in
            try! journal.append(entry: record("a", "pending"))
            try! journal.append(entry: record("b", "pending"))
            XCTAssertEqual(ids(journal), ["a:pending", "b:pending"])
            try! OperationJournal(sessionDirectory: journal.sessionDirectory).append(entry: record("a", "succeeded"))
            XCTAssertEqual(ids(journal), ["a:succeeded", "b:pending"], "append by another instance keeps first-appearance order with the latest snapshot")
            rawAppend(line(record("c", "failed")) + line(record("b", "succeeded")), to: journal.journalFile)
            XCTAssertEqual(ids(journal), ["a:succeeded", "b:succeeded", "c:failed"], "raw appends are visible on the next read")
            XCTAssertEqual(ids(journal), ["a:succeeded", "b:succeeded", "c:failed"], "an unchanged journal reads the same")
        }

        withJournal { journal in
            try! journal.append(entry: record("a", "succeeded"))
            XCTAssertEqual(ids(journal), ["a:succeeded"])
            rawAppend(Data("{\"operationId\": \"broken\"\n".utf8), to: journal.journalFile)
            XCTAssertThrowsError(try journal.validatedEntries(), "a corrupt appended line fails closed")
            XCTAssertThrowsError(try journal.validatedEntries(), "a corrupt appended line keeps failing closed")
            XCTAssertThrowsError(try journal.append(entry: record("b", "pending")), "a corrupt journal blocks appends")
            XCTAssertTrue(journal.unresolvedEntries().isEmpty && journal.find(operationId: "a") == nil, "lenient reads see nothing from a corrupt journal")
        }

        withJournal { journal in
            try! journal.append(entry: record("a", "succeeded"))
            XCTAssertEqual(ids(journal), ["a:succeeded"])
            let length = try! Data(contentsOf: journal.journalFile).count
            rawAppend(line(record("x", "pending")) + Data("{broken\n".utf8), to: journal.journalFile)
            XCTAssertThrowsError(try journal.validatedEntries())
            truncate(journal.journalFile, to: length)
            XCTAssertEqual(ids(journal), ["a:succeeded"], "a failed read leaves no partly decoded lines behind")
        }

        withJournal { journal in
            try! journal.append(entry: record("a", "pending"))
            XCTAssertEqual(ids(journal), ["a:pending"])
            rawAppend(Data([0xff, 0xfe, 0x0a]), to: journal.journalFile)
            XCTAssertThrowsError(try journal.validatedEntries(), "an appended non-UTF-8 line fails closed")
        }

        withJournal { journal in
            try! journal.append(entry: record("a", "pending"))
            try! journal.append(entry: record("a", "succeeded"))
            XCTAssertEqual(ids(journal), ["a:succeeded"])
            let first = line(record("a", "pending")).count
            let length = try! Data(contentsOf: journal.journalFile).count
            truncate(journal.journalFile, to: length - 5)
            XCTAssertThrowsError(try journal.validatedEntries(), "a journal cut mid-line below the decoded offset fails closed")
            truncate(journal.journalFile, to: first)
            XCTAssertEqual(ids(journal), ["a:pending"], "a journal cut to fewer bytes than the decoded offset is revalidated")
            try! journal.append(entry: record("b", "succeeded"))
            XCTAssertThrowsError(try journal.assertReady(), "the revalidated journal still blocks on its pending entry")
            let grown = try! Data(contentsOf: journal.journalFile).count
            rawAppend(line(record("c", "succeeded")).prefix(20), to: journal.journalFile)
            XCTAssertThrowsError(try journal.validatedEntries(), "a partial line past the decoded offset fails closed")
            truncate(journal.journalFile, to: grown)
            XCTAssertEqual(ids(journal), ["a:pending", "b:succeeded"], "removing the partial line restores the journal")
        }

        withJournal { journal in
            for index in 0..<100 { try! journal.append(entry: record("op-\(index)", "succeeded")) }
            XCTAssertEqual(ids(journal).count, 100)
            var content = try! Data(contentsOf: journal.journalFile)
            XCTAssertTrue(content.count > 4096 * 2, "the corrupt line lies outside the compared tail")
            content[content.startIndex] = UInt8(ascii: "x")
            let replacement = journal.journalFile.appendingPathExtension("new")
            let inode = { (try! FileManager.default.attributesOfItem(atPath: journal.journalFile.path)[.systemFileNumber] as! Int) }
            let before = inode()
            try! content.write(to: replacement)
            XCTAssertEqual(rename(replacement.path, journal.journalFile.path), 0)
            XCTAssertNotEqual(inode(), before, "the replacement has a new inode")
            XCTAssertThrowsError(try journal.validatedEntries(), "an atomically replaced journal of the same length is revalidated and fails closed")
        }

        withJournal { journal in
            for index in 0..<100 { try! journal.append(entry: record("op-\(index)", "succeeded", error: "aaaa")) }
            XCTAssertEqual(ids(journal).count, 100)
            let content = try! Data(contentsOf: journal.journalFile)
            let handle = try! FileHandle(forWritingTo: journal.journalFile)
            try! handle.seek(toOffset: UInt64(content.lastRange(of: Data("aaaa".utf8))!.lowerBound))
            try! handle.write(contentsOf: Data("bbbb".utf8))
            try! handle.close()
            XCTAssertEqual(try? journal.validatedEntries().last?.error, "bbbb", "an in-place rewrite of the last bytes is revalidated")
        }

        withJournal { journal in
            try! journal.append(entry: record("early", "outcome-unknown"))
            for index in 0..<300 { try! journal.append(entry: record("op-\(index)", index % 2 == 0 ? "pending" : "succeeded")) }
            for index in stride(from: 0, to: 300, by: 2) { try! journal.append(entry: record("op-\(index)", "succeeded")) }
            XCTAssertThrowsError(try journal.assertReady(), "an unresolved entry in old history blocks writes after many appends") { error in
                XCTAssertEqual((error as? OperationFailure)?.operationId, "early")
            }
            XCTAssertEqual(journal.unresolvedEntries().map(\.operationId), ["early"])
            XCTAssertEqual(journal.find(operationId: "early")?.status, "outcome-unknown", "old history stays findable after appends")
            XCTAssertEqual(journal.find(operationId: "op-0")?.status, "succeeded")
            XCTAssertEqual(ids(journal).count, 301)
        }
    }
}
