import Foundation
import CaptureOneCore

/// Capture One resolves `variant id X of document` only inside the current collection,
/// so every handler receives the document with the route its variants resolve through.
struct VariantRouteTests {
    static func run() {
        print("Running VariantRouteTests...")
        testSessionDocumentsCarryNoCatalogRoute()
        testCatalogHandlersAddressAllImages()
        testAllImagesIsReadOncePerOpenDocument()
        testUnreadableCatalogFallsBackToCurrentCollection()
        testUnresolvableVariantError()
        testStoredAllImagesCollection()
    }

    private static func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isMissing(_ descriptor: NSAppleEventDescriptor?) -> Bool {
        descriptor?.descriptorType == NSAppleEventDescriptor.missingValue().descriptorType
    }

    /// A Catalog package with an online referenced original, open for writes.
    private static func catalog(allImages: @escaping (String) -> String?) -> (FakeScript, SessionController, URL) {
        let root = directory()
        let package = root.appendingPathComponent("Main.cocatalog")
        try! FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try! Data("database".utf8).write(to: package.appendingPathComponent("Main.cocatalogdb"))
        let fake = FakeScript(directory: package)
        fake.isSession = false
        fake.catalogID = package.path
        try! Data("original".utf8).write(to: URL(fileURLWithPath: fake.parent))
        let core = SessionController(lock: testLock, executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" },
                                     catalogWritePath: package.path, imageDimensions: { _ in [6000, 4000] },
                                     allImagesCollection: allImages, isAppRunning: { true })
        return (fake, core, root)
    }

