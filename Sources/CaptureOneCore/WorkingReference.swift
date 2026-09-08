import Foundation

public struct WorkingRef: Equatable, Hashable, CustomStringConvertible, Codable {
    public let rawValue: String

    public static let prefix = "c1_wrk_"

    public init(uuid: UUID = UUID()) {
        self.rawValue = Self.prefix + uuid.uuidString.lowercased()
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        self.rawValue = trimmed
    }

    public static func isWorkingRefString(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.prefix)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let val = try container.decode(String.self)
        guard Self.isWorkingRefString(val) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid working ref format: '\(val)'")
        }
        self.rawValue = val
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProvenanceRecord: Codable, Equatable {
    public let workingRef: String
    public let sourceVariantId: String
    public var cloneVariantId: String
    public let documentPath: String
    public let documentName: String
    public let parentImagePath: String?
    public let creationOperationId: String
    public let createdAt: String
    public let documentToken: String?
    public let baselineAdjustments: Adjustments
    public let baselineStateHash: String

    public init(
        workingRef: String,
        sourceVariantId: String,
        cloneVariantId: String,
        documentPath: String,
        documentName: String,
        parentImagePath: String?,
        creationOperationId: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        baselineAdjustments: Adjustments,
        baselineStateHash: String,
        documentToken: String? = nil
    ) {
        self.documentToken = documentToken
        self.workingRef = workingRef
        self.sourceVariantId = sourceVariantId
        self.cloneVariantId = cloneVariantId
        self.documentPath = documentPath
        self.documentName = documentName
        self.parentImagePath = parentImagePath
        self.creationOperationId = creationOperationId
        self.createdAt = createdAt
        self.baselineAdjustments = baselineAdjustments
        self.baselineStateHash = baselineStateHash
    }
}
