import Foundation
import CaptureOneCore

/// A timed-out preview resolves through operation status without a restart only when its
/// own folder holds the JPEG it asked for and the variant still matches the journal.
struct LatePreviewTests {
    static func run() {
        print("Running LatePreviewTests...")
        timeoutIsConfigurable()
        lateJPEGResolvesWithoutRestart()
        unmetConditionsStayBlocked()
        journalGapsStayBlocked()
        restartKeepsReconciliation()
    }

    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fake: GeometryFake
        let journal: OperationJournal
        var identity = "database-1"
        lazy var core = SessionController(lock: testLock, executor: fake, appInstance: { [unowned self] in fake.base.generation },
                                          databaseIdentity: { [unowned self] _ in identity },
                                          imageDimensions: { _ in [6000, 4000] }, isAppRunning: { true })
        init() {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fake = GeometryFake(directory: directory)
            fake.holdPreview = true
            journal = OperationJournal(sessionDirectory: directory)
        }
        var journalLines: Int { ((try? String(contentsOf: journal.journalFile)) ?? "").split(separator: "\n").count }
    }

    /// Runs `body` after a preview of variant 1 timed out before Capture One wrote its JPEG.
    static func timedOut(_ body: (Fixture, OperationRecord) throws -> Void) {
        let f = Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        XCTAssertNoThrowBlock {
            do {
                _ = try f.core.preview(ref: "1", timeout: 0.2)
                XCTFail("A held export must time out")
            } catch let failure as OperationFailure {
                XCTAssertEqual((failure.cause as? C1Error)?.errorCode, "timeout", "Actual: \(failure)")
                let entry = try f.journal.validatedEntries().first { $0.operationId == failure.operationId }!
                XCTAssertEqual(entry.status, "outcome-unknown")
                try body(f, entry)
            }
        }
    }

    /// Operation status leaves `operationId` at `status` and every write stays blocked.
    static func assertBlocked(_ f: Fixture, _ operationId: String, status: String = "outcome-unknown", _ label: String) throws {
        let lines = f.journalLines
        let observed = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(observed.status, status, label)
        XCTAssertNil(observed.resolution, label)
        XCTAssertEqual(f.journalLines, lines, "\(label): an unresolved status appends nothing")
        XCTAssertThrowsError(try f.core.cloneVariant(sourceRef: "1"), label) {
            XCTAssertEqual(($0 as? OperationFailure)?.operationId, operationId, "\(label): blocked by the preview")
        }
        XCTAssertEqual(f.journalLines, lines, "\(label): a blocked write dispatches nothing")
    }

    static func timeoutIsConfigurable() {
        XCTAssertEqual(PreviewManager.defaultTimeout, 120, "Documented default preview timeout")
        let short = Fixture(), slow = Fixture()
        defer { for f in [short, slow] { try? FileManager.default.removeItem(at: f.directory) } }
        let start = Date()
        XCTAssertThrowsError(try short.core.preview(ref: "1", timeout: 0.3)) {
            XCTAssertEqual((($0 as? OperationFailure)?.cause as? C1Error)?.errorCode, "timeout", "Actual: \($0)")
        }
        XCTAssertTrue(Date().timeIntervalSince(start) < 5, "A short timeout is honored")
        XCTAssertNoThrowBlock {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? slow.fake.landHeldPreview() }
            let preview = try slow.core.preview(ref: "1", timeout: 10)
            XCTAssertEqual(preview.size, 1500, "An export slower than half a second succeeds within a longer timeout")
            let entry = try slow.journal.validatedEntries().last
            XCTAssertEqual(entry?.status, "succeeded")
        }
    }

    static func lateJPEGResolvesWithoutRestart() {
        timedOut { f, entry in
            let current = try f.core.get(ref: "1")
            XCTAssertEqual(entry.preconditionGeometryStateHash, current.geometryStateHash, "The preview journals its geometry token")
            try assertBlocked(f, entry.operationId, "before the JPEG lands")
            try f.fake.landHeldPreview()
            let resolved = try f.core.operationStatus(operationId: entry.operationId)
            XCTAssertEqual(resolved.status, "succeeded")
            XCTAssertEqual(resolved.resolution, .latePreview)
            XCTAssertNil(resolved.error)
            XCTAssertEqual(resolved.previewOutputPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, f.fake.heldPreview!.file.resolvingSymlinksInPath(), "The status names the landed JPEG")
            XCTAssertNoThrow(try f.journal.assertReady())
            let doctor = try f.core.doctor()
            XCTAssertEqual(doctor.unresolvedOperationsCount, 0)
            let lines = f.journalLines
            let again = try f.core.operationStatus(operationId: entry.operationId)
            XCTAssertEqual(again, resolved, "Resolution is stable")
            XCTAssertEqual(f.journalLines, lines, "A resolved status appends nothing")
            let clone = try f.core.cloneVariant(sourceRef: "1")
            let state = try f.core.get(ref: clone.workingRef).stateHash
            _ = try f.core.mutate(workingRefString: clone.workingRef, ifState: state, setAdjustments: Adjustments(exposure: 0.25), addAdjustments: nil)
            XCTAssertEqual(f.fake.base.values[clone.cloneVariantId]![0], 0.25, "Writes resume without a restart")
        }
    }

    static func unmetConditionsStayBlocked() {
        let cases: [(String, (Fixture) throws -> Void)] = [
            ("no JPEG", { _ in }),
            ("partial JPEG", { f in
                try f.fake.landHeldPreview()
                let file = f.fake.heldPreview!.file
                try Data(contentsOf: file).prefix(30).write(to: file)
            }),
            ("undecodable JPEG", { f in try (Data(repeating: 0x55, count: 64) + Data([0xff, 0xd9])).write(to: f.fake.heldPreview!.file) }),
            ("two JPEGs", { f in
                try f.fake.landHeldPreview()
                try FileManager.default.copyItem(at: f.fake.heldPreview!.file, to: f.fake.heldPreview!.file.deletingLastPathComponent().appendingPathComponent("other.jpg"))
            }),
            ("another long edge", { f in f.fake.base.exportedLongEdgeOverride = 1499; try f.fake.landHeldPreview() }),
            ("another aspect", { f in try f.fake.landHeldPreview(aspect: 1) }),
            ("changed tonal state", { f in f.fake.base.values["1"]![1] = 7; try f.fake.landHeldPreview() }),
            ("changed geometry, same aspect", { f in
                var record = f.fake.record("1"); record["cropValues"] = [3000.0, 2000, 5400, 3600]; f.fake.records["1"] = record
                try f.fake.landHeldPreview()
            }),
            ("another parent image", { f in f.fake.base.parents["1"] = "/elsewhere/fixture.CR3"; try f.fake.landHeldPreview() }),
            ("replaced database", { f in f.identity = "database-2"; try f.fake.landHeldPreview() }),
        ]
        for (label, change) in cases {
            timedOut { f, entry in
                try change(f)
                try assertBlocked(f, entry.operationId, label)
            }
        }
    }

    /// Entries lacking the evidence a late preview needs stay unresolved even with a complete JPEG.
    static func journalGapsStayBlocked() {
        func rewritten(_ f: Fixture, _ entry: OperationRecord, _ change: (inout [String: Any]) throws -> Void) throws {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
            try change(&object)
            try f.journal.append(entry: JSONDecoder().decode(OperationRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        let cases: [(String, String, (Fixture, inout [String: Any]) throws -> Void)] = [
            ("not a preview", "outcome-unknown", { _, object in object["operationType"] = "native"; object["nativeAction"] = "mask.refine" }),
            ("still pending", "pending", { _, object in object["status"] = "pending" }),
            ("no geometry token", "outcome-unknown", { _, object in object.removeValue(forKey: "preconditionGeometryStateHash") }),
            ("no preview size", "outcome-unknown", { _, object in object.removeValue(forKey: "previewSize") }),
            ("no crop geometry", "outcome-unknown", { _, object in object.removeValue(forKey: "beforeGeometry") }),
            ("another folder", "outcome-unknown", { f, object in
                let other = f.fake.heldPreview!.file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: f.fake.heldPreview!.file, to: other.appendingPathComponent("preview.jpg"))
                object["previewOutputPath"] = other.path
            }),
        ]
        for (label, status, change) in cases {
            timedOut { f, entry in
                try f.fake.landHeldPreview()
                try rewritten(f, entry) { try change(f, &$0) }
                try assertBlocked(f, entry.operationId, status: status, label)
            }
        }
    }

    /// After a restart the restart reconciliation runs, even when the late JPEG is complete.
    static func restartKeepsReconciliation() {
        timedOut { f, entry in
            try f.fake.landHeldPreview()
            f.fake.base.generation += "-restarted"
            let reconciled = try f.core.operationStatus(operationId: entry.operationId)
            XCTAssertEqual(reconciled.status, "reconciled")
            XCTAssertEqual(reconciled.resolution, .restart)
        }
    }
}