    private static func testSessionDocumentsCarryNoCatalogRoute() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeScript(directory: dir)
        var reads = 0
        let core = SessionController(lock: testLock, executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" },
                                     allImagesCollection: { _ in reads += 1; return "2" })
        XCTAssertNoThrowBlock {
            _ = try core.get(ref: "1")
            let clone = try core.cloneVariant(sourceRef: "1")
            _ = try core.deleteVariant(workingRefString: clone.workingRef)
        }
        XCTAssertEqual(reads, 0, "Sessions never read a Catalog collection ID")
        XCTAssertTrue(fake.documentArguments.contains { $0.handler == "deleteVariant" })
        for (handler, document) in fake.documentArguments {
            XCTAssertEqual(document.numberOfItems, 2, handler)
            XCTAssertEqual(document.atIndex(1)?.stringValue, dir.path, handler)
            XCTAssertTrue(isMissing(document.atIndex(2)), "\(handler) routes a Session through its folders")
        }
    }

    private static func testCatalogHandlersAddressAllImages() {
        var databases: [String] = []
        let (fake, core, root) = catalog { databases.append($0); return "2" }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrowBlock {
            let source = try core.get(ref: "1")
            let clone = try core.cloneVariant(sourceRef: "1")
            let current = try core.get(ref: clone.workingRef)
            _ = try core.mutate(workingRefString: clone.workingRef, ifState: current.stateHash, setAdjustments: Adjustments(exposure: 0.5), addAdjustments: nil)
            let tonal = try core.get(ref: clone.workingRef)
            _ = try core.metadataSet(workingRef: clone.workingRef, ifMetadataState: tonal.metadataStateHash!, rating: 4)
            _ = try core.preview(ref: clone.workingRef)
            _ = try core.deleteVariant(workingRefString: clone.workingRef)
            XCTAssertEqual(source.id, "1")
        }
        let handlers = Set(fake.documentArguments.map(\.handler))
        for handler in ["getAdjustmentsBatch", "readParentSiblings", "cloneVariant", "applyAdjustments", "applyMetadata",
                        "ensurePreviewRecipe", "processPreview", "deleteVariant"] {
            XCTAssertTrue(handlers.contains(handler), "\(handler) was exercised")
        }
        for (handler, document) in fake.documentArguments {
            XCTAssertEqual(document.atIndex(1)?.stringValue, root.appendingPathComponent("Main.cocatalog").path, handler)
            XCTAssertEqual(document.atIndex(2)?.stringValue, "2", "\(handler) resolves through All Images")
        }
        XCTAssertEqual(databases, [root.appendingPathComponent("Main.cocatalog/Main.cocatalogdb").path],
                       "The stored ID is read from the open Catalog's database")
    }

    private static func testAllImagesIsReadOncePerOpenDocument() {
        var reads = 0
        let (fake, core, root) = catalog { _ in reads += 1; return "2" }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrowBlock {
            _ = try core.get(ref: "1")
            _ = try core.get(ref: "1")
            XCTAssertEqual(reads, 1, "One read per open document")
            fake.generation = "app-2"
            _ = try core.get(ref: "1")
            XCTAssertEqual(reads, 2, "A restart reopens the document and reads again")
        }
    }

    private static func testUnreadableCatalogFallsBackToCurrentCollection() {
        var reads = 0
        let (fake, core, root) = catalog { _ in reads += 1; return nil }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrowBlock {
            _ = try core.get(ref: "1")
            _ = try core.get(ref: "1")
        }
        XCTAssertEqual(reads, 1, "An unavailable ID is remembered for the open document too")
        XCTAssertTrue(fake.documentArguments.allSatisfy { isMissing($0.document.atIndex(2)) }, "No ID: current collection")

        // The default reader rejects a file that is not a supported Catalog database.
        let (defaultFake, _, defaultRoot) = catalog { _ in nil }
        defer { try? FileManager.default.removeItem(at: defaultRoot) }
        let defaultCore = SessionController(lock: testLock, executor: defaultFake, appInstance: { defaultFake.generation }, databaseIdentity: { _ in "database-1" })
        XCTAssertNoThrowBlock { _ = try defaultCore.get(ref: "1") }
        XCTAssertTrue(isMissing(defaultFake.documentArguments.last?.document.atIndex(2)))
    }

    private static func testUnresolvableVariantError() {
        let error = AppleScriptExecutor.error("Variant 4 is in neither the Catalog's All Images collection, a Session folder favorite nor the current collection.", number: -27004)
        XCTAssertEqual(error.errorCode, "variant-not-found")
        XCTAssertTrue(error.description.contains("current collection"), error.description)
        XCTAssertTrue(error.description.contains("make such a collection current"), error.description)
        // A people mask's -1728 is a native refusal, not a missing variant.
        XCTAssertEqual(AppleScriptExecutor.error("Can't get people mask.", number: -1728), .scriptError("Can't get people mask.", code: -1728))
        XCTAssertEqual(AppleScriptExecutor.error("x", number: -27003).errorCode, "identity-ambiguous")
    }

    /// The stored root names All Images by ID; the name is localized and its kind is shared with Trash.
    private static func testStoredAllImagesCollection() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CaptureOneCore/Resources/catalog-schema-16.8.5.json")
        guard let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))) as? [String: Any],
              let schema = manifest["schema"] as? String, let history = manifest["versionHistory"] as? [[String: Any]] else {
            return XCTFail("Catalog schema manifest is unreadable")
        }
        func database(rootPointsTo target: Int) -> String {
            let path = dir.appendingPathComponent("root-\(target).cocatalogdb").path
            let lines = schema.split(separator: "\n")
            let ddl = (lines.filter { $0.hasPrefix("table|") } + lines.filter { !$0.hasPrefix("table|") })
                .map { String($0.split(separator: "|", maxSplits: 3)[3]) + ";" }
            var sql = ddl
            for (index, version) in history.enumerated() {
                sql.append("INSERT INTO ZVERSIONINFO(Z_PK,ZVERSION,ZCOMPATIBLEVERSION,ZFORMAT) VALUES(\(index + 1),\(version["ZVERSION"]!),\(version["ZCOMPATIBLEVERSION"]!),'\(version["ZFORMAT"]!)');")
            }
            sql += ["INSERT INTO ZDOCUMENTCONTENT(Z_PK,ZDOCUMENTTYPE,ZDOCUMENTUUID,ZROOTCOLLECTION) VALUES(1,1,'fixture-uuid',1);",
                    "INSERT INTO ZENTITIES(Z_ENT,ZNAME) VALUES(20,'ProjectCollection'),(21,'CatalogAllImagesCollection'),(22,'TrashCollection');",
                    "INSERT INTO ZCOLLECTION(Z_PK,Z_ENT,ZNAME,ZALLIMAGESCOLLECTION) VALUES(1,20,'root',\(target));",
                    "INSERT INTO ZCOLLECTION(Z_PK,Z_ENT,ZNAME) VALUES(2,21,'Alle Bilder'),(5,22,'Trash');"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [path]
            let input = Pipe()
            process.standardInput = input
            try! process.run()
            input.fileHandleForWriting.write(Data(sql.joined(separator: "\n").utf8))
            try! input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "fixture database")
            return path
        }
        XCTAssertNoThrowBlock {
            let allImages = try CatalogReader(database: database(rootPointsTo: 2)).allImagesCollectionID()
            XCTAssertEqual(allImages, "2")
            let trash = try CatalogReader(database: database(rootPointsTo: 5)).allImagesCollectionID()
            XCTAssertNil(trash, "Trash is never All Images")
        }
    }
}
