import Foundation
import CaptureOneCore

struct ExistingVariantTests {
    static func run() {
        print("Running ExistingVariantTests...")
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let image = directory.appendingPathComponent("dimensions.jpg")
        try! FakeScript.jpeg(width: 12, height: 8).write(to: image)
        XCTAssertEqual(ImageDimensions.read(image.path), [12, 8])
        XCTAssertEqual(ImageDimensions.read(directory.appendingPathComponent("missing.CR3").path), nil)
        let dimensionFake = GeometryFake(directory: directory)
        let noGeometry = SessionController(executor: dimensionFake, appInstance: { dimensionFake.base.generation }, databaseIdentity: { _ in "db-1" }, imageDimensions: { _ in nil })
        XCTAssertNoThrowBlock {
            let source = try noGeometry.get(ref: "1")
            XCTAssertEqual(source.geometry, nil)
            XCTAssertTrue(source.geometryUnavailableReason != nil)
            let document = try noGeometry.getDocumentInfo()
            let edit = try noGeometry.editVariant(sourceRef: "1", ifState: source.stateHash, ifDocument: document.openToken)
            XCTAssertEqual(edit.baselineGeometry, nil)
            _ = try noGeometry.mutate(workingRefString: edit.workingRef, ifState: source.stateHash, setAdjustments: Adjustments(exposure: 0.2), addAdjustments: nil)
            XCTAssertThrowsError(try noGeometry.geometrySet(workingRef: edit.workingRef, ifGeometryState: "missing", rotation: 2))
        }
        try! FileManager.default.removeItem(at: directory.appendingPathComponent(".c1"))
        let fake = GeometryFake(directory: directory)
        fake.dimensionsFollowRotation = true
        fake.base.values["1"] = [0.3, 5, 8, 5000, 2]
        var database = "db-1"
        let core = SessionController(executor: fake, appInstance: { fake.base.generation }, databaseIdentity: { _ in database }, imageDimensions: { _ in [6000, 4000] })
        let journal = OperationJournal(sessionDirectory: directory)
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo()
            let initial = try core.get(ref: "1")
            XCTAssertThrowsError(try core.editVariant(sourceRef: "1", ifState: initial.stateHash, ifDocument: "wrong"))
            XCTAssertThrowsError(try core.editVariant(sourceRef: "1", ifState: "stale", ifDocument: doc.openToken))
            XCTAssertThrowsError(try core.editVariant(sourceRef: "1", ifState: initial.stateHash, ifDocument: doc.openToken, ifGeometryState: "stale"))
            let edit = try core.editVariant(sourceRef: "1", ifState: initial.stateHash, ifDocument: doc.openToken, ifGeometryState: initial.geometryStateHash)
            let ref = edit.workingRef
            XCTAssertTrue(ref.hasPrefix("c1_edit_"))
            XCTAssertEqual(edit.variantId, "1")
            XCTAssertEqual(edit.baselineAdjustments, initial.adjustments)
            XCTAssertEqual(edit.baselineGeometry, initial.geometry)
            XCTAssertFalse(fake.base.calls.contains("cloneVariant"))
            XCTAssertEqual(fake.base.values.count, 1)
            let snapshots = try JSONDecoder().decode([String: EditingRecord].self, from: Data(contentsOf: directory.appendingPathComponent(".c1/editing.json")))
            XCTAssertEqual(snapshots[ref], edit, "Baseline exists before any native write")
            XCTAssertTrue(journal.loadEntries().isEmpty)
            let current = try core.get(ref: ref)
            XCTAssertEqual(current.id, initial.id)
            XCTAssertThrowsError(try core.deleteVariant(workingRefString: ref), "Editing permission never permits deleting the original")
            XCTAssertThrowsError(try core.mutate(workingRefString: "1", ifState: initial.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            let dry = try core.mutate(workingRefString: ref, ifState: initial.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil, isDryRun: true)
            XCTAssertTrue(dry.isDryRun)
            XCTAssertEqual(fake.base.values["1"]![0], 0.3)
            let edited = try core.mutate(workingRefString: ref, ifState: initial.stateHash,
                setAdjustments: Adjustments(exposure: 0.5, contrast: 9, saturation: 11, temperature: 5100, tint: 3), addAdjustments: nil)
            XCTAssertTrue(fake.base.preparedBeforeDispatch)
            XCTAssertEqual(fake.base.values["1"]!, [0.5, 9, 11, 5100, 3])
            XCTAssertThrowsError(try core.mutate(workingRefString: ref, ifState: initial.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            let added = try core.mutate(workingRefString: ref, ifState: edited.stateHash, setAdjustments: nil, addAdjustments: Adjustments(exposure: 0.25))
            XCTAssertEqual(fake.base.values["1"]![0], 0.75)
            _ = try core.reset(workingRefString: ref, ifState: added.stateHash)
            XCTAssertEqual(fake.base.values["1"]!, [0, 0, 0, 5000, 2], "Reset preserves its existing baseline WB semantics")
            let tonal = try core.get(ref: ref)
            let crop = try core.geometrySet(workingRef: ref, ifGeometryState: tonal.geometryStateHash!, rotation: 2, aspectRatio: 0.75)
            XCTAssertTrue(fake.pendingBeforeWrite)
            XCTAssertEqual(crop.after.imageWidth, 6000, "Intrinsic dimensions stay stable when the native first-variant canvas rotates")
            XCTAssertEqual(fake.base.values.count, 1)
            XCTAssertThrowsError(try core.geometryRestore(workingRef: ref, ifGeometryState: tonal.geometryStateHash!))
            let preview = try core.preview(ref: ref)
            XCTAssertEqual(preview.nativeVariantId, "1")
            XCTAssertEqual(preview.workingRef, ref)
            let diff = try core.diff(ref1: ref)
            XCTAssertEqual(diff.geometryBefore, initial.geometry)
            XCTAssertEqual(diff.geometryAfter, crop.after)
            let restored = try core.geometryRestore(workingRef: ref, ifGeometryState: crop.geometryStateHash)
            XCTAssertTrue(restored.after.matchesTarget(initial.geometry!))
            let afterRestore = try core.get(ref: ref)
            XCTAssertEqual(afterRestore.stateHash, tonal.stateHash, "Geometry restore does not overwrite subsequent tone edits")
            let restoreOperation = journal.find(operationId: restored.operationId)!
            XCTAssertEqual(restoreOperation.operationType, "geometry_restore")
            XCTAssertEqual(restoreOperation.nativeVariantId, "1")
            XCTAssertEqual(restoreOperation.beforeGeometry, crop.after)
            XCTAssertEqual(restoreOperation.afterGeometry, restored.after)
            fake.base.parentOverride = "/different.CR3"
            XCTAssertThrowsError(try core.get(ref: ref))
            fake.base.parentOverride = nil
            database = "db-2"
            XCTAssertThrowsError(try core.get(ref: ref))
            database = "db-1"
            var changed = fake.record("1"); changed["orientationDegrees"] = 90
            fake.records["1"] = changed
            let newContext = try core.get(ref: ref)
            XCTAssertThrowsError(try core.geometryRestore(workingRef: ref, ifGeometryState: newContext.geometryStateHash!))
            changed["orientationDegrees"] = 0; fake.records["1"] = changed

            // A lost reply may already have changed the existing variant. Block and
            // observe after restart, never recreate a variant or blindly retry.
            let beforeFault = try core.get(ref: ref)
            fake.failure = "lost-reply"
            var operation = ""
            do { _ = try core.geometrySet(workingRef: ref, ifGeometryState: beforeFault.geometryStateHash!, rotation: 3, aspectRatio: 1.5) }
            catch let failure as OperationFailure { operation = failure.operationId }
            XCTAssertFalse(operation.isEmpty)
            let fault = journal.find(operationId: operation)!
            XCTAssertEqual(fault.beforeGeometry, beforeFault.geometry)
            XCTAssertEqual(fault.nativeVariantId, "1")
            XCTAssertThrowsError(try core.editVariant(sourceRef: "1", ifState: beforeFault.stateHash, ifDocument: doc.openToken))
            XCTAssertThrowsError(try core.geometryRestore(workingRef: ref, ifGeometryState: beforeFault.geometryStateHash!))
            fake.failure = nil
            fake.base.generation = "app-2"
            let recovery = try core.operationStatus(operationId: operation)
            XCTAssertEqual(recovery.status, "reconciled")
            XCTAssertThrowsError(try core.get(ref: ref))
            XCTAssertEqual(fake.base.values.count, 1)
            XCTAssertFalse(fake.base.calls.contains("cloneVariant"))
            XCTAssertFalse(fake.base.calls.contains("deleteVariant"))
            // The baseline remains readable evidence after references expire.
            let retained = try JSONDecoder().decode([String: EditingRecord].self, from: Data(contentsOf: directory.appendingPathComponent(".c1/editing.json")))
            XCTAssertEqual(retained[ref], edit)
            let nextDoc = try core.getDocumentInfo(), next = try core.get(ref: "1")
            try Data("corrupt".utf8).write(to: directory.appendingPathComponent(".c1/editing.json"))
            XCTAssertThrowsError(try core.editVariant(sourceRef: "1", ifState: next.stateHash, ifDocument: nextDoc.openToken))
        }
    }
}
