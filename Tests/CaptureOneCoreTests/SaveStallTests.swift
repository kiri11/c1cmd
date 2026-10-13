import Foundation
import CaptureOneCore

/// Capture One saves its database about once a minute. A write it acknowledged but has not
/// saved after `SaveStall.stallSeconds` makes every unsaved write's outcome unknown (#43, #45).
struct SaveStallTests {
    static func run() {
        print("Running SaveStallTests...")
        stallRules()
        stallBlocksWritesUntilRestart()
        savingDatabaseNeverStalls()
        journalFieldsAreDeclared()
    }

    static let dispatched = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(_ type: String = "set", status: String = "succeeded", instance: String = "app-1",
                       at offset: TimeInterval = 0, changed: Bool = true) -> OperationRecord {
        var entry = OperationRecord(timestamp: ISO8601DateFormatter().string(from: dispatched.addingTimeInterval(offset)),
                                    operationType: type, workingRef: nil, documentPath: "/fixture", status: status)
        entry.appInstance = instance
        if changed { entry.diff = ["exposure": DoubleDiff(before: 0, after: 1)] }
        return entry
    }

    static func stalled(_ entries: [OperationRecord], modified offset: TimeInterval, now: TimeInterval) -> [String] {
        (try? SaveStall.stalled(entries, appInstance: "app-1", now: dispatched.addingTimeInterval(now)) {
            dispatched.addingTimeInterval(offset)
        })?.map(\.operationId) ?? ["error"]
    }

    static func stallRules() {
        let first = record(), later = record(at: 120)
        XCTAssertEqual(stalled([first, later], modified: 121, now: 1000), [], "Healthy: saved after every dispatch")
        XCTAssertEqual(stalled([first, later], modified: -10, now: SaveStall.stallSeconds - 1), [], "Normal lag below the bound")
        XCTAssertEqual(stalled([first, later], modified: -10, now: SaveStall.stallSeconds), [first.operationId, later.operationId],
                       "At the bound every unsaved write is stalled, including younger ones")
        XCTAssertEqual(stalled([first, later], modified: 60, now: SaveStall.stallSeconds + 60), [],
                       "A save after the oldest write leaves only a younger write under the bound")
        XCTAssertEqual(stalled([first, later], modified: 60, now: 420), [later.operationId], "Only writes after the last save are unsaved")
        let ignored = [record("preview"), record(changed: false), record(instance: "app-0"),
                       record(status: "failed"), record(status: "outcome-unknown"), record(status: "reconciled"), record("native", changed: false)]
        XCTAssertEqual(stalled(ignored, modified: -10, now: 1000), [],
                       "Previews, no-op writes, other processes and unresolved or reconciled writes never stall")
        func reconciled(_ resolution: Resolution, adjusted: Bool) -> OperationRecord {
            var entry = OperationRecord(timestamp: ISO8601DateFormatter().string(from: dispatched), operationType: "set",
                workingRef: nil, documentPath: "/fixture", beforeAdjustments: Adjustments(exposure: 0),
                afterAdjustments: Adjustments(exposure: adjusted ? 1 : 0), status: "reconciled")
            entry.appInstance = "app-1"
            entry.resolution = resolution
            return entry
        }
        let barrier = reconciled(.probeBarrier, adjusted: true)
        XCTAssertEqual(stalled([barrier, reconciled(.probeBarrier, adjusted: false), reconciled(.restart, adjusted: true)],
                               modified: -10, now: 1000), [barrier.operationId],
                       "A barrier reconcile that observed a change stays in the running process and can stall unsaved")
        XCTAssertEqual(stalled([record("clone", changed: false), record("delete", changed: false)], modified: -10, now: 1000).count, 2,
                       "Creating and deleting variants always changes the database")
        XCTAssertNoThrow(try SaveStall.stalled([record()], appInstance: "app-1", now: dispatched.addingTimeInterval(10)) {
            throw C1Error.identityAmbiguous("not read")
        }, "Fresh writes need no database read")
    }

    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fake: FakeScript
        let journal: OperationJournal
        var modified = Date.distantPast
        var clock: Date?
        lazy var core = SessionController(executor: fake, appInstance: { [unowned self] in fake.generation },
                                          databaseIdentity: { _ in "database-1" },
                                          databaseModified: { [unowned self] _ in modified },
                                          now: { [unowned self] in clock ?? Date() }, isAppRunning: { true })
        init() {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fake = FakeScript(directory: directory)
            journal = OperationJournal(sessionDirectory: directory)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var clones: Int { fake.calls.filter { $0 == "cloneVariant" }.count }
        func entry(_ id: String) throws -> OperationRecord { try journal.validatedEntries().first { $0.operationId == id }! }
    }

