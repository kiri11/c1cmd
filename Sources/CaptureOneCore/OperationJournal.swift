import Foundation

public struct DoubleDiff: Codable, Equatable {
    public let before: Double?
    public let after: Double?
    public let delta: Double?

    public init(before: Double?, after: Double?) {
        self.before = before
        self.after = after
        if let b = before, let a = after {
            self.delta = a - b
        } else {
            self.delta = nil
        }
    }
}

public struct OperationRecord: Codable, Equatable {
    public let operationId: String
    public var appInstance: String?
    public var documentIdentity: String?
    public var nativeVariantId: String?
    public var parentImagePath: String?
    public var variantIdsBefore: [String]?
    public var observedVariantIds: [String]?
    public let timestamp: String
    public let operationType: String
    public let workingRef: String?
    public let documentPath: String
    public let preconditionStateHash: String?
    public let intendedAdjustments: Adjustments?
    public let beforeAdjustments: Adjustments?
    public var afterAdjustments: Adjustments?
    public var beforeMetadata: VariantMetadata?
    public var intendedMetadata: VariantMetadata?
    public var afterMetadata: VariantMetadata?
    public var beforeGeometry: Geometry?
    public var intendedGeometry: Geometry?
    public var requestedGeometry: GeometryRequest?
    public var afterGeometry: Geometry?
    public var diff: [String: DoubleDiff]?
    public var status: String // "pending", "succeeded", "failed", "partial-failure", "outcome-unknown"
    public var error: String?
    public var previewOutputPath: String?

    public init(
        operationId: String = UUID().uuidString.lowercased(),
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        operationType: String,
        workingRef: String?,
        documentPath: String,
        preconditionStateHash: String? = nil,
        intendedAdjustments: Adjustments? = nil,
        beforeAdjustments: Adjustments? = nil,
        afterAdjustments: Adjustments? = nil,
        diff: [String: DoubleDiff]? = nil,
        status: String = "pending",
        error: String? = nil,
        previewOutputPath: String? = nil,
        beforeGeometry: Geometry? = nil,
        intendedGeometry: Geometry? = nil,
        requestedGeometry: GeometryRequest? = nil
    ) {
        self.beforeGeometry = beforeGeometry
        self.intendedGeometry = intendedGeometry
        self.requestedGeometry = requestedGeometry
        self.operationId = operationId
        self.timestamp = timestamp
        self.operationType = operationType
        self.workingRef = workingRef
        self.documentPath = documentPath
        self.preconditionStateHash = preconditionStateHash
        self.intendedAdjustments = intendedAdjustments
        self.beforeAdjustments = beforeAdjustments
        self.afterAdjustments = afterAdjustments
        self.diff = diff
        self.status = status
        self.error = error
        self.previewOutputPath = previewOutputPath
    }
}

public final class OperationJournal {
    public let sessionDirectory: URL
    public let journalFile: URL

    public init(sessionDirectory: URL) {
        self.sessionDirectory = sessionDirectory
        let c1Dir = sessionDirectory.appendingPathComponent(".c1", isDirectory: true)
        self.journalFile = c1Dir.appendingPathComponent("journal.jsonl")
    }

    private func ensureDirectoryExists() throws {
        let dir = journalFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func validatedEntries() throws -> [OperationRecord] {
        guard FileManager.default.fileExists(atPath: journalFile.path) else { return [] }
        let data = try Data(contentsOf: journalFile)
        guard let content = String(data: data, encoding: .utf8) else {
            throw C1Error.invalidRequest("Journal is not UTF-8; preserve it for recovery.")
        }
        var latest: [String: OperationRecord] = [:]
        var order: [String] = []
        for line in content.split(separator: "\n") {
            let record = try JSONDecoder().decode(OperationRecord.self, from: Data(line.utf8))
            if latest[record.operationId] == nil { order.append(record.operationId) }
            latest[record.operationId] = record
        }
        return order.compactMap { latest[$0] }
    }

    public func loadEntries() -> [OperationRecord] { (try? validatedEntries()) ?? [] }

    /// Append snapshots rather than rewriting history. A failed durable append prevents dispatch.
    public func append(entry: OperationRecord) throws {
        try ensureDirectoryExists()
        _ = try validatedEntries()
        var data = try JSONEncoder().encode(entry)
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: journalFile.path) {
            guard FileManager.default.createFile(atPath: journalFile.path, contents: nil) else {
                throw C1Error.invalidRequest("Cannot create operation journal.")
            }
        }
        let handle = try FileHandle(forWritingTo: journalFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if entry.status == "pending" { RequestContext.current?.linkOperation(entry.operationId) }
    }

    public func update(operationId: String, status: String, afterAdjustments: Adjustments? = nil,
                       diff: [String: DoubleDiff]? = nil, error: String? = nil, previewOutputPath: String? = nil, afterGeometry: Geometry? = nil, afterMetadata: VariantMetadata? = nil) throws {
        guard var entry = try validatedEntries().first(where: { $0.operationId == operationId }) else {
            throw C1Error.invalidRequest("Operation not found: \(operationId)")
        }
        entry.status = status
        if let value = afterMetadata { entry.afterMetadata = value }
        if let value = afterGeometry { entry.afterGeometry = value }
        if let value = afterAdjustments { entry.afterAdjustments = value }
        if let value = diff { entry.diff = value }
        if let value = error { entry.error = value }
        if let value = previewOutputPath { entry.previewOutputPath = value }
        try append(entry: entry)
    }

    public func find(operationId: String) -> OperationRecord? { loadEntries().first { $0.operationId == operationId } }
    public func unresolvedEntries() -> [OperationRecord] { loadEntries().filter(Self.isUnresolved) }
    public static func isUnresolved(_ entry: OperationRecord) -> Bool {
        ["pending", "partial-failure", "outcome-unknown"].contains(entry.status)
    }
    public func assertReady() throws {
        if let entry = try validatedEntries().first(where: Self.isUnresolved) {
            throw OperationFailure(operationId: entry.operationId, cause: C1Error.outcomeUnknown("An unresolved operation blocks further writes. Restart Capture One to end in-flight work, then inspect operation status."))
        }
    }
}
