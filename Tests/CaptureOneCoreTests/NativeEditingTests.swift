import Foundation
import CaptureOneCore

final class NativeFake: ScriptExecuting {
    let base: FakeScript
    var clarity = 0.0
    var fault = false
    var prepared = false
    var calls: [String] = []
    var onNativeRead: (() -> Void)?
    var layers: [[String:Any]] = []
    /// Raised by the next native action; `changeBeforeError` also adds a layer first.
    var actionError: C1Error?
    var changeBeforeError = false
    /// Layers a successful action appends.
    var addedLayers = 1
    init(_ base: FakeScript) { self.base = base }
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        calls.append(handler)
        if handler == "nativeRead" {
            onNativeRead?()
            let result: [String:Any] = ["nativeRows":[["fieldName":"clarity amount", "numbersVal":[clarity]]], "nativeLayers":layers, "basicColorCount":0, "advancedColorCount":0]
            return try JSONDecoder().decode(T.self, from:JSONSerialization.data(withJSONObject:result))
        }
        if handler == "nativeApply" || handler == "nativeAction" {
            try base.intercept(handler)
            prepared = OperationJournal(sessionDirectory:base.directory).unresolvedEntries().contains { $0.beforeNative != nil && $0.nativePatch != nil }
            if fault { throw C1Error.timeout("native fault") }
            if handler == "nativeAction", let actionError {
                if changeBeforeError { layers.append(["nativeName":"partial", "nativeKind":"adjustment", "nativeOpacity":100, "nativeEnabled":true]) }
                throw actionError
            }
            if handler == "nativeAction" {
                // Actions append layers (layer.create, mask.people); a misapplied action adds nothing.
                if !base.misapply { for _ in 0..<addedLayers { layers.append(["nativeName":"fixture layer", "nativeKind":"adjustment", "nativeOpacity":100, "nativeEnabled":true]) } }
            } else {
                clarity = args[10].atIndex(1)!.doubleValue + (base.misapply ? 1 : 0)
            }
            return try JSONDecoder().decode(T.self, from:Data("true".utf8))
        }
        return try base.executeAndDecode(handler:handler, args:args)
    }
}
struct NativeEditingTests {
    static func run() {
        print("Running NativeEditingTests...")
        let target = NativeTarget()
        XCTAssertTrue((NativeEditing.fields["adjustments"]?.count ?? 0) > 80)
        XCTAssertNoThrowBlock {
            _ = try NativeEditing.parsePatch(Data("{\"clarity amount\":15,\"black and white\":true,\"rgb curve\":[0,0,50,55,100,100]}".utf8), target:target)
        }
        for json in ["{}", "{\"clarity amount\":null}", "{\"unknown\":1}", "{\"clarity amount\":true}", "{\"clarity amount\":\"5\"}", "{\"rgb curve\":[0,0,60,40,50,60,100,100]}", "{\"rgb curve\":[0,0,100]}", "{\"flip\":\"horizontal\"}", "{\"exposure\":5}", "{\"clarity method\":\"bogus\"}"] {
            XCTAssertThrowsError(try NativeEditing.parsePatch(Data(json.utf8), target:target), json)
        }
        XCTAssertThrowsError(try NativeEditing.validate(["clarity amount":.number(1)], target:NativeTarget(layer:Int.max)))
        XCTAssertThrowsError(try NativeEditing.validateAction("mask.feather", target:NativeTarget(scope:"layer",layer:1), arguments:["amount":.number(101)]))
        XCTAssertThrowsError(try NativeEditing.validateAction("mask.clear", target:target, arguments:[:]))
        XCTAssertThrowsError(try NativeEditing.validateAction("layer.create", target:target, arguments:["name":.text("x"),"kind":.text("background")]))
        XCTAssertThrowsError(try ContractSchema.validate(tool:"get", arguments:["ref":"1","nativeTargets":[["scope":"adjustments","layer":true]]]))
        for band in ["master", "shadow", "midtone", "highlight"] {
            let hue = "color balance \(band) hue", saturation = "color balance \(band) saturation"
            XCTAssertEqual(NativeEditing.orderedPatchKeys([hue:.number(237), saturation:.number(0.2)], target:target), [saturation, hue])
            XCTAssertTrue(NativeEditing.matchesReadback(field:hue, expected:.number(0), actual:.number(360)))
            XCTAssertTrue(NativeEditing.matchesReadback(field:hue, expected:.number(360), actual:.number(0)))
            XCTAssertFalse(NativeEditing.matchesReadback(field:hue, expected:.number(237), actual:.number(237.14285)))
            XCTAssertFalse(NativeEditing.matchesReadback(field:saturation, expected:.number(0), actual:.number(360)))
            XCTAssertEqual(NativeEditing.orderedPatchKeys([hue:.number(237)], target:target), [hue])
            XCTAssertEqual(NativeEditing.orderedPatchKeys([saturation:.number(0.2)], target:target), [saturation])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = FakeScript(directory:directory), bridge = NativeFake(fake)
        let core = SessionController(executor:bridge, appInstance:{ fake.generation }, databaseIdentity:{ _ in "db" })
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), source = try core.get(ref:"1")
            let edit = try core.editVariant(sourceRef:"1", ifState:source.stateHash, ifDocument:doc.openToken)
            let initial = try core.get(ref:edit.workingRef, nativeTargets:[target]).nativeSnapshots![0]
            XCTAssertThrowsError(try core.nativeSet(workingRef:"1", target:target, ifNativeState:initial.nativeStateHash, patch:["clarity amount":.number(5)]))
            XCTAssertThrowsError(try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:"stale", patch:["clarity amount":.number(5)]))
            let peopleDry = try core.nativeAction(workingRef:edit.workingRef, target:target, ifNativeState:initial.nativeStateHash, action:"mask.people", arguments:["areas":.texts(["face skin"]), "separateLayers":.boolean(false)], dryRun:true)
            XCTAssertTrue(peopleDry.dryRun)
            let dry = try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:initial.nativeStateHash, patch:["clarity amount":.number(5)], dryRun:true)
            XCTAssertEqual(dry.after, initial)
            XCTAssertEqual(bridge.clarity, 0)
            // A prior read/dry run must never authorize reuse across operations.
            fake.values["1"]![0] = 0.75
            bridge.calls.removeAll()
            XCTAssertThrowsError(try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:initial.nativeStateHash, patch:["clarity amount":.number(5)]))
            XCTAssertFalse(bridge.calls.contains("nativeApply"))
            let fresh = try core.get(ref:edit.workingRef, nativeTargets:[target])
            fake.parentOverride = "/different.CR3"
            XCTAssertThrowsError(try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:fresh.nativeSnapshots![0].nativeStateHash, patch:["clarity amount":.number(5)]))
            fake.parentOverride = nil
            bridge.onNativeRead = { fake.generation = "changed-during-read" }
            XCTAssertThrowsError(try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:fresh.nativeSnapshots![0].nativeStateHash, patch:["clarity amount":.number(5)]))
            XCTAssertFalse(bridge.calls.contains("nativeApply"))
            bridge.onNativeRead = nil
            fake.generation = "app-1"
            bridge.calls.removeAll()
            let result = try core.nativeSet(workingRef:edit.workingRef, target:target, ifNativeState:fresh.nativeSnapshots![0].nativeStateHash, patch:["clarity amount":.number(5)])
            XCTAssertEqual(bridge.calls.filter { $0 == "getAdjustmentsBatch" }.count, 2, "One fresh preparation read and one independent post-write read")
            XCTAssertEqual(bridge.calls.filter { $0 == "nativeRead" }.count, 2)
            XCTAssertTrue(bridge.prepared)
            XCTAssertEqual(result.after.values["clarity amount"], .number(5))
            XCTAssertTrue(result.after.nativeStateHash != initial.nativeStateHash)
            let journal = OperationJournal(sessionDirectory:directory)
            XCTAssertEqual(journal.find(operationId:result.operationId)?.status, "succeeded")
            XCTAssertEqual(journal.find(operationId:result.operationId)?.beforeAdjustments, fresh.adjustments)
            XCTAssertEqual(journal.find(operationId:result.operationId)?.beforeNative, fresh.nativeSnapshots![0])
            bridge.fault = true
            var operation = ""
            do { _ = try core.nativeSet(workingRef:edit.workingRef,target:target,ifNativeState:result.after.nativeStateHash,patch:["clarity amount":.number(10)]) }
            catch let failure as OperationFailure { operation = failure.operationId }
            XCTAssertFalse(operation.isEmpty)
            XCTAssertEqual(journal.find(operationId:operation)?.status,"outcome-unknown")
            XCTAssertThrowsError(try core.nativeSet(workingRef:edit.workingRef,target:target,ifNativeState:result.after.nativeStateHash,patch:["clarity amount":.number(10)]))
            bridge.fault = false; fake.generation = "app-2"
            let recovered = try core.operationStatus(operationId:operation)
            XCTAssertEqual(recovered.status,"reconciled")
            XCTAssertTrue(recovered.afterNative != nil)
            XCTAssertThrowsError(try core.get(ref:edit.workingRef, nativeTargets:[target]).nativeSnapshots![0])
            XCTAssertEqual(fake.values.count,1)
        }
        peopleRefusals()
        peopleSuccess()
    }

    /// A successful people mask keeps existing layers and appends one mask layer,
    /// or up to one per area with separate layers; anything else is a readback mismatch.
    static func peopleSuccess() {
        for (separate, areas, added, misapply, succeeds) in [(false, 2, 1, false, true), (true, 3, 3, false, true), (true, 3, 2, false, true),
                                                              (false, 2, 2, false, false), (true, 2, 3, false, false), (false, 1, 1, true, false)] {
            let label = "separate \(separate), \(areas) areas, \(added) added, misapply \(misapply)"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let fake = FakeScript(directory:directory), bridge = NativeFake(fake)
            let core = SessionController(executor:bridge, appInstance:{ fake.generation }, databaseIdentity:{ _ in "db" })
            bridge.layers = [["nativeName":"Background", "nativeKind":"background", "nativeOpacity":100, "nativeEnabled":true]]
            XCTAssertNoThrowBlock {
                let doc = try core.getDocumentInfo(), source = try core.get(ref:"1")
                let ref = try core.editVariant(sourceRef:"1", ifState:source.stateHash, ifDocument:doc.openToken).workingRef
                let before = try core.get(ref:ref, nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                bridge.addedLayers = added; fake.misapply = misapply
                let names = Array(["body skin", "face skin", "hair"].prefix(areas))
                var operation: String?
                do {
                    operation = try core.nativeAction(workingRef:ref, target:NativeTarget(), ifNativeState:before.nativeStateHash, action:"mask.people",
                                                      arguments:["areas":.texts(names), "separateLayers":.boolean(separate)]).operationId
                } catch let failure as OperationFailure { XCTAssertEqual((failure.cause as? C1Error)?.errorCode, "readback-mismatch", label); operation = failure.operationId }
                XCTAssertEqual(OperationJournal(sessionDirectory:directory).find(operationId:operation ?? "")?.status, succeeds ? "succeeded" : "partial-failure", label)
            }
        }
    }

    /// A people mask without people is a definite, non-blocking failure only when the
    /// readback shows no change; anything else stays uncertain and blocks writes.
    static func peopleRefusals() {
        let noPeople = C1Error.scriptError("Capture One got an error: No people detected.", code: -1728)
        let people: [String:NativeValue] = ["areas":.texts(["body skin", "face skin"]), "separateLayers":.boolean(false)]
        for (name, error, changed) in [("unchanged", noPeople, false), ("changed", noPeople, true),
                                       ("other error", C1Error.scriptError("Capture One got an error: Some object.", code: -1728), false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let fake = FakeScript(directory:directory), bridge = NativeFake(fake)
            let core = SessionController(executor:bridge, appInstance:{ fake.generation }, databaseIdentity:{ _ in "db" })
            let journal = OperationJournal(sessionDirectory:directory)
            XCTAssertNoThrowBlock {
                let doc = try core.getDocumentInfo(), source = try core.get(ref:"1")
                let ref = try core.editVariant(sourceRef:"1", ifState:source.stateHash, ifDocument:doc.openToken).workingRef
                let before = try core.get(ref:ref, nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                bridge.actionError = error; bridge.changeBeforeError = changed
                let context = RequestContext(tool:"native_action", progressMode:"quiet", directory:directory)
                var thrown: Error?
                do { _ = try context.withCurrent { try core.nativeAction(workingRef:ref, target:NativeTarget(), ifNativeState:before.nativeStateHash, action:"mask.people", arguments:people) } }
                catch { thrown = error; context.finish(error:error) }
                bridge.actionError = nil
                let entry = journal.loadEntries().last
                let payload = context.annotate(ErrorResponse.payload(thrown!))["error"] as! [String:Any]
                if name == "unchanged" {
                    XCTAssertEqual((thrown as? C1Error)?.errorCode, "no-people-detected", "An unchanged readback makes the refusal definite")
                    XCTAssertEqual(entry?.status, "failed")
                    XCTAssertEqual(entry?.afterNative?.layers, before.layers, "The refusal keeps its readback as evidence")
                    XCTAssertTrue(journal.unresolvedEntries().isEmpty)
                    XCTAssertEqual(context.snapshot.status, "failed")
                    XCTAssertNil(payload["outcome"])
                    XCTAssertEqual(payload["recoveryAction"] as? String, "Nothing was changed; choose another mask for this photo.")
                    let fresh = try core.get(ref:ref, nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                    XCTAssertNoThrow(try core.nativeSet(workingRef:ref, target:NativeTarget(), ifNativeState:fresh.nativeStateHash, patch:["clarity amount":.number(5)]), "A definite refusal blocks nothing")
                } else {
                    XCTAssertTrue(thrown is OperationFailure, "\(name) stays uncertain")
                    XCTAssertEqual(entry?.status, "outcome-unknown")
                    XCTAssertEqual(context.snapshot.status, "outcome-unknown")
                    XCTAssertEqual(payload["outcome"] as? String, "inspect-operation")
                    let fresh = try core.get(ref:ref, nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                    XCTAssertThrowsError(try core.nativeSet(workingRef:ref, target:NativeTarget(), ifNativeState:fresh.nativeStateHash, patch:["clarity amount":.number(5)]), "\(name) blocks writes")
                }
                XCTAssertEqual(bridge.clarity, name == "unchanged" ? 5 : 0)
            }
        }
    }
}
