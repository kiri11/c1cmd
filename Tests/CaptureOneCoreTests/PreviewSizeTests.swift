import Foundation
import CaptureOneCore

struct PreviewSizeTests {
    static func run() {
        print("Running PreviewSizeTests...")
        defaultExportIsUnchanged()
        requestedSizeSelectsItsRecipe()
        invalidSizeFailsBeforeDispatch()
        readbackRejectsAnotherLongEdge()
    }

    private static func fixture(_ body: (FakeScript, SessionController, OperationJournal) throws -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory)
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" })
        XCTAssertNoThrowBlock { try body(fake, core, OperationJournal(sessionDirectory: directory)) }
    }

    private static func code(_ error: Error) -> String? {
        ((error as? OperationFailure)?.cause as? C1Error ?? error as? C1Error)?.errorCode
    }

    static func defaultExportIsUnchanged() {
        fixture { fake, core, journal in
            let preview = try core.preview(ref: "1")
            XCTAssertEqual(fake.previewRecipeCalls.map(\.name), ["c1-preview"], "Omitting size configures the original recipe")
            XCTAssertEqual(fake.previewRecipeCalls.map(\.longEdge), [1500])
            XCTAssertEqual(fake.processedRecipes, ["c1-preview"])
            XCTAssertEqual([preview.size, preview.width, preview.height], [1500, 1500, 1000])
            let last = try journal.validatedEntries().last
            XCTAssertEqual(last?.previewSize, 1500)
        }
    }

    static func requestedSizeSelectsItsRecipe() {
        fixture { fake, core, journal in
            let preview = try core.preview(ref: "1", size: PreviewSize(800))
            XCTAssertEqual(fake.previewRecipeCalls.map(\.name), ["c1-preview-800"])
            XCTAssertEqual(fake.previewRecipeCalls.map(\.longEdge), [800])
            XCTAssertEqual(fake.processedRecipes, ["c1-preview-800"])
            XCTAssertEqual([preview.size, preview.width, preview.height], [800, 800, 533])
            let entry = try journal.validatedEntries().last
            XCTAssertEqual(entry?.previewSize, 800, "The journal names the requested size")
            XCTAssertEqual(entry?.status, "succeeded")
        }
    }

    static func invalidSizeFailsBeforeDispatch() {
        for size in [0, 640, 1499, 1501, 2000] {
            XCTAssertThrowsError(try PreviewSize(size)) { XCTAssertEqual(code($0), "invalid-request") }
        }
        for size: Any in [640, 800.5, "800", true] {
            XCTAssertThrowsError(try ToolRequest(tool: "preview", arguments: ["ref": "1", "size": size], profile: .standard), "size \(size)") {
                XCTAssertEqual(code($0), "invalid-request")
            }
        }
        XCTAssertThrowsError(try ToolRequest(tool: "preview", arguments: ["ref": "1", "size": 640], profile: .standard)) {
            XCTAssertTrue("\($0)".contains(PreviewSize.usage), "Actual: \($0)")
        }
        XCTAssertNoThrow(try ToolRequest(tool: "preview", arguments: ["ref": "1", "size": 400], profile: .standard))
    }

    static func readbackRejectsAnotherLongEdge() {
        fixture { fake, core, journal in
            fake.exportedLongEdgeOverride = 1499
            do {
                _ = try core.preview(ref: "1")
                XCTFail("A 1499 px export from the 1500 px recipe must fail readback")
            } catch {
                XCTAssertEqual(code(error), "readback-mismatch", "Actual: \(error)")
            }
            let entry = try journal.validatedEntries().last
            XCTAssertEqual(entry?.previewSize, 1500)
            XCTAssertEqual(entry?.status, "outcome-unknown")
        }
    }
}
