import Foundation
import CaptureOneCore

struct DoctorTests {
    static func run() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory)
        var identityFailure = false
        let core = SessionController(executor: fake, appInstance: { "test" }, databaseIdentity: { _ in
            if identityFailure { throw C1Error.identityAmbiguous("fixture identity unavailable") }
            return "db"
        }, isAppRunning: { true })
        XCTAssertNoThrowBlock {
            let clean = try core.doctor()
            XCTAssertTrue(clean.allChecksPassed)
            XCTAssertEqual(clean.unresolvedOperationsCount, 0)
            XCTAssertNil(clean.diagnosticError)
            XCTAssertEqual(fake.calls, ["getAppAndDocInfo"], "Doctor resolves one coherent discovery response without a second Apple Event")
            let journal = OperationJournal(sessionDirectory: directory)
            try journal.append(entry: OperationRecord(operationType: "set", workingRef: nil, documentPath: directory.path, status: "pending"))
            let pending = try core.doctor()
            XCTAssertEqual(pending.unresolvedOperationsCount, 1)
            XCTAssertNil(pending.diagnosticError)
            XCTAssertFalse(pending.allChecksPassed)
            XCTAssertFalse(pending.writesEnabled)
            identityFailure = true
            let unknown = try core.doctor()
            XCTAssertNil(unknown.unresolvedOperationsCount)
            XCTAssertFalse(unknown.allChecksPassed)
            XCTAssertFalse(unknown.writesEnabled)
            XCTAssertEqual(unknown.diagnosticError, .identityAmbiguous("fixture identity unavailable"))
            let encoded = try JSONEncoder().encode(unknown)
            let decoded = try JSONDecoder().decode(DoctorReport.self, from: encoded)
            XCTAssertEqual(decoded, unknown)
            let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            XCTAssertNil(json["unresolvedOperationsCount"], "Unknown is never a fabricated count")
            XCTAssertEqual((json["diagnosticError"] as? [String: Any])?["code"] as? String, "identity-ambiguous")
            XCTAssertTrue(OutputFormatter.renderDoctorReport(unknown, format: .human).contains("Unknown (journal"))
            identityFailure = false
            fake.documentCount = 2
            let multiple = try core.doctor()
            XCTAssertFalse(multiple.allChecksPassed)
            XCTAssertEqual(multiple.diagnosticError?.errorCode, "document-changed")
            fake.documentCount = 1
            fake.fail = "getAppAndDocInfo"
            let failed = try core.doctor()
            XCTAssertEqual(failed.diagnosticError, .timeout("injected late reply"))
            XCTAssertNil(failed.unresolvedOperationsCount)
            XCTAssertFalse(failed.allChecksPassed)
            fake.fail = nil
            let journalDir = directory.appendingPathComponent(".c1")
            try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
            try Data("broken journal\n".utf8).write(to: journalDir.appendingPathComponent("journal.jsonl"))
            let corrupt = try core.doctor()
            XCTAssertNil(corrupt.unresolvedOperationsCount)
            XCTAssertNotNil(corrupt.diagnosticError)
            XCTAssertFalse(corrupt.writesEnabled)
            let stopped = try SessionController(executor: fake, isAppRunning: { false }).doctor()
            XCTAssertFalse(stopped.appRunning)
            XCTAssertNil(stopped.unresolvedOperationsCount)
        }
    }
}
