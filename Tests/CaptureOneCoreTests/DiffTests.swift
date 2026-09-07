import Foundation
import CaptureOneCore

public struct DiffTests {
    public static func run() {
        print("Running DiffTests...")

        let adj1 = Adjustments(
            exposure: 0.0,
            contrast: 10.0,
            saturation: -20.0,
            temperature: 5500.0,
            tint: 5.0
        )

        let adj2 = Adjustments(
            exposure: 0.5,
            contrast: 10.0, // identical
            saturation: 0.0,
            temperature: 6000.0,
            tint: -5.0
        )

        // 1. Identical diff produces empty dictionary
        let zeroDiff = SessionController.shared.computeDiff(before: adj1, after: adj1)
        XCTAssertTrue(zeroDiff.isEmpty, "Diff of identical adjustments should be empty")

        // 2. Distinct adjustments produce accurate before, after, and delta
        let diff = SessionController.shared.computeDiff(before: adj1, after: adj2)
        XCTAssertEqual(diff.count, 4, "Should have diffs for exposure, saturation, temperature, tint")
        XCTAssertNil(diff["contrast"], "Contrast should not be present in diff since values are identical")

        if let expDiff = diff["exposure"] {
            XCTAssertEqual(expDiff.before ?? 0, 0.0, "Diff exposure before")
            XCTAssertEqual(expDiff.after ?? 0, 0.5, "Diff exposure after")
            XCTAssertEqual(expDiff.delta ?? 0, 0.5, "Diff exposure delta")
        } else {
            XCTFail("Missing exposure diff")
        }

        if let satDiff = diff["saturation"] {
            XCTAssertEqual(satDiff.before ?? 0, -20.0, "Diff saturation before")
            XCTAssertEqual(satDiff.after ?? 0, 0.0, "Diff saturation after")
            XCTAssertEqual(satDiff.delta ?? 0, 20.0, "Diff saturation delta")
        } else {
            XCTFail("Missing saturation diff")
        }

        if let tempDiff = diff["temperature"] {
            XCTAssertEqual(tempDiff.before ?? 0, 5500.0, "Diff temperature before")
            XCTAssertEqual(tempDiff.after ?? 0, 6000.0, "Diff temperature after")
            XCTAssertEqual(tempDiff.delta ?? 0, 500.0, "Diff temperature delta")
        } else {
            XCTFail("Missing temperature diff")
        }

        if let tintDiff = diff["tint"] {
            XCTAssertEqual(tintDiff.before ?? 0, 5.0, "Diff tint before")
            XCTAssertEqual(tintDiff.after ?? 0, -5.0, "Diff tint after")
            XCTAssertEqual(tintDiff.delta ?? 0, -10.0, "Diff tint delta")
        } else {
            XCTFail("Missing tint diff")
        }

        // 3. DoubleDiff nil handling
        let d1 = DoubleDiff(before: nil, after: 10.0)
        XCTAssertNil(d1.before, "Before should be nil")
        XCTAssertEqual(d1.after, 10.0, "After should be 10.0")
        XCTAssertNil(d1.delta, "Delta should be nil when before is nil")

        let d2 = DoubleDiff(before: 10.0, after: nil)
        XCTAssertNil(d2.delta, "Delta should be nil when after is nil")
    }
}
