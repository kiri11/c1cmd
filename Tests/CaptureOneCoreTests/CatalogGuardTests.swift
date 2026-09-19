import Foundation
import CaptureOneCore

public struct CatalogGuardTests {
    public static func run() {
        print("Running CatalogGuardTests...")

        let catalogDoc = DocumentInfo(
            documentId: "/Users/user/Pictures/My Catalog.cocatalog",
            documentName: "My Catalog",
            documentPath: "/Users/user/Pictures/My Catalog.cocatalog",
            isSession: false,
            openToken: "tok123"
        )

        let sessionDoc = DocumentInfo(
            documentId: "/Users/user/Pictures/My Session/My Session.cosessiondb",
            documentName: "My Session",
            documentPath: "/Users/user/Pictures/My Session/My Session.cosessiondb",
            isSession: true,
            openToken: "tok456",
            captureFolder: "/Users/user/Pictures/My Session/Capture",
            outputFolder: "/Users/user/Pictures/My Session/Output"
        )

        let mutativeOps = ["clone", "delete", "set", "add", "reset", "baseline"]

        // 1. All mutative ops are rejected on Catalog documents
        for op in mutativeOps {
            XCTAssertThrowsError(
                try SessionController.shared.assertSessionWritable(docInfo: catalogDoc, operation: op),
                "Catalog mutation '\(op)' must be rejected"
            ) { err in
                if case let C1Error.invalidRequest(msg) = err {
                    XCTAssertTrue(msg.contains("Catalog"), "Error message should mention Catalog")
                    XCTAssertTrue(msg.contains("read-only"), "Error message should mention read-only")
                } else {
                    XCTFail("Expected C1Error.invalidRequest but got \(err)")
                }
            }
        }

        // 2. All mutative ops succeed on Session documents
        for op in mutativeOps {
            XCTAssertNoThrow(
                try SessionController.shared.assertSessionWritable(docInfo: sessionDoc, operation: op),
                "Session mutation '\(op)' must be accepted"
            )
        }

        // 3. Preview export is rejected on Catalog documents
        XCTAssertThrowsError(
            try SessionController.shared.assertSessionWritable(docInfo: catalogDoc, operation: "preview"),
            "Preview export must fail closed on Catalog"
        ) { err in
            if case let C1Error.invalidRequest(msg) = err {
                XCTAssertTrue(msg.contains("Catalog"), "Error message should mention Catalog")
                XCTAssertTrue(msg.contains("read-only"), "Error message should explain read-only scope")
            } else {
                XCTFail("Expected C1Error.invalidRequest but got \(err)")
            }
        }
    }
}

