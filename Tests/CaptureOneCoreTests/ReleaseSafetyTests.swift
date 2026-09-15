import Foundation
import CaptureOneCore
import ImageIO
import CoreGraphics

final class FakeScript: ScriptExecuting {
    let directory: URL
    var values: [String: [Double]] = ["1": [0, 0, 0, 5000, 0]]
    var ratings: [String: Int] = [:]
    var selectedIDs: Set<String> = []
    var listArguments: [NSAppleEventDescriptor] = []
    var documentCount = 1
    var isSession = true
    var catalogID: String?
    var version = "16.8.5.30"
    var calls: [String] = []
    var fail: String?
    var mutatePatch: [Bool] = []
    var parentOverride: String?
    var generation = "app-1"
    var beforeApply: (() -> Void)?
    var preparedBeforeDispatch = true
    var previewRoot: String?
    static func jpeg(width: Int = 2, height: Int = 2) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    init(directory: URL) { self.directory = directory }
    var parent: String { (isSession ? directory : directory.deletingLastPathComponent()).appendingPathComponent("fixture.CR3").path }
    func item(_ id: String) -> [String: Any] {
        let a = values[id]!
        return ["variantId": id, "parentImagePath": parentOverride ?? parent,
                "exposureVal": a[0], "contrastVal": a[1], "saturationVal": a[2], "temperatureVal": a[3], "tintVal": a[4], "starRating": 0, "colorTagVal": 0]
    }
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        calls.append(handler)
        if ["cloneVariant", "createBaselineVariant", "deleteVariant", "applyAdjustments", "ensurePreviewRecipe", "processPreview"].contains(handler) {
            preparedBeforeDispatch = preparedBeforeDispatch && OperationJournal(sessionDirectory: directory).unresolvedEntries().contains { $0.status == "pending" }
        }
        if fail == handler { throw C1Error.timeout("injected late reply") }
        let result: Any
        switch handler {
        case "getAppAndDocInfo":
            result = ["appVersion": version, "hasDocument": true, "docName": "fixture.cosessiondb",
                      "docPath": catalogID ?? directory.path, "docId": catalogID ?? directory.path,
                      "isSession": isSession, "documentCount": documentCount] as [String: Any]
        case "listVariants":
            listArguments = args
            result = values.keys.sorted().filter { !args[2].booleanValue || selectedIDs.contains($0) }.map {
                ["variantId": $0, "variantName": "fixture", "parentImagePath": parent, "isSelected": selectedIDs.contains($0), "starRating": ratings[$0] ?? 0, "colorTagVal": 0] as [String: Any]
            }
        case "getAdjustmentsBatch":
            guard let id = args[1].atIndex(1)?.stringValue, values[id] != nil else { throw C1Error.variantNotFound("missing") }
            result = [item(id)]
        case "cloneVariant", "createBaselineVariant":
            let id = "\((values.keys.compactMap(Int.init).max() ?? 0) + 1)"
            values[id] = handler == "cloneVariant" ? values[args[1].stringValue!] : [0, 0, 0, 5000, 0]
            result = [handler == "cloneVariant" ? "cloneId" : "baselineId": id]
        case "deleteVariant": values.removeValue(forKey: args[1].stringValue!); result = ["deleted": true, "existsNow": false]
        case "ensurePreviewRecipe":
            previewRoot = args[2].stringValue
            result = ["configured": true, "recipeName": "c1-preview"]
        case "processPreview":
            let target = URL(fileURLWithPath: args[3].stringValue!).appendingPathComponent(args[4].stringValue!).appendingPathComponent("preview.jpg")
            try FakeScript.jpeg().write(to: target)
            result = ["jobId": "job-1"]
        case "applyAdjustments":
            beforeApply?()
            let id = args[1].stringValue!
            let before = values[id]!
            let expected = (1...5).map { args[7].atIndex($0)!.doubleValue }
            guard before == expected else { throw C1Error.stateChanged("injected UI edit at dispatch") }
            mutatePatch = (2...6).map { args[$0].descriptorType != NSAppleEventDescriptor.missingValue().descriptorType }
            var after = before
            for n in 0..<5 where mutatePatch[n] { after[n] = args[n + 2].doubleValue }
            values[id] = after
            var object: [String: Any] = ["variantId": id]
            for (n, name) in ["Exposure", "Contrast", "Saturation", "Temperature", "Tint"].enumerated() {
                object["before\(name)Val"] = before[n]; object["after\(name)Val"] = after[n]
            }
            result = object
        default: throw C1Error.invalidRequest("Unexpected fake handler \(handler)")
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

struct ReleaseSafetyTests {
    static func run() {
        print("Running ReleaseSafetyTests...")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeScript(directory: dir)
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" })
        let journal = OperationJournal(sessionDirectory: dir)
        let store = ProvenanceStore(sessionDirectory: dir)
        XCTAssertNoThrowBlock {
            let clone = try core.cloneVariant(sourceRef: "1")
            let record = try store.validatedRecords()[clone.workingRef]!
            XCTAssertNotNil(record.documentToken)
            XCTAssertEqual(record.parentImagePath, fake.parent)
            let current = try core.get(ref: clone.workingRef)
            _ = try core.mutate(workingRefString: clone.workingRef, ifState: current.stateHash,
                                setAdjustments: Adjustments(exposure: 0.25), addAdjustments: nil)
            XCTAssertEqual(fake.mutatePatch, [true, false, false, false, false], "Only requested exposure is written")
            let after = try core.get(ref: clone.workingRef)
            XCTAssertThrowsError(try core.mutate(workingRefString: clone.workingRef, ifState: current.stateHash,
                                                setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            fake.parentOverride = "/wrong.CR3"
            XCTAssertThrowsError(try core.deleteVariant(workingRefString: clone.workingRef))
            fake.parentOverride = nil
            fake.generation = "app-2"
            let priorReads = fake.calls.filter { $0 == "getAdjustmentsBatch" }.count
            fake.fail = "getAdjustmentsBatch"
            do {
                _ = try core.get(ref: clone.workingRef)
                XCTAssertTrue(false, "Expired references must fail before native lookup")
            } catch let error as C1Error {
                XCTAssertEqual(error.errorCode, "document-changed")
            }
            XCTAssertEqual(fake.calls.filter { $0 == "getAdjustmentsBatch" }.count, priorReads)
            fake.fail = nil
            fake.generation = "app-1"
            fake.documentCount = 2
            XCTAssertThrowsError(try core.get(ref: clone.workingRef))
            fake.documentCount = 1
            fake.beforeApply = { fake.values[clone.cloneVariantId]![1] = 7 }
            XCTAssertThrowsError(try core.mutate(workingRefString: clone.workingRef, ifState: after.stateHash,
                                                setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            XCTAssertEqual(fake.values[clone.cloneVariantId]![0], 0.25, "Late UI conflict must not apply exposure")
            fake.beforeApply = nil
        }
        // Isolate each fault's journal so assertions cannot accidentally pass on an earlier blocker.
        try? FileManager.default.removeItem(at: journal.journalFile)
        for operation in ["cloneVariant", "createBaselineVariant", "deleteVariant", "applyAdjustments", "processPreview"] {
            XCTAssertNoThrowBlock {
                fake.fail = nil
                let clone = try core.cloneVariant(sourceRef: "1")
                fake.fail = operation
                do {
                    switch operation {
                    case "cloneVariant": _ = try core.cloneVariant(sourceRef: "1")
                    case "createBaselineVariant": _ = try core.createBaselineVariant(sourceRef: "1")
                    case "deleteVariant": _ = try core.deleteVariant(workingRefString: clone.workingRef)
                    case "processPreview": _ = try core.preview(ref: clone.workingRef)
                    default:
                        let current = try core.get(ref: clone.workingRef)
                        _ = try core.mutate(workingRefString: clone.workingRef, ifState: current.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil)
                    }
                    XCTFail("Expected injected timeout")
                } catch let failure as OperationFailure {
                    XCTAssertEqual(ErrorResponse.payload(failure)["error"] as? [String: String] != nil, true)
                    let pending = try core.operationStatus(operationId: failure.operationId)
                    XCTAssertEqual(pending.status, "outcome-unknown")
                    let beforeCalls = fake.calls.filter { $0 == "cloneVariant" }.count
                    fake.fail = nil
                    XCTAssertThrowsError(try core.cloneVariant(sourceRef: "1"))
                    XCTAssertEqual(fake.calls.filter { $0 == "cloneVariant" }.count, beforeCalls)
                    fake.generation += "-restarted"
                    let reconciled = try core.operationStatus(operationId: failure.operationId)
                    XCTAssertEqual(reconciled.status, "reconciled")
                    XCTAssertNoThrow(try journal.assertReady())
                }
            }
            fake.fail = nil
            try? FileManager.default.removeItem(at: journal.journalFile)
        }
        XCTAssertTrue(fake.preparedBeforeDispatch, "All Apple Event mutations have a durable pending entry")
        XCTAssertNoThrowBlock {
            let custom = dir.appendingPathComponent("custom")
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            let old = custom.appendingPathComponent("unrelated.jpg")
            try FakeScript.jpeg().write(to: old)
            let preview = try core.preview(ref: "1", outputDirOverride: custom.path)
            XCTAssertEqual(fake.previewRoot, custom.path)
            XCTAssertTrue(preview.outputPath.contains("/c1-previews/\(preview.operationId)/"))
            XCTAssertNotEqual(preview.outputPath, old.path)
            XCTAssertNotNil(preview.stateHash)
            XCTAssertEqual(preview.nativeVariantId, "1")
            // A partial JPEG is not a completed output, even if nonempty.
            let partial = dir.appendingPathComponent("partial")
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            try FakeScript.jpeg().prefix(30).write(to: partial.appendingPathComponent("preview.jpg"))
            XCTAssertThrowsError(try PreviewManager.shared.pollForOutputFile(inDirectory: partial, timeout: 0.7))
        }
        // Observe a delayed application after timeout without ever retrying it.
        XCTAssertNoThrowBlock {
            let clone = try core.cloneVariant(sourceRef: "1")
            let current = try core.get(ref: clone.workingRef)
            fake.fail = "applyAdjustments"
            var operationId = ""
            do {
                _ = try core.mutate(workingRefString: clone.workingRef, ifState: current.stateHash,
                                    setAdjustments: Adjustments(exposure: 2), addAdjustments: nil)
                XCTFail("Expected timeout")
            } catch let failure as OperationFailure { operationId = failure.operationId }
            fake.fail = nil
            fake.values[clone.cloneVariantId]![0] = 2 // Capture One finishes after the caller timed out.
            XCTAssertThrowsError(try core.cloneVariant(sourceRef: "1"))
            fake.generation += "-ended"
            let observations = try core.operationStatus(operationId: operationId)
            XCTAssertEqual(observations.afterAdjustments?.exposure, 2)
            XCTAssertEqual(observations.status, "reconciled")
            XCTAssertThrowsError(try core.get(ref: clone.workingRef), "Recovery must not silently rebind old references")
        }
        // Same-path database replacement changes identity even if contents are identical.
        XCTAssertNoThrowBlock {
            let file = dir.appendingPathComponent("identity.cosessiondb")
            try Data("database".utf8).write(to: file)
            let before = try DocumentIdentity.fileIdentity(path: file.path)
            try Data("database".utf8).write(to: file, options: .atomic)
            let after = try DocumentIdentity.fileIdentity(path: file.path)
            XCTAssertNotEqual(before, after)
        }
        // Corruption must fail closed, never erase evidence or dispatch a mutation.
        XCTAssertNoThrowBlock {
            try FileManager.default.createDirectory(at: journal.journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: journal.journalFile)
            let count = fake.calls.count
            XCTAssertThrowsError(try core.cloneVariant(sourceRef: "1"))
            XCTAssertFalse(fake.calls.dropFirst(count).contains("cloneVariant"))
            let journalText = try String(contentsOf: journal.journalFile)
            XCTAssertEqual(journalText, "broken")
            try FileManager.default.removeItem(at: journal.journalFile)
            try Data("broken".utf8).write(to: store.storeFile)
            XCTAssertThrowsError(try core.cloneVariant(sourceRef: "1"))
            let storeText = try String(contentsOf: store.storeFile)
            XCTAssertEqual(storeText, "broken")
        }
        XCTAssertThrowsError(try core.dump(batchSize: -1))
        XCTAssertThrowsError(try core.dump(batchSize: 0))
        XCTAssertThrowsError(try core.dump(batchSize: Int.max))
        XCTAssertThrowsError(try core.preview(ref: "1", timeout: .nan))
        XCTAssertThrowsError(try core.preview(ref: "1", timeout: -1))
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try FieldRegistry.shared.validateAdjustments(Adjustments(exposure: value)))
        }
        for args: [String: Any] in [["fields": [123]], ["fields": "exposure"], ["fields": [""]]] {
            XCTAssertThrowsError(try ContractSchema.validate(tool: "reset", arguments: args.merging(["workingRef": "x", "ifState": "h"]) { a, _ in a }))
        }
        for adj: [String: Any] in [["exposure": "bad", "contrast": 1], ["exposure": true], ["exposure": 1, "exp": 2], ["unknown": 3], [:]] {
            XCTAssertThrowsError(try ContractSchema.validate(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "adjustments": adj]))
        }
        XCTAssertThrowsError(try ContractSchema.validate(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "adjustments": ["exposure": 1], "contrast": 2]))
        XCTAssertThrowsError(try ContractSchema.validate(tool: "dump", arguments: ["batchSize": -1]))
        XCTAssertNoThrow(try ContractSchema.validate(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1]))
        XCTAssertThrowsError(try FieldRegistry.shared.parseKeyValueArguments(["exposure=1", "exp=2"]))
        XCTAssertThrowsError(try ContractSchema.parseAdjustments(["exposure": 1, "unknown": 2], delta: false))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ContractSchema.document()))
        let record = ProvenanceRecord(workingRef: "c1_wrk_test", sourceVariantId: "1", cloneVariantId: "2", documentPath: dir.path, documentName: "fixture", parentImagePath: fake.parent, creationOperationId: "op", baselineAdjustments: Adjustments(), baselineStateHash: "h")
        try? FileManager.default.removeItem(at: store.storeFile)
        XCTAssertNoThrow(try store.register(record: record))
        XCTAssertThrowsError(try store.resolveManagedWorkingReference(record.workingRef, currentDocumentPath: dir.path + "-copy"))
        XCTAssertThrowsError(try store.resolveManagedWorkingReference(record.workingRef, currentDocumentPath: dir.deletingLastPathComponent().path))
    }
}
