import Foundation
import CaptureOneCore

private final class NativeManyFake: ScriptExecuting {
    let base: FakeScript
    let native: NativeFake
    var reads = 0
    var onRead: ((Int) throws -> Void)?
    init(_ base: FakeScript) { self.base = base; self.native = NativeFake(base) }
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        if handler == "nativeRead" { reads += 1; try onRead?(reads) }
        return try native.executeAndDecode(handler: handler, args: args)
    }
}

struct ScopedGetTests {
    static func run() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory), bridge = NativeManyFake(fake)
        var database = "db"
        let core = SessionController(executor: bridge, appInstance: { fake.generation }, databaseIdentity: { _ in database })
        let targets = [NativeTarget(), NativeTarget(scope: "lens"), NativeTarget(scope: "variant")]
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: []))
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: Array(repeating: targets[0], count: 17)))
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: [NativeTarget(scope: "lens", layer: 1)]))
        XCTAssertEqual(fake.calls.count, 0, "Validate all targets before contacting Capture One")
        XCTAssertNoThrowBlock {
            let singles = try targets.map { try core.get(ref: "1", nativeTargets: [$0]).nativeSnapshots![0] }
            fake.calls = []; bridge.reads = 0
            let bundle = try core.get(ref: "1", nativeTargets: targets + [targets[0]])
            XCTAssertEqual(bundle.nativeSnapshots!, singles + [singles[0]], "Tokens and values match independent single reads")
            XCTAssertEqual(bundle.id, "1")
            var compact = bundle
            compact.nativeSnapshots = nil; compact.openToken = nil
            let legacy = try core.get(ref: "1")
            XCTAssertEqual(compact, legacy)
            let compactJSON = OutputFormatter.formatJson(legacy)
            XCTAssertFalse(compactJSON.contains("nativeSnapshots"))
            XCTAssertFalse(compactJSON.contains("openToken"))
            XCTAssertTrue(OutputFormatter.renderGetResult(bundle, format: .human).contains("clarity amount"))
            XCTAssertEqual(bridge.reads, 3, "Duplicate targets reuse one observation, preserving order")
            XCTAssertEqual(fake.calls.filter { $0 == "getAdjustmentsBatch" }.count, 3, "Read source once plus final drift validation")
            let entries = try OperationJournal(sessionDirectory: directory).validatedEntries()
            XCTAssertTrue(entries.isEmpty)
            XCTAssertEqual(fake.values.count, 1)
            fake.calls = []; bridge.reads = 0
            let singleBundle = try core.get(ref: "1", nativeTargets: [targets[0]])
            XCTAssertEqual(singleBundle.nativeSnapshots!, [singles[0]])
            XCTAssertEqual(bridge.reads, 1)
            XCTAssertEqual(fake.calls.filter { $0 == "getAdjustmentsBatch" }.count, 1, "Single-scope reads avoid batch revalidation")
        }
        // Every failure discards the bundle; no automatic retries or mutations.
        bridge.reads = 0
        bridge.onRead = { if $0 == 2 { throw C1Error.timeout("lost read reply") } }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        XCTAssertEqual(bridge.reads, 2)
        bridge.onRead = { _ in fake.values["1"]![0] = 1 }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.values["1"]![0] = 0
        bridge.onRead = { _ in fake.ratings["1"] = 5 }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.ratings = [:]
        bridge.onRead = { _ in fake.parentOverride = "/different.CR3" }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.parentOverride = nil
        bridge.onRead = { _ in fake.generation = "app-2" }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.generation = "app-1"
        bridge.onRead = { _ in database = "replacement" }
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        database = "db"; bridge.onRead = nil
        fake.version = "16.8.5.31"
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.version = "16.8.5.30"
        fake.documentCount = 2
        XCTAssertThrowsError(try core.get(ref: "1", nativeTargets: targets))
        fake.documentCount = 1
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), source = try core.get(ref: "1")
            let edit = try core.editVariant(sourceRef: "1", ifState: source.stateHash, ifDocument: doc.openToken)
            let batch = try core.get(ref: edit.workingRef, nativeTargets: [targets[0]])
            let write = try core.nativeSet(workingRef: edit.workingRef, target: targets[0],
                ifNativeState: batch.nativeSnapshots![0].nativeStateHash, patch: ["clarity amount": .number(7)])
            XCTAssertEqual(write.after.values["clarity amount"], .number(7))
            XCTAssertThrowsError(try core.nativeSet(workingRef: edit.workingRef, target: targets[0],
                ifNativeState: batch.nativeSnapshots![0].nativeStateHash, patch: ["clarity amount": .number(8)]))
            fake.generation = "app-3"
            XCTAssertThrowsError(try core.get(ref: edit.workingRef, nativeTargets: targets))
        }
    }
}
