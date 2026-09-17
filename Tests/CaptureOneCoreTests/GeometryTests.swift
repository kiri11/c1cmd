import Foundation
import CaptureOneCore

final class GeometryFake: ScriptExecuting {
    let base: FakeScript
    var records: [String: [String: Any]] = [:]
    var failure: String?
    var changeDuringPreview = false
    var writeCount = 0
    var dimensionsFollowRotation = false
    var pendingBeforeWrite = false
    var requestedBeforeWrite: GeometryRequest?
    var normalizePerspective = false
    init(directory: URL) { base = FakeScript(directory: directory) }
    func record(_ id: String) -> [String: Any] {
        records[id] ?? ["cropValues":[3000.0,2000,6000,4000], "rotationDegrees":0.0, "orientationDegrees":0,
            "sourceDimensions":[6000.0,4000], "maximumValues":[3000.0,2000,6000,4000], "flipName":"none", "ratioName":"",
            "keystoneValues":[100.0,0,0,0,0], "lensValues":[0.0,35,0,0,0,0,0,0], "profileName":"fixture", "hiddenAreas":true, "outsideAllowed":false]
    }
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        var result: Any
        switch handler {
        case "getAdjustmentsBatch":
            let id = args[1].atIndex(1)!.stringValue!
            guard base.values[id] != nil else { throw C1Error.variantNotFound("missing") }
            var item = base.item(id); item["geometryRecord"] = record(id); result = [item]
        case "cloneVariant":
            let cloned: CloneVariantResult = try base.executeAndDecode(handler:handler, args:args)
            records[cloned.cloneId] = record(args[1].stringValue!)
            result = ["cloneId":cloned.cloneId]
        case "processPreview":
            let id = args[1].stringValue!
            let r = record(id), crop = r["cropValues"] as! [Double]
            let url = URL(fileURLWithPath:args[3].stringValue!).appendingPathComponent(args[4].stringValue!).appendingPathComponent("preview.jpg")
            try FakeScript.jpeg(width:120, height:Int((120*crop[3]/crop[2]).rounded())).write(to:url)
            if changeDuringPreview { var changed = r; changed["rotationDegrees"] = 1.0; records[id] = changed }
            result = ["jobId":"geometry-job"]
        case "applyGeometry", "applyCorrectedGeometry":
            writeCount += 1
            pendingBeforeWrite = OperationJournal(sessionDirectory: base.directory).unresolvedEntries().contains { $0.operationType == "geometry_set" }
            requestedBeforeWrite = OperationJournal(sessionDirectory: base.directory).unresolvedEntries().last?.requestedGeometry
            let id = args[1].stringValue!
            var r = record(id)
            if failure == "stale-dispatch" { throw C1Error.stateChanged("injected state change at handler") }
            if failure == "timeout" { throw C1Error.timeout("injected timeout") }
            let keyIndex = handler == "applyCorrectedGeometry" ? 8 : 7
            r["keystoneValues"] = (1...5).map { args[keyIndex].atIndex($0)!.doubleValue }
            if failure == "keystone-partial" { records[id] = r; throw C1Error.scriptError("injected failure after keystone", code:-1700) }
            r["rotationDegrees"] = args[6].doubleValue; records[id] = r
            if failure == "partial" { throw C1Error.scriptError("injected failure after rotation", code:-1700) }
            var target: [Double]
            let bounds = [3150.0,2300,5000,3400] // Native corrected canvas deliberately differs from RAW math.
            if handler == "applyCorrectedGeometry" {
                if args[5].descriptorType != NSAppleEventDescriptor.missingValue().descriptorType {
                    target = (1...4).map { args[5].atIndex($0)!.doubleValue }
                } else if args[7].descriptorType != NSAppleEventDescriptor.missingValue().descriptorType {
                    let ratio = args[7].doubleValue, w = floor(min(bounds[2], bounds[3]*args[7].doubleValue))
                    target = [bounds[0], bounds[1], w, floor(w/ratio)]
                } else { target = [3150,2300,2400,1600] }
                r["maximumValues"] = bounds
            } else { target = (1...4).map { args[5].atIndex($0)!.doubleValue } }
            var fitted = target
            if normalizePerspective && handler == "applyCorrectedGeometry" {
                fitted[2] *= 0.8; fitted[3] *= 0.8
            }
            if failure == "fit-ratio" { fitted[2] *= 0.7 }
            if failure == "fit-outside" { fitted[0] += 10000 }
            r["cropValues"] = fitted
            if dimensionsFollowRotation { r["sourceDimensions"] = args[6].doubleValue == 0 ? [6000.0, 4000] : [6135.0, 4206] }
            if failure == "keystone-mismatch" { r["keystoneValues"] = [100.0,99,0,0,0] }
            if failure == "mismatch" { r["rotationDegrees"] = 22.0 }
            if failure == "lens-change" { r["lensValues"] = [0.0,35,0,0,0,0,0,0] }
            records[id] = r
            if failure == "lost-reply" { throw C1Error.timeout("applied, reply lost") }
            result = handler == "applyCorrectedGeometry" ? ["targetCropValues":target, "fittedCropValues":fitted, "boundsValues": failure == "bad-bounds" ? [0.0,0,1,1] : bounds] : r
        default: return try base.executeAndDecode(handler:handler, args:args)
        }
        return try JSONDecoder().decode(T.self, from:JSONSerialization.data(withJSONObject:result))
    }
}

