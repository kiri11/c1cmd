import Foundation
import CaptureOneCore

/// Offline fault table for the write pipeline. Each fault runs against every
/// mutation kind on the pipeline and asserts the resulting journal outcome.
struct WritePipelineTests {
    /// One mutation kind: its native handler, its precondition token, one write,
    /// and how the fake returns a readback that differs from the request.
    struct Kind {
        let name: String
        let handler: String
        let token: (GetResult) -> String
        let write: (SessionController, _ workingRef: String, _ token: String) throws -> Void
        let injectMismatch: (FakeScript) -> Void
    }

    enum Expected {
        /// Refused before dispatch: no Apple Event and no journal entry.
        case refused(code: String)
        /// Dispatched: the journal keeps this status, which blocks writes until reconciled.
        case journaled(status: String, code: String)
    }

    struct Fault {
        let name: String
        var staleToken = false
        let arm: (FakeScript, _ journal: URL) -> Void
        let expected: Expected
    }

    static let kinds = [
        Kind(name: "metadata", handler: "applyMetadata", token: { $0.metadataStateHash! },
             write: { core, ref, token in _ = try core.metadataSet(workingRef: ref, ifMetadataState: token, rating: 4, colorTag: 7) },
             injectMismatch: { $0.metadataFault = "mismatch" }),
    ]

    static func faults(_ kind: Kind) -> [Fault] {
        [
            Fault(name: "stale token", staleToken: true, arm: { _, _ in }, expected: .refused(code: "state-changed")),
            Fault(name: "document drift before dispatch", arm: { fake, _ in fake.documentCount = 2 },
                  expected: .refused(code: "document-changed")),
            Fault(name: "journal write failure before dispatch", arm: { _, journal in readOnly(journal) },
                  expected: .refused(code: "unexpected-error")),
            Fault(name: "dispatch throw", arm: { fake, _ in fake.fail = kind.handler },
                  expected: .journaled(status: "outcome-unknown", code: "timeout")),
            Fault(name: "document drift after dispatch", arm: { fake, _ in fake.beforeApply = { fake.documentCount = 2 } },
                  expected: .journaled(status: "outcome-unknown", code: "document-changed")),
            Fault(name: "readback mismatch", arm: { fake, _ in kind.injectMismatch(fake) },
                  expected: .journaled(status: "partial-failure", code: "readback-mismatch")),
            // The ending cannot be recorded, so the entry stays pending and still blocks writes.
            Fault(name: "journal write failure after dispatch", arm: { fake, journal in fake.beforeApply = { readOnly(journal) } },
                  expected: .journaled(status: "pending", code: "unexpected-error")),
        ]
    }

    static func readOnly(_ journal: URL) {
        try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: journal.path)
    }

    static func run() {
        print("Running WritePipelineTests...")
        for kind in kinds {
            for fault in faults(kind) { check(kind, fault) }
        }
    }

    static func check(_ kind: Kind, _ fault: Fault) {
        let label = "\(kind.name): \(fault.name)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory)
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "db-1" })
        let journal = OperationJournal(sessionDirectory: directory)
        XCTAssertNoThrowBlock(label) {
            let doc = try core.getDocumentInfo(), source = try core.get(ref: "1")
            let ref = try core.editVariant(sourceRef: "1", ifState: source.stateHash, ifDocument: doc.openToken).workingRef
            let token = kind.token(try core.get(ref: ref))
            if !FileManager.default.fileExists(atPath: journal.journalFile.path) {
                try FileManager.default.createDirectory(at: journal.journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: journal.journalFile.path, contents: nil)
            }
            let entriesBefore = try journal.validatedEntries().count
            fault.arm(fake, journal.journalFile)
            var thrown: Error?
            do { try kind.write(core, ref, fault.staleToken ? "stale" : token) } catch { thrown = error }
            fake.fail = nil; fake.beforeApply = nil; fake.metadataFault = nil; fake.documentCount = 1
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.journalFile.path)
            let dispatches = fake.calls.filter { $0 == kind.handler }.count
            guard let thrown else { return XCTFail("\(label): expected the write to fail") }
            let code = (ErrorResponse.payload(thrown)["error"] as? [String: Any])?["code"] as? String
            switch fault.expected {
            case .refused(let expected):
                XCTAssertEqual(code, expected, label)
                XCTAssertFalse(thrown is OperationFailure, "\(label): refusal carries no operation")
                XCTAssertEqual(dispatches, 0, "\(label): nothing dispatched")
                let entriesAfter = try journal.validatedEntries().count
                XCTAssertEqual(entriesAfter, entriesBefore, "\(label): nothing journaled")
                XCTAssertNoThrow(try journal.assertReady(), "\(label): writes stay available")
            case .journaled(let status, let expected):
                XCTAssertEqual(code, expected, label)
                guard let failure = thrown as? OperationFailure else { return XCTFail("\(label): expected an operation failure") }
                XCTAssertEqual(journal.find(operationId: failure.operationId)?.status, status, label)
                XCTAssertEqual(dispatches, 1, "\(label): dispatched once")
                // Uncertain outcomes block the next write before dispatch; nothing is retried.
                XCTAssertThrowsError(try kind.write(core, ref, token), "\(label): blocked until reconciled")
                XCTAssertEqual(fake.calls.filter { $0 == kind.handler }.count, 1, "\(label): never retried")
                let unrestarted = try core.operationStatus(operationId: failure.operationId)
                XCTAssertEqual(unrestarted.status, status, "\(label): the same app instance cannot reconcile")
                fake.generation += "-restarted"
                let reconciled = try core.operationStatus(operationId: failure.operationId)
                XCTAssertEqual(reconciled.status, "reconciled", label)
                XCTAssertNoThrow(try journal.assertReady(), "\(label): reconciliation clears the block")
            }
        }
    }
}