struct CatalogEditingTests {
    static func run() {
        print("Running CatalogEditingTests...")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        XCTAssertNoThrowBlock {
            let package = root.appendingPathComponent("Main.cocatalog")
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            let db = package.appendingPathComponent("Main.cocatalogdb")
            try Data("database".utf8).write(to: db)
            let fake = GeometryFake(directory: package)
            fake.base.isSession = false
            fake.base.catalogID = package.path
            try Data("original".utf8).write(to: URL(fileURLWithPath: fake.base.parent))
            func core(_ path: String?) -> SessionController {
                SessionController(executor: fake, appInstance: { fake.base.generation }, catalogWritePath: path, imageDimensions: { _ in [6000, 4000] })
            }
            let enabled = core(package.path)
            let readOnly = core(nil)
            let doc = try enabled.getDocumentInfo()
            XCTAssertEqual(doc.documentPath, package.path)
            XCTAssertTrue(doc.openToken.contains(db.path), "Bind the database file, not package inode")
            XCTAssertTrue(doc.writesEnabled)
            let readOnlyEnabled = try readOnly.getDocumentInfo().writesEnabled
            XCTAssertFalse(readOnlyEnabled)
            for path in [nil, "", "1", "Main.cocatalog", root.path, root.appendingPathComponent("Other.cocatalog").path] as [String?] {
                XCTAssertThrowsError(try core(path).cloneVariant(sourceRef: "1"))
            }
            XCTAssertFalse(fake.base.calls.contains("cloneVariant"), "Denied opt-ins never dispatch")
            fake.base.version = "16.9.0"
            let untestedEnabled = try enabled.getDocumentInfo().writesEnabled
            XCTAssertFalse(untestedEnabled)
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            fake.base.version = "16.8.5.30"
            let alias = root.appendingPathComponent("alias.cocatalog")
            try fm.createSymbolicLink(at: alias, withDestinationURL: package)
            let aliasEnabled = try core(alias.path).getDocumentInfo().writesEnabled
            XCTAssertTrue(aliasEnabled)
            let databasePathEnabled = try core(db.path).getDocumentInfo().writesEnabled
            XCTAssertTrue(databasePathEnabled)
            fake.base.catalogID = db.path
            let databasePathToken = try enabled.getDocumentInfo().openToken
            XCTAssertEqual(databasePathToken, doc.openToken)
            fake.base.catalogID = package.path

            let source = try enabled.get(ref: "1")
            let clone = try enabled.cloneVariant(sourceRef: "1")
            let ref = clone.workingRef
            XCTAssertTrue(fake.base.preparedBeforeDispatch)
            let current = try readOnly.get(ref: ref)
            XCTAssertEqual(current.id, clone.cloneVariantId)
            let cloneListed = try readOnly.listVariants().contains { $0.workingRef == ref }
            XCTAssertTrue(cloneListed)
            XCTAssertNoThrow(try readOnly.diff(ref1: ref))
            XCTAssertThrowsError(try readOnly.geometrySet(workingRef: ref, ifGeometryState: current.geometryStateHash!, rotation: 1))
            XCTAssertThrowsError(try readOnly.preview(ref: ref))
            XCTAssertThrowsError(try readOnly.deleteVariant(workingRefString: ref))
            XCTAssertThrowsError(try enabled.mutate(workingRefString: "1", ifState: source.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            XCTAssertThrowsError(try enabled.deleteVariant(workingRefString: "1"))
            _ = try enabled.mutate(workingRefString: ref, ifState: current.stateHash, setAdjustments: Adjustments(exposure: 0.5), addAdjustments: nil)
            XCTAssertThrowsError(try enabled.mutate(workingRefString: ref, ifState: current.stateHash, setAdjustments: Adjustments(exposure: 1), addAdjustments: nil))
            let tonal = try enabled.get(ref: ref)
            let crop = try enabled.geometrySet(workingRef: ref, ifGeometryState: tonal.geometryStateHash!, rotation: 2, aspectRatio: 1.5)
            XCTAssertTrue(fake.pendingBeforeWrite)
            XCTAssertThrowsError(try enabled.geometrySet(workingRef: ref, ifGeometryState: tonal.geometryStateHash!, rotation: 3))
            let preview = try enabled.preview(ref: ref)
            XCTAssertTrue(preview.outputPath.contains("/Main.cocatalog.c1-output/c1-previews/"), "Actual: \(preview.outputPath); expected package: \(package.path)")
            let originalGeometryHash = try enabled.get(ref: "1").geometryStateHash
            XCTAssertEqual(originalGeometryHash, source.geometryStateHash)
            let proposalGeometryHash = try enabled.get(ref: ref).geometryStateHash
            XCTAssertEqual(proposalGeometryHash, crop.geometryStateHash)
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".c1").path), "Catalogs never share parent state")

            // Unqualified catalog-stored originals fail before dispatch.
            let internalRAW = package.appendingPathComponent("stored.CR3")
            try Data("internal original".utf8).write(to: internalRAW)
            fake.base.parentOverride = internalRAW.path
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            fake.base.parentOverride = nil

            // Offline originals fail before any write event or pending journal record.
            try fm.removeItem(atPath: fake.base.parent)
            let dispatches = fake.base.calls.filter { $0 == "cloneVariant" }.count
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            XCTAssertEqual(fake.base.calls.filter { $0 == "cloneVariant" }.count, dispatches)
            try Data("original".utf8).write(to: URL(fileURLWithPath: fake.base.parent))

            // Outcome-unknown blocks subsequent writes; restart permits observation only.
            fake.failure = "lost-reply"
            var operationID = ""
            do { _ = try enabled.geometrySet(workingRef: ref, ifGeometryState: crop.geometryStateHash, rotation: 3, aspectRatio: 1.5) }
            catch let error as OperationFailure { operationID = error.operationId }
            XCTAssertFalse(operationID.isEmpty)
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            let unresolvedStatus = try enabled.operationStatus(operationId: operationID).status
            XCTAssertEqual(unresolvedStatus, "outcome-unknown")
            fake.base.generation = "app-2"
            fake.failure = nil
            let reconciledStatus = try enabled.operationStatus(operationId: operationID).status
            XCTAssertEqual(reconciledStatus, "reconciled")
            XCTAssertThrowsError(try enabled.get(ref: ref))
            let staleCloneListed = try enabled.listVariants().contains { $0.workingRef == ref }
            XCTAssertFalse(staleCloneListed)
            let fresh = try enabled.cloneVariant(sourceRef: "1")
            _ = try enabled.deleteVariant(workingRefString: fresh.workingRef)
            let originalStateHash = try enabled.get(ref: "1").stateHash
            XCTAssertEqual(originalStateHash, source.stateHash)

            let other = root.appendingPathComponent("Other.cocatalog")
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("other".utf8).write(to: other.appendingPathComponent("Other.cocatalogdb"))
            fake.base.catalogID = other.path
            let otherCatalogEnabled = try enabled.getDocumentInfo().writesEnabled
            XCTAssertFalse(otherCatalogEnabled)
            XCTAssertThrowsError(try enabled.get(ref: ref))
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            fake.base.catalogID = package.path

            let replacementRef = try enabled.cloneVariant(sourceRef: "1").workingRef
            try Data("replacement".utf8).write(to: db, options: .atomic)
            XCTAssertThrowsError(try enabled.get(ref: replacementRef), "Replacing database inside same package invalidates refs")
            let extra = package.appendingPathComponent("Ambiguous.cocatalogdb")
            try Data().write(to: extra)
            XCTAssertThrowsError(try enabled.cloneVariant(sourceRef: "1"))
            XCTAssertThrowsError(try readOnly.getDocumentInfo(), "Package-only reads remain ambiguous")
            fake.base.catalogID = db.path
            let exact = core(db.path)
            let exactDoc = try exact.getDocumentInfo()
            XCTAssertTrue(exactDoc.writesEnabled)
            let exactReadOnlyDoc = try readOnly.getDocumentInfo()
            XCTAssertFalse(exactReadOnlyDoc.writesEnabled)
            XCTAssertEqual(exactReadOnlyDoc.openToken, exactDoc.openToken)
            XCTAssertNoThrow(try readOnly.get(ref: "1"))
            let ambiguousAuthorization = try enabled.getDocumentInfo()
            XCTAssertFalse(ambiguousAuthorization.writesEnabled, "Package opt-in cannot select among databases")
            let wrongAuthorization = try core(extra.path).getDocumentInfo()
            XCTAssertFalse(wrongAuthorization.writesEnabled, "Another database in the same package is not authorized")
            let exactRef = try exact.cloneVariant(sourceRef: "1").workingRef
            fake.base.catalogID = extra.path
            XCTAssertThrowsError(try exact.get(ref: exactRef), "Switching databases inside one package invalidates references")
            fake.base.catalogID = db.path
            try Data("second replacement".utf8).write(to: db, options: .atomic)
            XCTAssertThrowsError(try exact.get(ref: exactRef), "Exact database replacement invalidates references")
            fake.base.catalogID = package.path
            try fm.removeItem(at: extra)
            try fm.removeItem(at: db)
            XCTAssertThrowsError(try enabled.getDocumentInfo())
            try fm.createSymbolicLink(at: db, withDestinationURL: other.appendingPathComponent("Other.cocatalogdb"))
            XCTAssertThrowsError(try enabled.getDocumentInfo(), "Database symlink outside catalog fails closed")
        }
    }
}
