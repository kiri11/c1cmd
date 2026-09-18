import Foundation
import CryptoKit

/// Writable classification fields, with a token independent of tone and geometry.
public struct VariantMetadata: Codable, Equatable {
    public let rating: Int
    public let colorTag: Int

    public init(rating: Int, colorTag: Int) {
        self.rating = rating
        self.colorTag = colorTag
    }

    public static func from(_ metadata: Metadata) -> VariantMetadata? {
        guard let rating = metadata.rating, let colorTag = metadata.colorTag,
              (0...5).contains(rating), (0...7).contains(colorTag) else { return nil }
        return VariantMetadata(rating: rating, colorTag: colorTag)
    }

    public var stateHash: String {
        let data = Data("metadata-v1:rating=\(rating);colorTag=\(colorTag)".utf8)
        return "metadata-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func changes(from before: VariantMetadata) -> [String: DoubleDiff] {
        var result: [String: DoubleDiff] = [:]
        if rating != before.rating { result["rating"] = DoubleDiff(before: Double(before.rating), after: Double(rating)) }
        if colorTag != before.colorTag { result["colorTag"] = DoubleDiff(before: Double(before.colorTag), after: Double(colorTag)) }
        return result
    }
}

public struct MetadataMutationResult: Codable, Equatable {
    public let operationId: String
    public let workingRef: String
    public let before: VariantMetadata
    public let after: VariantMetadata
    public let diff: [String: DoubleDiff]
    public let metadataStateHash: String
    public let isDryRun: Bool
}
