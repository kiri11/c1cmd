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