struct GeometryTests {
    static func run() {
        print("Running GeometryTests...")
        testCorrectedLens()
        testKeystone()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "geometry-db"}, imageDimensions: { _ in [6000, 4000] })
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let cloned = try core.cloneVariant(sourceRef:"1")
            let initial = try core.get(ref:cloned.workingRef)
            let g = initial.geometry!
            XCTAssertTrue(initial.geometryStateHash!.hasPrefix("geometry-v1:"))
            let record = try ProvenanceStore(sessionDirectory:directory).validatedRecords()[cloned.workingRef]!
            XCTAssertEqual(record.baselineGeometry, g)
            for bad in [Double.nan, Double.infinity, -46, 46] {
                XCTAssertThrowsError(try core.geometrySet(workingRef:cloned.workingRef, ifGeometryState:initial.geometryStateHash!, rotation:bad))
            }
            XCTAssertThrowsError(try core.geometrySet(workingRef:"1", ifGeometryState:initial.geometryStateHash!, rotation:1))
            XCTAssertThrowsError(try core.geometrySet(workingRef:cloned.workingRef, ifGeometryState:"stale", rotation:1))
            XCTAssertThrowsError(try g.target(crop:CropRect(centerX:1,centerY:1,width:1000,height:1000), rotation:5, aspectRatio:nil))
            XCTAssertThrowsError(try g.target(crop:nil,rotation:nil,aspectRatio:0))
            XCTAssertThrowsError(try g.target(crop:g.crop,rotation:nil,aspectRatio:1.5))
            var unsupported = g; unsupported.keystone[1] = 1
            XCTAssertThrowsError(try unsupported.target(crop:nil,rotation:2,aspectRatio:1.5))
            unsupported = g; unsupported.flip = "horizontal"
            XCTAssertNotNil(unsupported.unsupportedReason)
            for orientation in [0,90,180,270] {
                var oriented = g; oriented.orientation = orientation
                for angle in [-10.0,0,10] {
                    for ratio in [1.5,0.75] {
                        let target = try oriented.target(crop:nil,rotation:angle,aspectRatio:ratio)
                        XCTAssertEqual(target.crop.aspectRatio,ratio,accuracy:0.001)
                        XCTAssertTrue(target.crop.width > 0 && target.crop.height > 0)
                    }
                }
            }
            let dry = try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:initial.geometryStateHash!,rotation:5,aspectRatio:1.5,dryRun:true)
            XCTAssertTrue(dry.isDryRun); XCTAssertEqual(fake.writeCount,0)
            let result = try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:initial.geometryStateHash!,rotation:5,aspectRatio:1.5)
            XCTAssertTrue(fake.pendingBeforeWrite)
            XCTAssertEqual(result.after.rotation,5)
            XCTAssertEqual(result.after.crop.aspectRatio,1.5,accuracy:0.001)
            let after = try core.get(ref:cloned.workingRef)
            XCTAssertEqual(initial.stateHash,after.stateHash,"Legacy tonal hash unchanged")
            XCTAssertNotEqual(initial.geometryStateHash,after.geometryStateHash)
            let original = try core.get(ref:"1")
            XCTAssertEqual(original.geometry,g,"Original geometry unchanged")
            XCTAssertEqual(journal.find(operationId:result.operationId)?.afterGeometry,result.after)
            let difference = try core.diff(ref1:cloned.workingRef)
            XCTAssertEqual(difference.geometryBefore,g)
            XCTAssertNotNil(difference.geometryDiff?["rotation"])
            XCTAssertThrowsError(try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:initial.geometryStateHash!,rotation:0))
            let restored = try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:after.geometryStateHash!,crop:g.crop,rotation:g.rotation)
            XCTAssertEqual(restored.after,g)
            fake.base.isSession = false
            XCTAssertThrowsError(try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:restored.geometryStateHash,rotation:1))
            fake.base.isSession = true
            let countBeforeContext = fake.base.values.count
            let context = try core.preview(ref:cloned.workingRef,fullFrame:true)
            XCTAssertEqual(context.contextSourceRef,cloned.workingRef)
            XCTAssertEqual(fake.base.values.count,countBeforeContext)
            XCTAssertNotNil(context.geometryStateHash)
            fake.changeDuringPreview = true
            var previewOp: String?
            do { _ = try core.preview(ref:cloned.workingRef); XCTFail("Geometry changes during rendering must fail") }
            catch let e as OperationFailure { previewOp = e.operationId }
            XCTAssertNotNil(previewOp)
            XCTAssertNotNil(journal.find(operationId:previewOp!)?.beforeGeometry)
            fake.changeDuringPreview = false; fake.base.generation = "app-preview-restarted"
            let previewRecovery = try core.operationStatus(operationId:previewOp!)
            XCTAssertNotNil(previewRecovery.afterGeometry)
            let restartClone = try core.cloneVariant(sourceRef:"1")
            var faultRef = restartClone.workingRef
            for failure in ["stale-dispatch","timeout","partial","lost-reply","mismatch"] {
                fake.failure = failure
                let fresh = try core.get(ref:faultRef)
                var op: String?
                do { _ = try core.geometrySet(workingRef:faultRef,ifGeometryState:fresh.geometryStateHash!,rotation:5,aspectRatio:0.75); XCTFail("Expected injected failure") }
                catch let e as OperationFailure { op = e.operationId }
                XCTAssertNotNil(op)
                XCTAssertEqual(journal.unresolvedEntries().count,1)
                XCTAssertThrowsError(try core.geometrySet(workingRef:faultRef,ifGeometryState:fresh.geometryStateHash!,rotation:0))
                let pending = try core.operationStatus(operationId:op!)
                XCTAssertTrue(OperationJournal.isUnresolved(pending))
                fake.failure = nil; fake.base.generation += "-restart"
                let recovered = try core.operationStatus(operationId:op!)
                XCTAssertEqual(recovered.status,"reconciled")
                XCTAssertNotNil(recovered.afterGeometry)
                XCTAssertThrowsError(try core.get(ref:faultRef))
                // Continue with a freshly bound reference after each simulated restart.
                let next = try core.cloneVariant(sourceRef:"1")
                faultRef = next.workingRef
            }
        }
    }

    private static func testKeystone() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "keystone-db"}, imageDimensions:{_ in [6000,4000]})
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let source = try core.get(ref:"1"), doc = try core.getDocumentInfo()
            let edit = try core.editVariant(sourceRef:"1",ifState:source.stateHash,ifDocument:doc.openToken)
            let ref = edit.workingRef, token = source.geometryStateHash!
            for invalid in [KeystoneAdjustments(), KeystoneAdjustments(amount:9), KeystoneAdjustments(amount:121), KeystoneAdjustments(amount:50.5), KeystoneAdjustments(vertical:76), KeystoneAdjustments(horizontal:-76), KeystoneAdjustments(horizontal:Double.nan), KeystoneAdjustments(skew:Double.infinity), KeystoneAdjustments(aspect:-51)] {
                XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,keystone:invalid))
            }
            XCTAssertThrowsError(try core.geometrySet(workingRef:"1",ifGeometryState:token,keystone:KeystoneAdjustments(vertical:10)))
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:"stale",keystone:KeystoneAdjustments(vertical:10)))
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,keystone:KeystoneAdjustments(vertical:10),dryRun:true))
            XCTAssertEqual(fake.writeCount,0)
            fake.normalizePerspective = true
            let patch = KeystoneAdjustments(amount:80,vertical:12.5,horizontal:-8,skew:3,aspect:10)
            let applied = try core.geometrySet(workingRef:ref,ifGeometryState:token,rotation:2,aspectRatio:1.5,keystone:patch)
            XCTAssertEqual(applied.after.keystone,[80,12.5,-8,3,10])
            XCTAssertEqual(applied.after.crop.width,4000)
            XCTAssertEqual(applied.after.crop.aspectRatio,1.5,accuracy:0.001)
            XCTAssertEqual(fake.requestedBeforeWrite?.keystone,patch)
            XCTAssertTrue(fake.pendingBeforeWrite)
            XCTAssertEqual(fake.base.values.count,1)
            let after = try core.get(ref:ref)
            XCTAssertEqual(after.stateHash,source.stateHash)
            XCTAssertEqual(journal.find(operationId:applied.operationId)?.intendedGeometry?.keystone,applied.after.keystone)
            let diff = try core.diff(ref1:ref)
            XCTAssertNotNil(diff.geometryDiff?["keystone.vertical"])
            fake.normalizePerspective = false
            let partial = try core.geometrySet(workingRef:ref,ifGeometryState:applied.geometryStateHash,keystone:KeystoneAdjustments(vertical:0))
            XCTAssertEqual(partial.after.keystone,[80,0,-8,3,10])
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:applied.geometryStateHash,keystone:patch))
            let dry = try core.geometryRestore(workingRef:ref,ifGeometryState:partial.geometryStateHash,dryRun:true)
            XCTAssertEqual(dry.after.keystone,source.geometry!.keystone)
            let restored = try core.geometryRestore(workingRef:ref,ifGeometryState:partial.geometryStateHash)
            XCTAssertEqual(restored.after.keystone,source.geometry!.keystone)
            XCTAssertEqual(restored.after.crop,source.geometry!.crop)
            XCTAssertEqual(restored.after.rotation,source.geometry!.rotation)
            for failure in ["keystone-partial", "keystone-mismatch", "lost-reply"] {
                let fresh = try core.get(ref:"1")
                let prepared = try core.editVariant(sourceRef:"1",ifState:fresh.stateHash,ifDocument:try core.getDocumentInfo().openToken)
                fake.failure = failure
                var operation = ""
                do { _ = try core.geometrySet(workingRef:prepared.workingRef,ifGeometryState:fresh.geometryStateHash!,keystone:patch); XCTFail("Expected keystone failure") }
                catch let error as OperationFailure { operation = error.operationId }
                XCTAssertFalse(operation.isEmpty)
                XCTAssertEqual(journal.find(operationId:operation)?.requestedGeometry?.keystone,patch)
                XCTAssertThrowsError(try core.geometryRestore(workingRef:prepared.workingRef,ifGeometryState:fresh.geometryStateHash!))
                fake.failure = nil; fake.base.generation += "-restart"
                let recovered = try core.operationStatus(operationId:operation)
                XCTAssertEqual(recovered.status,"reconciled")
                XCTAssertThrowsError(try core.get(ref:prepared.workingRef))
            }
        }
    }

    private static func testCorrectedLens() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        var source = fake.record("1")
        source["lensValues"] = [100.0,35,0,0,0,0,0,0]
        source["maximumValues"] = [3002.0,2000,6000,4000]
        fake.records["1"] = source
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "corrected-db"}, imageDimensions:{_ in [6000,4000]})
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), original = try core.get(ref:"1")
            XCTAssertNil(original.geometryUnavailableReason)
            XCTAssertEqual(original.geometryUsableBounds,original.geometry!.maximumCrop)
            let edit = try core.editVariant(sourceRef:"1",ifState:original.stateHash,ifDocument:doc.openToken,ifGeometryState:original.geometryStateHash)
            let ref = edit.workingRef
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:original.geometryStateHash!,rotation:5,aspectRatio:0.75,dryRun:true))
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:original.geometryStateHash!,crop:CropRect(centerX:0,centerY:0,width:1000,height:1000)))
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:original.geometryStateHash!,rotation:5,aspectRatio:Double.nan))
            XCTAssertEqual(fake.writeCount,0,"Invalid requests and unknown dry-run bounds cannot dispatch")
            let result = try core.geometrySet(workingRef:ref,ifGeometryState:original.geometryStateHash!,rotation:5,aspectRatio:0.75)
            XCTAssertEqual(result.after.crop,CropRect(centerX:3150,centerY:2300,width:2550,height:3400),"Fit the native corrected canvas, not intrinsic RAW bounds")
            XCTAssertEqual(fake.requestedBeforeWrite?.rotation,5)
            XCTAssertEqual(fake.requestedBeforeWrite?.aspectRatio,0.75)
            XCTAssertTrue(fake.pendingBeforeWrite)
            XCTAssertEqual(result.before.lensGeometry,result.after.lensGeometry)
            XCTAssertEqual(fake.base.values.count,1,"Existing corrected-lens edit creates no duplicate")
            let record = journal.find(operationId:result.operationId)!
            XCTAssertNotNil(record.requestedGeometry)
            XCTAssertEqual(record.intendedGeometry?.crop,result.after.crop)
            XCTAssertEqual(record.status,"succeeded")
            let restored = try core.geometryRestore(workingRef:ref,ifGeometryState:result.geometryStateHash)
            XCTAssertEqual(restored.after.crop,original.geometry!.crop)
            XCTAssertEqual(restored.after.rotation,original.geometry!.rotation)
            XCTAssertEqual(restored.after.lensGeometry,original.geometry!.lensGeometry)
            for index in 2...7 {
                var blocked = original.geometry!; blocked.lensGeometry[index] = 1
                XCTAssertNil(blocked.unsupportedReason)
                XCTAssertTrue(blocked.requiresNativeBounds)
            }
            for index in 1...4 {
                var corrected = original.geometry!; corrected.lensGeometry[0] = 0; corrected.keystone[index] = 10
                XCTAssertNil(corrected.unsupportedReason)
                XCTAssertTrue(corrected.requiresNativeBounds)
                let nativeBounds = try corrected.safeBounds(rotation:corrected.rotation)
                XCTAssertEqual(nativeBounds,corrected.maximumCrop)
                XCTAssertThrowsError(try corrected.safeBounds(rotation:5))
            }
            for amount in [-1.0,101,Double.nan] {
                var blocked = original.geometry!; blocked.lensGeometry[0] = amount
                XCTAssertNotNil(blocked.unsupportedReason)
            }
            var invalid = original.geometry!; invalid.maximumCrop.width = 0
            XCTAssertNotNil(invalid.unsupportedReason)
            for field in ["keystoneValues", "lensValues"] {
                let indices = field == "keystoneValues" ? Array(1...4) : Array(2...7)
                for index in indices {
                    var context = fake.record("1")
                    context["lensValues"] = [0.0,35,0,0,0,0,0,0]
                    var values = context[field] as! [Double]; values[index] = 1; context[field] = values
                    fake.records["1"] = context
                    let fresh = try core.get(ref:"1")
                    let prepared = try core.editVariant(sourceRef:"1",ifState:fresh.stateHash,ifDocument:doc.openToken)
                    fake.normalizePerspective = true
                    let changed = try core.geometrySet(workingRef:prepared.workingRef,ifGeometryState:fresh.geometryStateHash!,rotation:3,aspectRatio:1.5)
                    XCTAssertNotNil(journal.find(operationId:changed.operationId)?.requestedGeometry)
                    XCTAssertTrue(changed.before.sameContext(as:changed.after))
                    XCTAssertEqual(changed.after.crop.width,4000)
                    XCTAssertThrowsError(try core.geometrySet(workingRef:prepared.workingRef,ifGeometryState:changed.geometryStateHash,aspectRatio:1.5,dryRun:true))
                }
            }
            fake.normalizePerspective = false
            fake.records["1"] = source
            for failure in ["partial","lost-reply","lens-change","bad-bounds","fit-ratio","fit-outside"] {
                if failure.hasPrefix("fit-") {
                    var record = source; record["keystoneValues"] = [100.0,15,0,0,0]; fake.records["1"] = record
                }
                let fresh = try core.get(ref:"1")
                let freshEdit = try core.editVariant(sourceRef:"1",ifState:fresh.stateHash,ifDocument:try core.getDocumentInfo().openToken,ifGeometryState:fresh.geometryStateHash)
                fake.failure = failure
                var operation = ""
                do { _ = try core.geometrySet(workingRef:freshEdit.workingRef,ifGeometryState:fresh.geometryStateHash!,rotation:-5,aspectRatio:1.5); XCTFail("Expected corrected-lens failure") }
                catch let error as OperationFailure { operation = error.operationId }
                XCTAssertFalse(operation.isEmpty)
                XCTAssertNotNil(journal.find(operationId:operation)?.requestedGeometry)
                XCTAssertThrowsError(try core.geometrySet(workingRef:freshEdit.workingRef,ifGeometryState:fresh.geometryStateHash!,rotation:0))
                fake.failure = nil; fake.base.generation += "-restart"
                let recovered = try core.operationStatus(operationId:operation)
                XCTAssertEqual(recovered.status,"reconciled")
                XCTAssertThrowsError(try core.get(ref:freshEdit.workingRef))
                fake.records["1"] = source
            }
        }
    }
}
