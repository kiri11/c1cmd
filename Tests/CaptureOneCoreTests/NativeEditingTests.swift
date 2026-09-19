import Foundation
import CaptureOneCore

final class NativeFake: ScriptExecuting {
    let base: FakeScript
    var clarity = 0.0
    var fault = false
    var prepared = false
    var calls: [String] = []
    var onNativeRead: (() -> Void)?
    init(_ base: FakeScript) { self.base = base }
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        calls.append(handler)
        if handler == "nativeRead" {
            onNativeRead?()
            let result: [String:Any] = ["nativeRows":[["fieldName":"clarity amount", "numbersVal":[clarity]]], "nativeLayers":[], "basicColorCount":0, "advancedColorCount":0]
            return try JSONDecoder().decode(T.self, from:JSONSerialization.data(withJSONObject:result))
        }
        if handler == "nativeApply" {
            prepared = OperationJournal(sessionDirectory:base.directory).unresolvedEntries().contains { $0.beforeNative != nil && $0.nativePatch != nil }
            if fault { throw C1Error.timeout("native fault") }
            clarity = args[10].atIndex(1)!.doubleValue
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
    }
}
