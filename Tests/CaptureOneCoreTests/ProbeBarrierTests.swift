import Foundation
import CaptureOneCore

/// Reconciling an uncertain write in the same app instance once a later Apple Event is answered.
struct ProbeBarrierTests {
    static let coveredActions = ["layer.create", "layer.delete", "mask.people", "color.create", "color.delete",
                                 "dehaze.pick", "dehaze.recalculate", "lens.reset", "luma.clear", "style.apply",
                                 "mask.clear", "mask.invert", "mask.fill", "mask.rasterize", "mask.copy"]
    static let uncoveredActions = ["mask.feather", "mask.refine"]

    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fake: FakeScript
        let core: SessionController
        let journal: OperationJournal
        var editRef = ""

        init(native: Bool = false) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fake = FakeScript(directory: directory)
            self.fake = fake
            core = SessionController(executor: native ? NativeFake(fake) : fake, appInstance: { fake.generation },
                                     databaseIdentity: { _ in "db-1" }, imageDimensions: { _ in [6000, 4000] })
            journal = OperationJournal(sessionDirectory: directory)
            let doc = try core.getDocumentInfo(), source = try core.get(ref: "1")
            editRef = try core.editVariant(sourceRef: "1", ifState: source.stateHash, ifDocument: doc.openToken).workingRef
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Journal lines, counting every appended snapshot rather than the latest per operation.
        var records: Int { ((try? String(contentsOf: journal.journalFile, encoding: .utf8)) ?? "").split(separator: "\n").count }

        /// A tonal set whose reply is lost; Capture One may still apply it later.
        func uncertainTonal(exposure: Double = 2) throws -> String {
            let current = try core.get(ref: editRef)
            fake.fail = "applyAdjustments"
            defer { fake.fail = nil }
            do {
                _ = try core.mutate(workingRefString: editRef, ifState: current.stateHash,
                                    setAdjustments: Adjustments(exposure: exposure), addAdjustments: nil)
            } catch let failure as OperationFailure { return failure.operationId }
            throw C1Error.invalidRequest("Expected an injected timeout")
        }

