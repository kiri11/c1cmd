import Foundation
import CaptureOneCore

public struct ResetTests {
    public static func run() {
        print("Running ResetTests...")

        let baseline = Adjustments(
            exposure: 0.25,
            contrast: 10.0,
            saturation: -15.0,
            temperature: 5250.0,
            tint: 4.5
        )

        // 1. Reset all fields (default when empty)
        do {
            let res = try FieldRegistry.shared.computeResetValues(fields: [], baseline: baseline)
            XCTAssertEqual(res.exposure, 0.0, "Reset exposure should be 0.0")
            XCTAssertEqual(res.contrast, 0.0, "Reset contrast should be 0.0")
            XCTAssertEqual(res.saturation, 0.0, "Reset saturation should be 0.0")
            XCTAssertEqual(res.temperature, 5250.0, "Reset temperature should match baseline")
            XCTAssertEqual(res.tint, 4.5, "Reset tint should match baseline")
        } catch {
            XCTFail("computeResetValues([]) threw error: \(error)")
        }

        // 2. Reset explicit "all"
        do {
            let res = try FieldRegistry.shared.computeResetValues(fields: ["all"], baseline: baseline)
            XCTAssertEqual(res.exposure, 0.0, "Reset all exposure")
            XCTAssertEqual(res.contrast, 0.0, "Reset all contrast")
            XCTAssertEqual(res.saturation, 0.0, "Reset all saturation")
            XCTAssertEqual(res.temperature, 5250.0, "Reset all temperature")
            XCTAssertEqual(res.tint, 4.5, "Reset all tint")
        } catch {
            XCTFail("computeResetValues(['all']) threw error: \(error)")
        }

        // 3. Reset selective fields
        do {
            let res = try FieldRegistry.shared.computeResetValues(fields: ["exposure"], baseline: baseline)
            XCTAssertEqual(res.exposure, 0.0, "Reset single exposure")
            XCTAssertNil(res.contrast, "Contrast should be nil when resetting only exposure")
            XCTAssertNil(res.saturation, "Saturation should be nil when resetting only exposure")
            XCTAssertNil(res.temperature, "Temperature should be nil when resetting only exposure")
            XCTAssertNil(res.tint, "Tint should be nil when resetting only exposure")
        } catch {
            XCTFail("computeResetValues(['exposure']) threw error: \(error)")
        }

        // 4. Reset aliases (exp, sat, wb, kelvin)
        do {
            let resExp = try FieldRegistry.shared.computeResetValues(fields: ["exp"], baseline: baseline)
            XCTAssertEqual(resExp.exposure, 0.0, "Reset exp alias")
            XCTAssertNil(resExp.contrast, "Contrast should be untouched")

            let resSat = try FieldRegistry.shared.computeResetValues(fields: ["sat"], baseline: baseline)
            XCTAssertEqual(resSat.saturation, 0.0, "Reset sat alias")

            let resWb = try FieldRegistry.shared.computeResetValues(fields: ["wb"], baseline: baseline)
            XCTAssertEqual(resWb.temperature, 5250.0, "Reset wb alias temperature")
            XCTAssertEqual(resWb.tint, 4.5, "Reset wb alias tint")
            XCTAssertNil(resWb.exposure, "Exposure should be untouched by wb reset")

            let resKelvin = try FieldRegistry.shared.computeResetValues(fields: ["kelvin"], baseline: baseline)
            XCTAssertEqual(resKelvin.temperature, 5250.0, "Reset kelvin alias")
            XCTAssertNil(resKelvin.tint, "Tint should be untouched by kelvin reset")
        } catch {
            XCTFail("computeResetValues alias testing threw error: \(error)")
        }

        // 5. Unsupported field throws error
        XCTAssertThrowsError(
            try FieldRegistry.shared.computeResetValues(fields: ["unsupported_prop"], baseline: baseline),
            "Unsupported field should throw"
        )
    }
}
