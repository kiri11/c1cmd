import Foundation
import CryptoKit

public struct StateHash: Equatable, Hashable, CustomStringConvertible, Codable {
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public var description: String { hex }

    public static func compute(for adjustments: Adjustments, schemaVersion: String = "1.0") -> StateHash {
        // Canonical sorted key-value pairs with tolerance-aware precision rounding
        var parts: [String] = []
        parts.append("\"schemaVersion\":\"\(schemaVersion)\"")

        if let contrast = adjustments.contrast {
            parts.append("\"contrast\":\(String(format: "%.4f", contrast))")
        } else {
            parts.append("\"contrast\":null")
        }

        if let exposure = adjustments.exposure {
            parts.append("\"exposure\":\(String(format: "%.4f", exposure))")
        } else {
            parts.append("\"exposure\":null")
        }

        if let saturation = adjustments.saturation {
            parts.append("\"saturation\":\(String(format: "%.4f", saturation))")
        } else {
            parts.append("\"saturation\":null")
        }

        if let temperature = adjustments.temperature {
            parts.append("\"temperature\":\(String(format: "%.1f", temperature))")
        } else {
            parts.append("\"temperature\":null")
        }

        if let tint = adjustments.tint {
            parts.append("\"tint\":\(String(format: "%.2f", tint))")
        } else {
            parts.append("\"tint\":null")
        }

        // Sort keys for strict canonical consistency
        parts.sort()
        let canonicalJson = "{" + parts.joined(separator: ",") + "}"
        let digest = SHA256.hash(data: Data(canonicalJson.utf8))
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return StateHash(hex: hexString)
    }
}