        func assertStillBlocked(_ operationId: String, records before: Int, _ label: String, line: UInt = #line) {
            XCTAssertEqual(records, before, "\(label): nothing appended", line: line)
            XCTAssertTrue(journal.find(operationId: operationId).map(OperationJournal.isUnresolved) ?? false, "\(label): still unresolved", line: line)
            XCTAssertThrowsError(try journal.assertReady(), "\(label): writes stay blocked", line: line)
        }
    }

    static func run() {
        print("Running ProbeBarrierTests...")
        coverageTable()
        XCTAssertNoThrowBlock("covered tonal write") { try coveredTonalWrite() }
        XCTAssertNoThrowBlock("preview") { try previewNeedsRestart() }
        XCTAssertNoThrowBlock("mask feather") { try maskFeatherNeedsRestart() }
        XCTAssertNoThrowBlock("unpinned build") { try unpinnedBuildNeedsRestart() }
        XCTAssertNoThrowBlock("restart") { try restartReconciles() }
        XCTAssertNoThrowBlock("barrier timeout") { try barrierTimeoutLeavesBlock() }
        XCTAssertNoThrowBlock("clone") { try cloneObservedNotAdopted() }
    }

    static func coverageTable() {
        for type in ["set", "add", "reset", "metadata_set", "geometry_set", "geometry_restore", "clone", "baseline", "delete"] {
            XCTAssertTrue(OperationJournal.barrierCovers(operationType: type, nativeAction: nil), type)
        }
        XCTAssertTrue(OperationJournal.barrierCovers(operationType: "native", nativeAction: nil), "native property patch")
        for action in coveredActions {
            XCTAssertTrue(OperationJournal.barrierCovers(operationType: "native", nativeAction: action), action)
        }
        for action in uncoveredActions + ["unknown.action"] {
            XCTAssertFalse(OperationJournal.barrierCovers(operationType: "native", nativeAction: action), action)
        }
        for type in ["preview", "unknown-kind"] {
            XCTAssertFalse(OperationJournal.barrierCovers(operationType: type, nativeAction: nil), type)
        }
        XCTAssertEqual(Set(coveredActions + uncoveredActions), Set(NativeEditing.actions.keys),
                       "Every native action has a barrier decision; a new action needs its own qualification")
    }

    static func coveredTonalWrite() throws {
        let f = try Fixture()
        let before = try f.core.get(ref: f.editRef)
        let operationId = try f.uncertainTonal()
        XCTAssertEqual(f.journal.find(operationId: operationId)?.status, "outcome-unknown")
        XCTAssertThrowsError(try f.journal.assertReady())
        f.fake.values["1"]![0] = 2 // Capture One finishes the queued write after the caller timed out.
        let records = f.records, dispatches = f.fake.calls.filter { $0 == "applyAdjustments" }.count

        let reconciled = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(reconciled.status, "reconciled")
        XCTAssertEqual(reconciled.resolution, .probeBarrier)
        XCTAssertEqual(reconciled.afterAdjustments?.exposure, 2, "The observation is read after the barrier")
        XCTAssertTrue(reconciled.error?.contains("Read get again") ?? false, "Points to fresh tokens before the next write")
        XCTAssertEqual(f.records, records + 1, "One reconciliation record is appended")
        XCTAssertEqual(f.journal.find(operationId: operationId)?.resolution, .probeBarrier, "The resolution is journaled")
        XCTAssertEqual(f.fake.calls.filter { $0 == "applyAdjustments" }.count, dispatches, "Never retried")
        XCTAssertNoThrow(try f.journal.assertReady())

        // The document token is unchanged, so the reference stays valid; state tokens guard the next write.
        let fresh = try f.core.get(ref: f.editRef)
        XCTAssertThrowsError(try f.core.mutate(workingRefString: f.editRef, ifState: before.stateHash,
                                               setAdjustments: Adjustments(exposure: 1), addAdjustments: nil)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "state-changed")
        }
        XCTAssertNoThrow(try f.core.mutate(workingRefString: f.editRef, ifState: fresh.stateHash,
                                           setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
    }

    static func previewNeedsRestart() throws {
        let f = try Fixture()
        f.fake.fail = "processPreview"
        var operationId = ""
        do { _ = try f.core.preview(ref: f.editRef); XCTFail("Expected an injected timeout") }
        catch let failure as OperationFailure { operationId = failure.operationId }
        f.fake.fail = nil
        let records = f.records
        let status = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(status.status, "outcome-unknown", "Exports run outside the barrier")
        XCTAssertNil(status.resolution)
        f.assertStillBlocked(operationId, records: records, "preview")
    }

    static func maskFeatherNeedsRestart() throws {
        let f = try Fixture(native: true)
        let image = NativeTarget(), layer = NativeTarget(scope: "layer", layer: 1)
        let initial = try f.core.get(ref: f.editRef, nativeTargets: [image]).nativeSnapshots![0]
        _ = try f.core.nativeAction(workingRef: f.editRef, target: image, ifNativeState: initial.nativeStateHash,
                                    action: "layer.create", arguments: ["name": .text("mask"), "kind": .text("adjustment")])
        let token = try f.core.get(ref: f.editRef, nativeTargets: [layer]).nativeSnapshots![0].nativeStateHash
        f.fake.fail = "nativeAction"
        var operationId = ""
        do { _ = try f.core.nativeAction(workingRef: f.editRef, target: layer, ifNativeState: token, action: "mask.feather", arguments: ["amount": .number(10)]); XCTFail("Expected an injected timeout") }
        catch let failure as OperationFailure { operationId = failure.operationId }
        f.fake.fail = nil
        let records = f.records
        let status = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(status.status, "outcome-unknown", "Mask feather has no qualified barrier")
        f.assertStillBlocked(operationId, records: records, "mask.feather")

        f.fake.generation += "-restarted"
        let restarted = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(restarted.status, "reconciled")
        XCTAssertEqual(restarted.resolution, .restart)
    }

    static func unpinnedBuildNeedsRestart() throws {
        let f = try Fixture()
        let operationId = try f.uncertainTonal()
        f.fake.version = "16.8.4.1"
        let records = f.records
        let status = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(status.status, "outcome-unknown", "The barrier is qualified only on the pinned build")
        f.assertStillBlocked(operationId, records: records, "unpinned build")

        f.fake.version = SessionController.pinnedBuild
        let reconciled = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(reconciled.resolution, .probeBarrier)
    }

    static func restartReconciles() throws {
        let f = try Fixture()
        let operationId = try f.uncertainTonal()
        f.fake.values["1"]![0] = 2
        f.fake.generation += "-restarted"
        let records = f.records
        let reconciled = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(reconciled.status, "reconciled")
        XCTAssertEqual(reconciled.resolution, .restart)
        XCTAssertEqual(reconciled.afterAdjustments?.exposure, 2)
        XCTAssertTrue(reconciled.error?.hasPrefix("Previous app instance ended.") ?? false)
        XCTAssertEqual(f.records, records + 1)
        XCTAssertNoThrow(try f.journal.assertReady())
        XCTAssertThrowsError(try f.core.get(ref: f.editRef), "A restart invalidates old references")
    }

    static func barrierTimeoutLeavesBlock() throws {
        let f = try Fixture()
        let operationId = try f.uncertainTonal()
        let records = f.records
        f.fake.fail = "getAppAndDocInfo"
        XCTAssertThrowsError(try f.core.operationStatus(operationId: operationId)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "timeout")
        }
        f.fake.fail = nil
        XCTAssertEqual(f.journal.find(operationId: operationId)?.status, "outcome-unknown")
        f.assertStillBlocked(operationId, records: records, "barrier timeout")
    }

    static func cloneObservedNotAdopted() throws {
        let f = try Fixture()
        f.fake.fail = "cloneVariant"
        var operationId = ""
        do { _ = try f.core.cloneVariant(sourceRef: "1"); XCTFail("Expected an injected timeout") }
        catch let failure as OperationFailure { operationId = failure.operationId }
        f.fake.fail = nil
        f.fake.values["7"] = [0, 0, 0, 5000, 0] // The clone lands after the caller timed out.
        let clones = f.fake.calls.filter { $0 == "cloneVariant" }.count

        let reconciled = try f.core.operationStatus(operationId: operationId)
        XCTAssertEqual(reconciled.status, "reconciled")
        XCTAssertEqual(reconciled.resolution, .probeBarrier)
        XCTAssertEqual(reconciled.observedVariantIds, ["7"])
        XCTAssertNotNil(f.fake.values["7"], "The observed variant is not deleted")
        let adopted = try ProvenanceStore(sessionDirectory: f.directory).validatedRecords().values.contains { $0.cloneVariantId == "7" }
        XCTAssertFalse(adopted, "The observed variant is not adopted as a managed clone")
        XCTAssertEqual(f.fake.calls.filter { $0 == "cloneVariant" }.count, clones, "Never retried")
        XCTAssertNoThrow(try f.journal.assertReady())
    }
}
