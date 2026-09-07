import Foundation
import CaptureOneCore

public struct VersionCompatibilityTests {
    public static func run() {
        print("Running VersionCompatibilityTests...")

        // 1. Exact match in testedBuilds
        for tested in SessionController.testedBuilds {
            let compat = SessionController.evaluateVersionCompatibility(tested)
            XCTAssertTrue(compat.isTestedMatch, "Tested build '\(tested)' should be exact match")
            XCTAssertTrue(compat.isAllowed, "Tested build '\(tested)' should be allowed")
            XCTAssertNil(compat.warning, "Tested build '\(tested)' should produce no warning")
        }

        // 2. Allowed 16.4+ through 16.x builds (not in testedBuilds)
        let allowedUntested = ["16.4.0", "16.4.2.1", "16.7.1.11", "16.8.4.12", "16.9.0", "16.999.0"]
        for version in allowedUntested {
            let compat = SessionController.evaluateVersionCompatibility(version)
            XCTAssertFalse(compat.isTestedMatch, "Build '\(version)' should not be marked exact match")
            XCTAssertTrue(compat.isAllowed, "Build '\(version)' should be allowed")
            XCTAssertNotNil(compat.warning, "Build '\(version)' should produce a warning")
            if let w = compat.warning {
                XCTAssertTrue(w.contains("unverified"), "Warning should mention unverified")
                XCTAssertTrue(w.contains("16.4+"), "Warning should mention 16.4+")
            }
        }

        // 3. Sub-16.4 versions fail closed without override
        let subVersions = ["16.3.9", "16.3.0", "16.2.1", "16.0.0", "15.4.1", "14.0.0"]
        for version in subVersions {
            let compat = SessionController.evaluateVersionCompatibility(version)
            XCTAssertFalse(compat.isTestedMatch, "Sub-16.4 build '\(version)' should not match")
            XCTAssertFalse(compat.isAllowed, "Sub-16.4 build '\(version)' should not be allowed")
            XCTAssertNil(compat.warning, "Sub-16.4 build '\(version)' should produce no warning when rejected")
        }

        // 4. Major 17+ versions fail closed without override
        let futureVersions = ["17.0.0", "17.1.0", "18.0.0"]
        for version in futureVersions {
            let compat = SessionController.evaluateVersionCompatibility(version)
            XCTAssertFalse(compat.isTestedMatch, "Version 17+ build '\(version)' should not match")
            XCTAssertFalse(compat.isAllowed, "Version 17+ build '\(version)' should not be allowed")
            XCTAssertNil(compat.warning, "Version 17+ build '\(version)' should produce no warning when rejected")
        }

        // 5. Malformed version strings fail closed
        let malformed = ["unknown", "error", "", "abc", "16", "v16.5"]
        for version in malformed {
            let compat = SessionController.evaluateVersionCompatibility(version)
            XCTAssertFalse(compat.isAllowed, "Malformed build '\(version)' should not be allowed")
        }

        // 6. Override flag allows any version with override warning
        let overrideCases = ["15.4.1", "16.3.0", "17.0.0", "unknown"]
        for version in overrideCases {
            let compat = SessionController.evaluateVersionCompatibility(version, allowUntestedOverride: true)
            XCTAssertFalse(compat.isTestedMatch, "Overridden build '\(version)' is not tested match")
            XCTAssertTrue(compat.isAllowed, "Overridden build '\(version)' must be allowed")
            XCTAssertNotNil(compat.warning, "Overridden build '\(version)' must have warning")
            if let w = compat.warning {
                XCTAssertTrue(w.contains("override") || w.contains("unverified"), "Warning should mention override or unverified")
            }
        }

        // 7. DoctorReport Codable round-trip with testedBuilds and warning
        let report = DoctorReport(
            appRunning: true,
            appVersion: "16.8.4.10",
            exactBuildMatched: false,
            testedBuilds: ["16.8.5.30"],
            pinnedBuild: "16.8.5.30",
            hasDocument: true,
            docName: "Shoot.cosessiondb",
            docPath: "/tmp/Shoot",
            isSession: true,
            lockAcquired: true,
            unresolvedOperationsCount: 0,
            allChecksPassed: true,
            warning: "Running on unverified Capture One build '16.8.4.10'."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(report)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(DoctorReport.self, from: data)
            XCTAssertEqual(decoded.appVersion, "16.8.4.10", "appVersion round-trip")
            XCTAssertEqual(decoded.exactBuildMatched, false, "exactBuildMatched round-trip")
            XCTAssertEqual(decoded.testedBuilds, ["16.8.5.30"], "testedBuilds round-trip")
            XCTAssertEqual(decoded.allChecksPassed, true, "allChecksPassed round-trip")
            XCTAssertEqual(decoded.warning, "Running on unverified Capture One build '16.8.4.10'.", "warning round-trip")
        } catch {
            XCTFail("DoctorReport Codable round-trip failed: \(error)")
        }

        // 8. assertSessionWritable version check on unsupported build
        let unsupportedDoc = DocumentInfo(
            documentId: "/tmp/Test.cosessiondb",
            documentName: "Test",
            documentPath: "/tmp/Test",
            isSession: true,
            openToken: "tok",
            appVersion: "15.4.1"
        )
        XCTAssertThrowsError(
            try SessionController.shared.assertSessionWritable(docInfo: unsupportedDoc, operation: "clone"),
            "assertSessionWritable must reject unsupported version 15.4.1"
        ) { err in
            if case let C1Error.unsupportedVersion(msg) = err {
                XCTAssertTrue(msg.contains("15.4.1"), "Error should mention running version")
                XCTAssertTrue(msg.contains("16.4+"), "Error should mention supported range")
            } else {
                XCTFail("Expected C1Error.unsupportedVersion, got \(err)")
            }
        }

        // 9. assertSessionWritable version check on supported 16.4+ unverified build
        let supportedUntestedDoc = DocumentInfo(
            documentId: "/tmp/Test.cosessiondb",
            documentName: "Test",
            documentPath: "/tmp/Test",
            isSession: true,
            openToken: "tok",
            appVersion: "16.8.4.12"
        )
        XCTAssertNoThrow(
            try SessionController.shared.assertSessionWritable(docInfo: supportedUntestedDoc, operation: "clone"),
            "assertSessionWritable must accept supported 16.8.4.12 build"
        )
    }
}
