import Foundation
import CaptureOneCore

struct StateHashTests {
    static func run() {
        print("Running StateHashTests...")
        let adj1 = Adjustments(exposure: 0.85, contrast: 18.0, saturation: -25.0, temperature: 5600.0, tint: 7.5)
        let adj2 = Adjustments(exposure: 0.85000001, contrast: 18.0000002, saturation: -25.0, temperature: 5600.01, tint: 7.50001)

        let hash1 = StateHash.compute(for: adj1)
        let hash2 = StateHash.compute(for: adj2)

        XCTAssertEqual(hash1, hash2, "StateHash should be identical within tolerance rounding")
        XCTAssertEqual(hash1.hex.count, 64)

        let adj3 = Adjustments(exposure: 1.20, contrast: 18.0, saturation: -25.0, temperature: 5600.0, tint: 7.5)
        let hash3 = StateHash.compute(for: adj3)

        XCTAssertNotEqual(hash1, hash3, "Different adjustments must produce different state hashes")
    }
}
