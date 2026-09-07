import Foundation
import CaptureOneCore

struct FieldSpecTests {
    static func run() {
        print("Running FieldSpecTests...")
        let registry = FieldRegistry.shared

        XCTAssertEqual(registry.supportedAdjustmentFields.count, 5)
        let names = registry.supportedAdjustmentFields.map { $0.name }
        XCTAssertTrue(names.contains("exposure"))
        XCTAssertTrue(names.contains("contrast"))
        XCTAssertTrue(names.contains("saturation"))
        XCTAssertTrue(names.contains("temperature"))
        XCTAssertTrue(names.contains("tint"))

        XCTAssertEqual(registry.findAdjustmentSpec(named: "exp")?.name, "exposure")
        XCTAssertEqual(registry.findAdjustmentSpec(named: "sat")?.name, "saturation")
        XCTAssertEqual(registry.findAdjustmentSpec(named: "kelvin")?.name, "temperature")
        XCTAssertEqual(registry.findAdjustmentSpec(named: "temp")?.name, "temperature")
        XCTAssertNil(registry.findAdjustmentSpec(named: "nonexistent"))

        let expSpec = registry.findAdjustmentSpec(named: "exposure")!
        XCTAssertNoThrow(try registry.validateValue(0.0, for: expSpec))
        XCTAssertNoThrow(try registry.validateValue(4.0, for: expSpec))
        XCTAssertNoThrow(try registry.validateValue(-4.0, for: expSpec))
        XCTAssertThrowsError(try registry.validateValue(4.5, for: expSpec))
        XCTAssertThrowsError(try registry.validateValue(-5.0, for: expSpec))

        XCTAssertNoThrowBlock {
            let args = ["exp=0.35", "contrast=12.0", "kelvin=5600"]
            let parsed = try registry.parseKeyValueArguments(args)
            XCTAssertEqual(parsed.exposure, 0.35)
            XCTAssertEqual(parsed.contrast, 12.0)
            XCTAssertEqual(parsed.temperature, 5600.0)
            XCTAssertNil(parsed.saturation)
            XCTAssertNil(parsed.tint)
        }

        XCTAssertNoThrowBlock {
            let base = Adjustments(exposure: 0.5, contrast: 10.0, saturation: -5.0, temperature: 5400.0, tint: 2.0)
            let delta = Adjustments(exposure: -0.2, temperature: 200.0)
            let result = try registry.applyDelta(base: base, delta: delta)
            XCTAssertEqual(result.exposure!, 0.3, accuracy: 1e-5)
            XCTAssertEqual(result.contrast!, 10.0, accuracy: 1e-5)
            XCTAssertEqual(result.temperature!, 5600.0, accuracy: 0.05)
        }

        XCTAssertTrue(registry.valuesMatchWithinTolerance(field: "exposure", expected: 1.234, actual: 1.233999967))
        XCTAssertFalse(registry.valuesMatchWithinTolerance(field: "exposure", expected: 1.234, actual: 1.235))
        XCTAssertTrue(registry.valuesMatchWithinTolerance(field: "temperature", expected: 5400.0, actual: 5400.02))
        XCTAssertFalse(registry.valuesMatchWithinTolerance(field: "temperature", expected: 5400.0, actual: 5400.1))
    }
}