    static func stallBlocksWritesUntilRestart() {
        let f = Fixture()
        XCTAssertNoThrowBlock {
            _ = try f.core.cloneVariant(sourceRef: "1")
            let first = try f.journal.validatedEntries().last!
            let start = SaveStall.dispatchDate(first)!
            f.modified = start.addingTimeInterval(-30)
            f.clock = start.addingTimeInterval(SaveStall.stallSeconds - 1)
            _ = try f.core.cloneVariant(sourceRef: "1")
            let second = try f.journal.validatedEntries().last!
            XCTAssertEqual([first, second].map { try! f.entry($0.operationId).status }, ["succeeded", "succeeded"],
                           "Unsaved under the bound is normal lag")

            f.clock = start.addingTimeInterval(SaveStall.stallSeconds)
            let clones = f.clones
            XCTAssertThrowsError(try f.core.cloneVariant(sourceRef: "1")) {
                XCTAssertEqual(($0 as? OperationFailure)?.operationId, first.operationId, "The oldest unsaved write blocks")
                XCTAssertTrue(String(describing: $0).contains("stopped saving"), "Actual: \($0)")
            }
            XCTAssertEqual(f.clones, clones, "A stalled save dispatches nothing")
            for id in [first.operationId, second.operationId] {
                let entry = try f.entry(id)
                XCTAssertEqual(entry.status, "outcome-unknown")
                XCTAssertEqual(entry.saveStalledAt, ISO8601DateFormatter().string(from: f.clock!))
                XCTAssertTrue(entry.error?.contains("has not saved the database since") == true, entry.error ?? "")
            }
            let firstError = try f.entry(first.operationId).error ?? ""
            XCTAssertTrue(firstError.contains("\(Int(SaveStall.stallSeconds)) s ago"), "The error names the write's age: \(firstError)")

            let report = try f.core.doctor()
            XCTAssertEqual(report.saveStall?.operationIds, [first.operationId, second.operationId])
            XCTAssertEqual(report.saveStall?.oldestAgeSeconds, Int(SaveStall.stallSeconds))
            XCTAssertEqual(report.writesDisabledReason, .saveStalled)
            XCTAssertFalse(report.allChecksPassed)
            XCTAssertTrue(OutputFormatter.renderDoctorReport(report, format: .human).contains("Save Stalled        : 2 unsaved write(s)"))

            f.modified = f.clock!.addingTimeInterval(1)
            XCTAssertThrowsError(try f.core.cloneVariant(sourceRef: "1"), "A late save does not lift the block")
            let unrestarted = try f.core.operationStatus(operationId: first.operationId)
            XCTAssertEqual(unrestarted.status, "outcome-unknown", "Operation status needs a restart")

            f.fake.generation = "app-2"
            for id in [first.operationId, second.operationId] {
                let reconciled = try f.core.operationStatus(operationId: id)
                XCTAssertEqual(reconciled.status, "reconciled")
            }
            let restarted = try f.core.doctor()
            XCTAssertNil(restarted.saveStall)
            _ = try f.core.cloneVariant(sourceRef: "1")
            XCTAssertEqual(f.clones, clones + 1, "Writes resume after restart and reconciliation")
        }
    }

    static func savingDatabaseNeverStalls() {
        let f = Fixture()
        XCTAssertNoThrowBlock {
            for step in 0..<4 {
                _ = try f.core.cloneVariant(sourceRef: "1")
                let dispatched = SaveStall.dispatchDate(try f.journal.validatedEntries().last!)!
                f.modified = dispatched.addingTimeInterval(45)
                f.clock = dispatched.addingTimeInterval(SaveStall.stallSeconds * Double(step + 1))
            }
            let statuses = try f.journal.validatedEntries().map(\.status)
            XCTAssertEqual(statuses, Array(repeating: "succeeded", count: 4))
            let report = try f.core.doctor()
            XCTAssertNil(report.saveStall)
        }
    }

    /// `operation_status` returns the journal record, and its schema admits no other fields.
    static func journalFieldsAreDeclared() {
        let schema = ContractSchema.document()
        let status = ((schema["responses"] as! [String: Any])["operation_status"] as! [String: Any])["properties"] as! [String: Any]
        let fields = Mirror(reflecting: record()).children.compactMap(\.label)
        XCTAssertEqual(fields.filter { status[$0] == nil }, [], "Every journal field is declared in operation_status")
    }
}
