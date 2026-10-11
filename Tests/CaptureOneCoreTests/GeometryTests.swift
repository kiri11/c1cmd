import Foundation
import CaptureOneCore

final class GeometryFake: ScriptExecuting {
    let base: FakeScript
    var records: [String: [String: Any]] = [:]
    var failure: String?
    var changeDuringPreview = false
    /// Capture One accepting an export whose JPEG lands only when `landHeldPreview` writes it.
    var holdPreview = false
    var heldPreview: (recipe: String, file: URL, aspect: Double)?
    var writeCount = 0
    var dimensionsFollowRotation = false
    var pendingBeforeWrite = false
    var requestedBeforeWrite: GeometryRequest?
    var normalizePerspective = false
    /// Capture One's automatic crop after a transform-only request.
    var automaticCrop: [Double] = [3150,2300,2400,1600]
    /// The orientation the last geometry handler was asked for.
    var lastOrientation: Int?
    init(directory: URL) { base = FakeScript(directory: directory) }
    init(base: FakeScript) { self.base = base }
    func record(_ id: String) -> [String: Any] {
        records[id] ?? ["cropValues":[3000.0,2000,6000,4000], "rotationDegrees":0.0, "orientationDegrees":0,
            "sourceDimensions":[6000.0,4000], "maximumValues":[3000.0,2000,6000,4000], "flipName":"none", "ratioName":"",
            "keystoneValues":[100.0,0,0,0,0], "lensValues":[0.0,35,0,0,0,0,0,0], "profileName":"fixture", "hiddenAreas":true, "outsideAllowed":false]
    }
    /// Writes the held export, by default at the crop's aspect and the recipe's long edge.
    func landHeldPreview(aspect: Double? = nil) throws {
        let held = heldPreview!
        try base.previewJPEG(recipe:held.recipe, aspect:aspect ?? held.aspect).write(to:held.file)
    }
    /// Every Apple Event the fake received, in order.
    var handlers: [String] = []
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        handlers.append(handler)
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
            if holdPreview { heldPreview = (args[2].stringValue!, url, crop[2]/crop[3]) }
            else { try base.previewJPEG(recipe:args[2].stringValue!, aspect:crop[2]/crop[3]).write(to:url) }
            if changeDuringPreview { var changed = r; changed["rotationDegrees"] = 1.0; records[id] = changed }
            result = ["jobId":"geometry-job"]
        case "applyGeometry", "applyCorrectedGeometry":
            try base.intercept(handler)
            writeCount += 1
            pendingBeforeWrite = OperationJournal(sessionDirectory: base.directory).unresolvedEntries().contains { $0.operationType == "geometry_set" }
            requestedBeforeWrite = OperationJournal(sessionDirectory: base.directory).unresolvedEntries().last?.requestedGeometry
            let id = args[1].stringValue!
            var r = record(id)
            if failure == "stale-dispatch" { throw C1Error.stateChanged("injected state change at handler") }
            // Capture One turns the stored crop with the canvas; centred crops swap their axes.
            let requestedOrientation = Int(args[handler == "applyCorrectedGeometry" ? 9 : 8].int32Value)
            lastOrientation = requestedOrientation
            let turned = (requestedOrientation - (r["orientationDegrees"] as! Int) + 360) % 180 == 90 && failure != "ignore-orientation"
            if failure != "ignore-orientation" { r["orientationDegrees"] = requestedOrientation }
            if turned { let c = r["cropValues"] as! [Double]; r["cropValues"] = [c[1], c[0], c[3], c[2]] }
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
                } else { target = turned ? r["cropValues"] as! [Double] : automaticCrop }
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
            if failure == "mismatch" || base.misapply { r["rotationDegrees"] = 22.0 }
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
        testContainmentTable()
        testRotationOnly()
        testOrientation()
        testCorrectedLens()
        testKeystone()
        testAnchorMaths()
        testAnchoredWrites()
        testFullFrameRectangles()
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
            // A readable stored crop is not proof that an explicit rewrite is contained.
            var offCenter = g
            offCenter.lensGeometry[0] = 100
            offCenter.maximumCrop = CropRect(centerX:3000,centerY:2000,width:5000,height:3400)
            offCenter.crop = CropRect(centerX:3400,centerY:2200,width:5400,height:3600)
            XCTAssertTrue(offCenter.unsupportedReason == nil)
            XCTAssertThrowsError(try offCenter.target(crop:offCenter.crop,rotation:nil,aspectRatio:nil))
            let fit = try offCenter.target(crop:nil,rotation:nil,aspectRatio:offCenter.crop.aspectRatio)
            XCTAssertEqual(fit.lensGeometry,offCenter.lensGeometry)
            XCTAssertTrue(fit.crop != offCenter.crop)
            var fractional = offCenter
            fractional.maximumCrop = CropRect(centerX:3000.1,centerY:2000.3,width:5000.1,height:3400.7)
            let singleton = CropRect(centerX:3000.1,centerY:2000.3,width:5004.1,height:3404.7)
            XCTAssertNoThrowBlock { _ = try fractional.target(crop:singleton,rotation:nil,aspectRatio:nil) }
            var emptyInterval = singleton
            emptyInterval.width += 0.000001
            XCTAssertThrowsError(try fractional.target(crop:emptyInterval,rotation:nil,aspectRatio:nil))
            emptyInterval = singleton
            emptyInterval.height += 0.000001
            XCTAssertThrowsError(try fractional.target(crop:emptyInterval,rotation:nil,aspectRatio:nil))
            // Test both center intervals at the existing two-pixel tolerance.
            // Use a clear subpixel step as well as adjacent representable values.
            for axis in [0, 1] {
                for side in [-1.0, 1.0] {
                    let boundary = (axis == 0 ? 3000.0 : 2000.0) + side * 2
                    func candidate(_ center: Double) -> CropRect {
                        CropRect(centerX:axis == 0 ? center : 3000,
                                 centerY:axis == 1 ? center : 2000,width:6000,height:4000)
                    }
                    XCTAssertNoThrowBlock { _ = try g.target(crop:candidate(boundary),rotation:nil,aspectRatio:nil) }
                    XCTAssertNoThrowBlock { _ = try g.target(crop:candidate(boundary-side*0.000001),rotation:nil,aspectRatio:nil) }
                    XCTAssertThrowsError(try g.target(crop:candidate(boundary+side*0.000001),rotation:nil,aspectRatio:nil))
                    let adjacent = side < 0 ? boundary.nextDown : boundary.nextUp
                    XCTAssertThrowsError(try g.target(crop:candidate(adjacent),rotation:nil,aspectRatio:nil))
                }
            }
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

    /// Shared with Tests/contained_crop_test.py, so c1 and the planner apply one test.
    private static func testContainmentTable() {
        struct Case: Decodable {
            let name: String, rotation: Double, canvas: [String: Double], crop: CropRect, exposed: [Int], distances: [Double]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/crop-containment.json")
        let cases = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertTrue(cases.count >= 10)
        let order: [(Double, Double)] = [(-1,-1), (1,-1), (1,1), (-1,1)]
        for item in cases {
            let exposed = CropContainment.exposedCorners(of: item.crop, rotation: item.rotation, width: item.canvas["width"]!, height: item.canvas["height"]!)
            let indices = order.indices.filter { index in exposed.contains {
                abs($0.x - (item.crop.centerX + order[index].0*item.crop.width/2)) < 1e-9 && abs($0.y - (item.crop.centerY + order[index].1*item.crop.height/2)) < 1e-9 } }
            XCTAssertEqual(indices, item.exposed, item.name)
            XCTAssertEqual(exposed.map { ($0.distance*1000).rounded()/1000 }, item.distances, item.name)
            // Uncorrected validation accepts exactly the contained crops at the requested rotation.
            let portrait = item.canvas["width"]! < item.canvas["height"]!
            var geometry = Geometry.fixture(width: item.canvas["width"]!, height: item.canvas["height"]!)
            if portrait { geometry.orientation = 90; (geometry.imageWidth, geometry.imageHeight) = (geometry.imageHeight, geometry.imageWidth) }
            let accepted = (try? geometry.target(crop: item.crop, rotation: item.rotation, aspectRatio: nil)) != nil
            XCTAssertEqual(accepted, item.exposed.isEmpty, item.name)
        }
        var corrected = Geometry.fixture(width: 6000, height: 4000); corrected.lensGeometry[0] = 50
        XCTAssertEqual(corrected.exposedCorners(of: CropRect(centerX: 0, centerY: 0, width: 9000, height: 9000), rotation: 0), [])
    }

    private static func testRotationOnly() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "rotation-db"}, imageDimensions:{_ in [6000,4000]})
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let source = try core.get(ref:"1"), doc = try core.getDocumentInfo()
            let ref = try core.editVariant(sourceRef:"1",ifState:source.stateHash,ifDocument:doc.openToken).workingRef
            // The stored full-frame crop cannot be validated at the new rotation; Capture One's crop is kept.
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:source.geometryStateHash!,rotation:5,dryRun:true))
            XCTAssertEqual(fake.writeCount,0)
            let rotated = try core.geometrySet(workingRef:ref,ifGeometryState:source.geometryStateHash!,rotation:5)
            XCTAssertEqual(rotated.after.rotation,5)
            XCTAssertEqual(rotated.after.crop,CropRect(centerX:3150,centerY:2300,width:2400,height:1600))
            XCTAssertNil(rotated.exposedCorners)
            XCTAssertTrue(fake.pendingBeforeWrite)
            let record = journal.find(operationId:rotated.operationId)!
            XCTAssertEqual(record.requestedGeometry?.rotation,5)
            XCTAssertNil(record.requestedGeometry?.crop)
            XCTAssertEqual(record.intendedGeometry?.crop,rotated.after.crop)
            XCTAssertEqual(record.status,"succeeded")
            // An automatic crop exposing a corner is reported, not accepted silently.
            fake.automaticCrop = [3163,2254,6000,4000]
            let exposed = try core.geometrySet(workingRef:ref,ifGeometryState:rotated.geometryStateHash,rotation:-5)
            XCTAssertEqual(exposed.exposedCorners?.count,4)
            XCTAssertTrue(exposed.exposedCorners!.allSatisfy { $0.distance > 100 })
            // Explicit crops at a new rotation still use exact containment before dispatch.
            let writes = fake.writeCount
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:exposed.geometryStateHash,crop:CropRect(centerX:3163,centerY:2254,width:6000,height:4000),rotation:5))
            XCTAssertEqual(fake.writeCount,writes)
            // Restoring an observed crop reports what it restores; it is not a new containment claim.
            let restored = try core.geometryRestore(workingRef:ref,ifGeometryState:exposed.geometryStateHash)
            XCTAssertEqual(restored.after.crop,source.geometry!.crop)
            XCTAssertNil(restored.exposedCorners)
        }
    }

    /// Orientation is absolute and applied first; crops are planned on the oriented canvas.
    private static func testOrientation() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "orientation-db"}, imageDimensions:{_ in [6000,4000]})
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let source = try core.get(ref:"1"), doc = try core.getDocumentInfo()
            let ref = try core.editVariant(sourceRef:"1",ifState:source.stateHash,ifDocument:doc.openToken).workingRef
            let token = source.geometryStateHash!
            fake.handlers = []
            for bad in [45, 360, -90, 1] {
                XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,orientation:bad)) { XCTAssertTrue(isInvalidRequest($0), "\(bad)") }
                XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:1.5,orientation:bad)) { XCTAssertTrue(isInvalidRequest($0), "\(bad) with a ratio") }
            }
            XCTAssertEqual(fake.handlers.filter { $0.hasPrefix("apply") }, [], "Invalid orientations never dispatch")
            XCTAssertNoThrow(try ContractSchema.validate(tool:"geometry_set", arguments:["workingRef":ref, "ifGeometryState":token, "orientation":270]))
            // Capture One's turned crop cannot be predicted, so an orientation-only dry run is refused.
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,orientation:90,dryRun:true))
            XCTAssertEqual(fake.writeCount, 0, "Refused requests never dispatch")

            let turned = try core.geometrySet(workingRef:ref,ifGeometryState:token,orientation:90)
            XCTAssertEqual(turned.after.orientation, 90)
            XCTAssertEqual(turned.after.crop, CropRect(centerX:2000,centerY:3000,width:4000,height:6000), "The turned crop is kept")
            XCTAssertEqual(turned.diff["orientation"], DoubleDiff(before:0, after:90))
            XCTAssertEqual(fake.lastOrientation, 90)
            XCTAssertTrue(fake.pendingBeforeWrite)
            let record = journal.find(operationId:turned.operationId)!
            XCTAssertEqual(record.requestedGeometry?.orientation, 90)
            XCTAssertEqual(record.beforeGeometry?.orientation, 0)
            XCTAssertEqual(record.afterGeometry?.orientation, 90)
            XCTAssertEqual(record.status, "succeeded")
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:token,orientation:0), "The old token is stale")
            let unchanged = try core.geometrySet(workingRef:ref,ifGeometryState:turned.geometryStateHash,orientation:90)
            XCTAssertEqual(unchanged.after, turned.after, "Setting the current orientation again changes nothing")
            XCTAssertEqual(unchanged.geometryStateHash, turned.geometryStateHash)

            // Back to 0 with a 3:2 ratio in one request: planned on the 6000 x 4000 canvas.
            let planned = try core.geometrySet(workingRef:ref,ifGeometryState:turned.geometryStateHash,aspectRatio:1.5,orientation:0,dryRun:true)
            XCTAssertEqual(planned.after.orientation, 0)
            XCTAssertEqual(planned.after.crop, CropRect(centerX:3000,centerY:2000,width:6000,height:4000))
            // A 3:4 ratio from 0 to 90 fits the portrait canvas, anchored to the top as viewed.
            let landscape = try core.geometrySet(workingRef:ref,ifGeometryState:turned.geometryStateHash,orientation:0)
            let top = try CropAnchor(x:0.5, y:0)
            let portraitPlan = try core.geometrySet(workingRef:ref,ifGeometryState:landscape.geometryStateHash,aspectRatio:0.75,anchor:top,orientation:90,dryRun:true)
            let portrait = try core.geometrySet(workingRef:ref,ifGeometryState:landscape.geometryStateHash,aspectRatio:0.75,anchor:top,orientation:90)
            XCTAssertEqual(portrait.after.crop, CropRect(centerX:2000,centerY:3333,width:4000,height:5333))
            XCTAssertEqual(portrait.after.crop, portraitPlan.after.crop, "The dry run predicts the oriented fit")
            XCTAssertEqual(portrait.anchoredCrop, portrait.after.crop)
            XCTAssertEqual(fake.handlers.last(where: { $0.hasPrefix("apply") }), "applyGeometry")
            XCTAssertEqual(fake.lastOrientation, 90)
            // Explicit crops are checked on the requested canvas before dispatch.
            let tall = CropRect(centerX:2000,centerY:3000,width:3800,height:5600)
            let writes = fake.writeCount
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:portrait.geometryStateHash,crop:tall,orientation:0)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertEqual(fake.writeCount, writes)
            let explicit = try core.geometrySet(workingRef:ref,ifGeometryState:portrait.geometryStateHash,crop:tall,orientation:90)
            XCTAssertEqual(explicit.after.crop, tall)

            // Restore returns the saved orientation together with the saved crop.
            let restored = try core.geometryRestore(workingRef:ref,ifGeometryState:explicit.geometryStateHash)
            XCTAssertEqual(restored.after.orientation, 0)
            XCTAssertEqual(restored.after.crop, source.geometry!.crop)
            XCTAssertEqual(fake.lastOrientation, 0)
            XCTAssertEqual(journal.find(operationId:restored.operationId)?.beforeGeometry?.orientation, 90)

            // Lens-corrected bounds exist only after the native orientation.
            var corrected = fake.record("1"); corrected["lensValues"] = [100.0,35,0,0,0,0,0,0]; fake.records["1"] = corrected
            let lens = try core.get(ref:ref).geometryStateHash!
            fake.handlers = []
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:lens,aspectRatio:0.75,anchor:top,orientation:90)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertThrowsError(try core.geometrySet(workingRef:ref,ifGeometryState:lens,aspectRatio:0.75,orientation:90,dryRun:true))
            XCTAssertEqual(fake.handlers.filter { $0.hasPrefix("apply") }, [])
            let nativeFit = try core.geometrySet(workingRef:ref,ifGeometryState:lens,aspectRatio:0.75,orientation:90)
            XCTAssertEqual(nativeFit.after.orientation, 90)
            XCTAssertEqual(fake.handlers.last(where: { $0.hasPrefix("apply") }), "applyCorrectedGeometry")
            XCTAssertEqual(journal.find(operationId:nativeFit.operationId)?.requestedGeometry?.orientation, 90)

            // A write whose readback keeps the old orientation is never accepted.
            fake.failure = "ignore-orientation"
            do {
                _ = try core.geometrySet(workingRef:ref,ifGeometryState:nativeFit.geometryStateHash,orientation:180)
                XCTFail("Expected an orientation readback mismatch")
            } catch let failure as OperationFailure {
                let status = try core.operationStatus(operationId:failure.operationId).status
                XCTAssertEqual(status, "partial-failure")
            }
            fake.failure = nil
        }
        XCTAssertThrowsError(try NativeEditing.validate(["orientation": .number(90)], target: NativeTarget())) { error in
            XCTAssertTrue(String(describing: error).contains("geometry_set for guarded orientation"), String(describing: error))
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

extension GeometryTests {
    private static func isInvalidRequest(_ error: Error) -> Bool {
        if case .invalidRequest = error as? C1Error { return true }
        return false
    }

    /// An anchored fit keeps the centred fit's size and lies inside `bounds` within a
    /// pixel. With room to move, the anchored edge sits on the bounds as viewed, so
    /// y 0 touches the top: the largest canvas y.
    private static func assertPlaced(_ crop: CropRect, centred: CropRect, in bounds: CropRect, anchor: CropAnchor, _ label: String) {
        XCTAssertEqual(crop.width, centred.width, label); XCTAssertEqual(crop.height, centred.height, label)
        let left = crop.centerX - crop.width/2, right = crop.centerX + crop.width/2
        let bottom = crop.centerY - crop.height/2, top = crop.centerY + crop.height/2
        let minX = bounds.centerX - bounds.width/2, maxX = bounds.centerX + bounds.width/2
        let minY = bounds.centerY - bounds.height/2, maxY = bounds.centerY + bounds.height/2
        XCTAssertTrue(left >= minX - 1 && right <= maxX + 1 && bottom >= minY - 1 && top <= maxY + 1, "inside bounds: \(label)")
        let roomX = bounds.width - crop.width >= 1, roomY = bounds.height - crop.height >= 1
        if roomY && anchor.y == 0 { XCTAssertTrue(top <= maxY && top > maxY - 1, "top-aligned: \(label)") }
        if roomY && anchor.y == 1 { XCTAssertTrue(bottom >= minY && bottom < minY + 1, "bottom-aligned: \(label)") }
        if roomX && anchor.x == 0 { XCTAssertTrue(left >= minX && left < minX + 1, "left-aligned: \(label)") }
        if roomX && anchor.x == 1 { XCTAssertTrue(right <= maxX && right > maxX - 1, "right-aligned: \(label)") }
    }

    /// The canvas is already oriented, so every orientation anchors in the same canvas
    /// terms; orientation only changes the oriented size the bounds come from.
    private static func testAnchorMaths() {
        let anchors = [(0.0, 0.0), (0.5, 0), (0.5, 1), (1, 1), (0, 0.5), (1, 0.5), (0.25, 0.75)].map { try! CropAnchor(x: $0.0, y: $0.1) }
        func fit(_ g: Geometry, _ angle: Double, _ ratio: Double, _ anchor: CropAnchor?) throws -> CropRect {
            try g.target(crop: nil, rotation: angle, aspectRatio: ratio, anchor: anchor).crop
        }
        XCTAssertNoThrowBlock {
            let landscape = Geometry.fixture(width: 6000, height: 4000)
            var vertical = landscape; vertical.orientation = 90
            let pinned: [(CropRect, CropRect, String)] = [
                (try fit(landscape, 0, 0.75, nil), CropRect(centerX: 3000, centerY: 2000, width: 3000, height: 4000), "Unanchored fit unchanged"),
                (try fit(vertical, 0, 0.75, nil), CropRect(centerX: 2000, centerY: 3000, width: 4000, height: 5333), "Unanchored fit unchanged"),
                (try fit(vertical, 0, 0.75, CropAnchor(x: 0.5, y: 0)), CropRect(centerX: 2000, centerY: 3333, width: 4000, height: 5333),
                 "Top-aligned on the vertical canvas: top edge 5999.5 of 6000"),
                (try fit(vertical, 0, 0.75, CropAnchor(x: 0.5, y: 1)), CropRect(centerX: 2000, centerY: 2667, width: 4000, height: 5333),
                 "Bottom-aligned: bottom edge 0.5"),
                (try fit(landscape, 0, 0.75, CropAnchor(x: 0, y: 0.5)), CropRect(centerX: 1500, centerY: 2000, width: 3000, height: 4000), "Left-aligned"),
            ]
            for (got, expected, label) in pinned { XCTAssertEqual(got, expected, label) }
            for orientation in [0, 90, 180, 270] {
                var g = landscape; g.orientation = orientation
                for angle in [-10.0, 0, 3, 10] {
                    let bounds = try g.safeBounds(rotation: angle)
                    for ratio in [0.75, 1.5] {
                        let centred = try fit(g, angle, ratio, nil), centreAnchored = try fit(g, angle, ratio, .center)
                        XCTAssertEqual(centreAnchored, centred, "0.5/0.5 is the centred fit")
                        for anchor in anchors {
                            let label = "orientation \(orientation), \(angle) degrees, ratio \(ratio), anchor \(anchor.x)/\(anchor.y)"
                            let crop = try fit(g, angle, ratio, anchor)
                            assertPlaced(crop, centred: centred, in: bounds, anchor: anchor, label)
                            XCTAssertEqual(g.exposedCorners(of: crop, rotation: angle), [], "exact containment: \(label)")
                        }
                    }
                }
            }
            // Corrected geometry plans in Capture One's maximumCrop, off-centre and fractional here.
            var corrected = landscape; corrected.lensGeometry[0] = 50
            corrected.maximumCrop = CropRect(centerX: 3002.5, centerY: 1999.5, width: 5801, height: 3901)
            for ratio in [0.75, 1.5] {
                let centred = try fit(corrected, 0, ratio, nil), centreAnchored = try fit(corrected, 0, ratio, .center)
                XCTAssertEqual(centreAnchored, centred)
                for anchor in anchors {
                    assertPlaced(try fit(corrected, 0, ratio, anchor), centred: centred, in: corrected.maximumCrop, anchor: anchor,
                                 "corrected ratio \(ratio), anchor \(anchor.x)/\(anchor.y)")
                }
            }
            XCTAssertThrowsError(try fit(corrected, 3, 0.75, anchors[1]), "Corrected bounds at a new rotation exist only natively")
            var perspective = corrected; perspective.keystone[1] = 10
            XCTAssertNoThrowBlock { _ = try fit(perspective, 0, 0.75, nil) }
            XCTAssertThrowsError(try fit(perspective, 0, 0.75, anchors[1]), "Capture One normalizes perspective ratio fits")
            XCTAssertThrowsError(try landscape.target(crop: nil, rotation: 2, aspectRatio: nil, anchor: anchors[0]), "anchor requires aspectRatio")
            XCTAssertThrowsError(try landscape.target(crop: landscape.crop, rotation: nil, aspectRatio: nil, anchor: anchors[0]), "anchor excludes crop")
            for (x, y) in [(-0.01, 0.5), (0.5, 1.01), (Double.nan, 0.5), (0.5, Double.infinity)] {
                XCTAssertThrowsError(try CropAnchor(x: x, y: y)) { XCTAssertTrue(isInvalidRequest($0)) }
            }
            XCTAssertThrowsError(try JSONDecoder().decode(CropAnchor.self, from: Data(#"{"x":2,"y":0}"#.utf8)))
        }
    }

    private static func testAnchoredWrites() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        var vertical = fake.record("1")
        vertical["orientationDegrees"] = 90; vertical["cropValues"] = [2000.0,3000,4000,6000]; vertical["maximumValues"] = [2000.0,3000,4000,6000]
        fake.records["1"] = vertical
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "anchor-db"}, imageDimensions:{_ in [6000,4000]})
        let journal = OperationJournal(sessionDirectory:directory)
        XCTAssertNoThrowBlock {
            let source = try core.get(ref:"1"), doc = try core.getDocumentInfo()
            let ref = try core.editVariant(sourceRef:"1",ifState:source.stateHash,ifDocument:doc.openToken).workingRef
            let token = source.geometryStateHash!
            let top = try CropAnchor(x:0.5,y:0), bottom = try CropAnchor(x:0.5,y:1)
            fake.handlers = []
            let invalid: [() throws -> GeometryMutationResult] = [
                { try core.geometrySet(workingRef:ref,ifGeometryState:token,rotation:2,anchor:top) },
                { try core.geometrySet(workingRef:ref,ifGeometryState:token,rotation:2,anchor:.center) },
                { try core.geometrySet(workingRef:ref,ifGeometryState:token,crop:source.geometry!.crop,anchor:top) },
                { try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:0.75,anchor:top,keystone:KeystoneAdjustments(vertical:5)) },
            ]
            for call in invalid { XCTAssertThrowsError(try call()) { XCTAssertTrue(isInvalidRequest($0)) } }
            XCTAssertEqual(fake.handlers, [], "Invalid anchors fail before any Apple Event")

            let dry = try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:0.75,anchor:top,dryRun:true)
            let topCrop = CropRect(centerX:2000,centerY:3333,width:4000,height:5333)
            XCTAssertTrue(dry.isDryRun); XCTAssertEqual(fake.writeCount,0)
            XCTAssertEqual(dry.anchoredCrop,topCrop); XCTAssertEqual(dry.after.crop,topCrop)
            let plain = try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:0.75,dryRun:true)
            XCTAssertNil(plain.anchoredCrop)
            XCTAssertFalse(OutputFormatter.formatJson(plain).contains("anchoredCrop"), "No anchor, no new field")
            let centred = try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:0.75,anchor:.center,dryRun:true)
            XCTAssertEqual(centred.after,plain.after); XCTAssertEqual(centred.anchoredCrop,plain.after.crop)
            if case .compact(let summary, _) = ResultCompaction.compact(.value(dry), tool:"geometry_set", documentPath:directory.path) {
                XCTAssertNotNil(summary["anchoredCrop"], "Compact results report the chosen rectangle")
            } else { XCTFail("geometry_set results are compact") }
            if case .compact(let summary, _) = ResultCompaction.compact(.value(plain), tool:"geometry_set", documentPath:directory.path) {
                XCTAssertNil(summary["anchoredCrop"])
            } else { XCTFail("geometry_set results are compact") }

            let applied = try core.geometrySet(workingRef:ref,ifGeometryState:token,aspectRatio:0.75,anchor:top)
            XCTAssertEqual(applied.after.crop,topCrop); XCTAssertEqual(applied.anchoredCrop,topCrop)
            let record = journal.find(operationId:applied.operationId)!
            XCTAssertEqual(record.intendedGeometry?.crop,topCrop)
            XCTAssertNil(record.requestedGeometry,"Uncorrected positioned crops take the exact geometry path")
            XCTAssertEqual(fake.handlers.filter { $0.hasPrefix("apply") },["applyGeometry"])
            // Uncorrected bounds at a new rotation are known before dispatch, so rotation and anchor combine.
            let rotated = try core.geometrySet(workingRef:ref,ifGeometryState:applied.geometryStateHash,rotation:3,aspectRatio:0.75,anchor:bottom)
            let expected = try source.geometry!.target(crop:nil,rotation:3,aspectRatio:0.75,anchor:bottom).crop
            XCTAssertEqual(rotated.after.crop,expected); XCTAssertEqual(rotated.after.rotation,3)
            let centredAtThree = try source.geometry!.target(crop:nil,rotation:3,aspectRatio:0.75).crop
            XCTAssertTrue(expected.centerY < centredAtThree.centerY,"Bottom-aligned sits below centre")

            var corrected = fake.record("1")
            corrected["orientationDegrees"] = 0; corrected["rotationDegrees"] = 0.0; corrected["cropValues"] = [3000.0,2000,6000,4000]
            corrected["lensValues"] = [100.0,35,0,0,0,0,0,0]; corrected["maximumValues"] = [3150.0,2300,5000,3400]
            fake.records["1"] = corrected
            let lens = try core.get(ref:"1")
            let lensRef = try core.editVariant(sourceRef:"1",ifState:lens.stateHash,ifDocument:try core.getDocumentInfo().openToken,ifGeometryState:lens.geometryStateHash).workingRef
            let left = try CropAnchor(x:0,y:0.5)
            let lensDry = try core.geometrySet(workingRef:lensRef,ifGeometryState:lens.geometryStateHash!,aspectRatio:0.75,anchor:left,dryRun:true)
            XCTAssertEqual(lensDry.anchoredCrop,CropRect(centerX:1925,centerY:2300,width:2550,height:3400),"Left edge on the native bounds at 650")
            let lensApplied = try core.geometrySet(workingRef:lensRef,ifGeometryState:lens.geometryStateHash!,aspectRatio:0.75,anchor:left)
            XCTAssertEqual(lensApplied.after.crop,lensDry.anchoredCrop)
            XCTAssertEqual(fake.requestedBeforeWrite?.crop,lensDry.anchoredCrop,"Journaled as an explicit crop before dispatch")
            XCTAssertNil(fake.requestedBeforeWrite?.aspectRatio)
            XCTAssertEqual(lensApplied.after.lensGeometry,lens.geometry!.lensGeometry)
            var writes = fake.writeCount
            XCTAssertThrowsError(try core.geometrySet(workingRef:lensRef,ifGeometryState:lensApplied.geometryStateHash,rotation:3,aspectRatio:0.75,anchor:left)) {
                XCTAssertTrue(isInvalidRequest($0))
            }
            XCTAssertEqual(fake.writeCount,writes,"Corrected bounds at a new rotation are unknown before dispatch")
            let centredLens = try core.geometrySet(workingRef:lensRef,ifGeometryState:lensApplied.geometryStateHash,rotation:3,aspectRatio:0.75,anchor:.center)
            XCTAssertEqual(fake.requestedBeforeWrite?.aspectRatio,0.75,"The centre keeps the native ratio fit")
            XCTAssertNil(fake.requestedBeforeWrite?.crop)
            XCTAssertEqual(centredLens.anchoredCrop,centredLens.after.crop)

            var perspective = corrected; perspective["keystoneValues"] = [100.0,10,0,0,0]
            fake.records["1"] = perspective
            let tilted = try core.get(ref:"1")
            let tiltedRef = try core.editVariant(sourceRef:"1",ifState:tilted.stateHash,ifDocument:try core.getDocumentInfo().openToken).workingRef
            writes = fake.writeCount
            XCTAssertThrowsError(try core.geometrySet(workingRef:tiltedRef,ifGeometryState:tilted.geometryStateHash!,aspectRatio:0.75,anchor:left)) {
                XCTAssertTrue(isInvalidRequest($0))
            }
            XCTAssertEqual(fake.writeCount,writes)
        }
    }

    private static func testFullFrameRectangles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = GeometryFake(directory:directory)
        let core = SessionController(executor:fake, appInstance:{fake.base.generation}, databaseIdentity:{_ in "frame-db"}, imageDimensions:{_ in [6000,4000]})
        func values(_ r: PreviewRect?) -> [Double] { r.map { [$0.left, $0.top, $0.width, $0.height] } ?? [] }
        XCTAssertNoThrowBlock {
            let cloned = try core.cloneVariant(sourceRef:"1")
            let initial = try core.get(ref:cloned.workingRef)
            let crop = CropRect(centerX:2400,centerY:2200,width:2400,height:1600)
            let set = try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:initial.geometryStateHash!,crop:crop)
            let anchors = [try CropAnchor(x:0,y:0.5), .center, try CropAnchor(x:1,y:0.5)]
            let variants = fake.base.values.count
            // The 6000×4000 context renders at 1500×1000: 4 canvas pixels per preview pixel.
            let context = try core.preview(ref:cloned.workingRef,fullFrame:true,aspectRatio:0.75,anchors:anchors)
            XCTAssertEqual(context.width,1500); XCTAssertEqual(context.height,1000)
            XCTAssertEqual(values(context.currentCrop),[300,250,600,400],"Top-left origin: the crop top, 1000 px below the canvas top, is 250 px down")
            let candidates = context.candidateCrops ?? []
            XCTAssertEqual(candidates.map(\.anchor),anchors)
            let dryRuns = try anchors.map { try core.geometrySet(workingRef:cloned.workingRef,ifGeometryState:set.geometryStateHash,aspectRatio:0.75,anchor:$0,dryRun:true).anchoredCrop }
            XCTAssertEqual(candidates.map(\.crop),dryRuns,"Candidates are the crops a dry run returns")
            XCTAssertEqual(candidates.map { values($0.preview) },[[0,0,750,1000],[375,0,750,1000],[750,0,750,1000]])
            XCTAssertEqual(fake.base.values.count,variants,"Context clone deleted")
            let bare = try core.preview(ref:cloned.workingRef,fullFrame:true)
            XCTAssertEqual(values(bare.currentCrop),[300,250,600,400]); XCTAssertNil(bare.candidateCrops)
            let plain = try core.preview(ref:cloned.workingRef)
            XCTAssertNil(plain.currentCrop); XCTAssertNil(plain.candidateCrops)
            fake.handlers = []
            XCTAssertThrowsError(try core.preview(ref:cloned.workingRef,aspectRatio:0.75,anchors:anchors)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertThrowsError(try core.preview(ref:cloned.workingRef,fullFrame:true,anchors:anchors)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertThrowsError(try core.preview(ref:cloned.workingRef,fullFrame:true,aspectRatio:0.75)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertThrowsError(try core.preview(ref:cloned.workingRef,fullFrame:true,aspectRatio:0.75,anchors:Array(repeating:.center,count:10))) {
                XCTAssertTrue(isInvalidRequest($0))
            }
            XCTAssertEqual(fake.handlers,[],"Invalid candidate requests fail before any Apple Event")
            var tilted = fake.record(cloned.cloneVariantId); tilted["keystoneValues"] = [100.0,10,0,0,0]
            fake.records[cloned.cloneVariantId] = tilted
            XCTAssertThrowsError(try core.preview(ref:cloned.workingRef,fullFrame:true,aspectRatio:0.75,anchors:anchors)) { XCTAssertTrue(isInvalidRequest($0)) }
            XCTAssertFalse(fake.handlers.contains("cloneVariant"),"Unpredictable candidates fail before the context clone")
        }
        func rejects(_ tool: String, _ arguments: [String: Any], _ label: String) {
            XCTAssertThrowsError(try ToolRequest(tool:tool,arguments:arguments,profile:.standard),label) { XCTAssertTrue(isInvalidRequest($0),label) }
        }
        let geometry: [String: Any] = ["workingRef":"c1_edit_x","ifGeometryState":"g"]
        func with(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }
        let top: [String: Any] = ["x":0.5,"y":0]
        XCTAssertNoThrow(try ToolRequest(tool:"geometry_set",arguments:with(geometry,["aspectRatio":0.75,"anchor":top,"dryRun":true]),profile:.standard))
        rejects("geometry_set",with(geometry,["aspectRatio":0.75,"anchor":["x":1.01,"y":0]]),"x above 1")
        rejects("geometry_set",with(geometry,["aspectRatio":0.75,"anchor":["x":0.5,"y":-0.1]]),"y below 0")
        rejects("geometry_set",with(geometry,["aspectRatio":0.75,"anchor":["x":0.5]]),"missing y")
        rejects("geometry_set",with(geometry,["rotation":2,"anchor":top]),"anchor without aspectRatio")
        rejects("geometry_set",with(geometry,["crop":["centerX":10,"centerY":10,"width":4,"height":3],"anchor":top]),"anchor with crop")
        rejects("geometry_set",with(geometry,["aspectRatio":0.75,"anchor":top,"keystone":["vertical":5]]),"anchor with keystone")
        let preview: [String: Any] = ["ref":"c1_edit_x"]
        XCTAssertNoThrow(try ToolRequest(tool:"preview",arguments:with(preview,["fullFrame":true,"aspectRatio":0.75,"anchors":[top]]),profile:.standard))
        rejects("preview",with(preview,["aspectRatio":0.75,"anchors":[top]]),"anchors without fullFrame")
        rejects("preview",with(preview,["fullFrame":false,"aspectRatio":0.75,"anchors":[top]]),"anchors with fullFrame false")
        rejects("preview",with(preview,["fullFrame":true,"anchors":[top]]),"anchors without aspectRatio")
        rejects("preview",with(preview,["fullFrame":true,"aspectRatio":0.75]),"aspectRatio without anchors")
        rejects("preview",with(preview,["fullFrame":true,"aspectRatio":0.75,"anchors":[[String: Any]]()]),"empty anchors")
        rejects("preview",with(preview,["fullFrame":true,"aspectRatio":0.75,"anchors":Array(repeating:top,count:10)]),"ten anchors")
        rejects("preview",with(preview,["fullFrame":true,"aspectRatio":0.75,"anchors":[["x":2,"y":0]]]),"anchor out of range")
    }
}

extension Geometry {
    fileprivate static func fixture(width: Double, height: Double) -> Geometry {
        let full: [String: Any] = ["centerX": width/2, "centerY": height/2, "width": width, "height": height]
        let object: [String: Any] = ["crop": full, "rotation": 0, "orientation": 0, "imageWidth": width, "imageHeight": height,
            "maximumCrop": full, "flip": "none", "keystone": [100,0,0,0,0], "lensGeometry": [0,35,0,0,0,0,0,0],
            "lensProfile": "fixture", "hideDistortedAreas": true, "cropOutsideImage": false]
        return try! JSONDecoder().decode(Geometry.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
