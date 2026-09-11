import Foundation
import CaptureOneCore

final class GeometryFake: ScriptExecuting {
    let base: FakeScript
    var records: [String: [String: Any]] = [:]
    var failure: String?
    var changeDuringPreview = false
    var writeCount = 0
    var pendingBeforeWrite = false
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
        case "applyGeometry":
            writeCount += 1
            pendingBeforeWrite = OperationJournal(sessionDirectory: base.directory).unresolvedEntries().contains { $0.operationType == "geometry_set" }
            let id = args[1].stringValue!
            var r = record(id)
            if failure == "stale-dispatch" { throw C1Error.stateChanged("injected state change at handler") }
            if failure == "timeout" { throw C1Error.timeout("injected timeout") }
            r["rotationDegrees"] = args[6].doubleValue; records[id] = r
            if failure == "partial" { throw C1Error.scriptError("injected failure after rotation", code:-1700) }
            r["cropValues"] = (1...4).map { args[5].atIndex($0)!.doubleValue }
            if failure == "mismatch" { r["rotationDegrees"] = 22.0 }
            records[id] = r
            if failure == "lost-reply" { throw C1Error.timeout("applied, reply lost") }
            result = r
        default: return try base.executeAndDecode(handler:handler, args:args)
        }
        return try JSONDecoder().decode(T.self, from:JSONSerialization.data(withJSONObject:result))
    }
}

struct GeometryTests {
    static func run() {
        print("Running GeometryTests...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "geometry-db"})
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
}
