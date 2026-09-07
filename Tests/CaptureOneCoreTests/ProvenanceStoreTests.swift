import Foundation
import CaptureOneCore

struct ProvenanceStoreTests {
    static func run() {
        print("Running ProvenanceStoreTests...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProvenanceStore(sessionDirectory: tempDir)

        let ref = WorkingRef()
        let record = ProvenanceRecord(
            workingRef: ref.rawValue,
            sourceVariantId: "1",
            cloneVariantId: "66",
            documentPath: tempDir.path,
            documentName: "test.cosessiondb",
            parentImagePath: "/tmp/raw.cr3",
            creationOperationId: "op-123",
            baselineAdjustments: Adjustments(exposure: 0.0),
            baselineStateHash: "abc"
        )
        XCTAssertNoThrow(try store.register(record: record))

        let loaded = store.find(workingRef: ref.rawValue)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.cloneVariantId, "66")
        XCTAssertEqual(loaded?.sourceVariantId, "1")

        let byClone = store.find(byCloneId: "66")
        XCTAssertNotNil(byClone)
        XCTAssertEqual(byClone?.workingRef, ref.rawValue)

        XCTAssertNoThrowBlock {
            let resolved = try store.resolveManagedWorkingReference(ref.rawValue, currentDocumentPath: tempDir.path)
            XCTAssertEqual(resolved.cloneVariantId, "66")
        }

        // Unmanaged raw ID throws
        XCTAssertThrowsError(try store.resolveManagedWorkingReference("1", currentDocumentPath: tempDir.path)) { error in
            guard let c1Err = error as? C1Error else { return XCTFail("Expected C1Error") }
            XCTAssertEqual(c1Err.errorCode, "unmanaged-variant")
        }

        // Mismatched document throws
        XCTAssertThrowsError(try store.resolveManagedWorkingReference(ref.rawValue, currentDocumentPath: "/other/session")) { error in
            guard let c1Err = error as? C1Error else { return XCTFail("Expected C1Error") }
            XCTAssertEqual(c1Err.errorCode, "document-changed")
        }
    }
}
