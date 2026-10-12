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
    public var compoundId: String?
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
    /// Preview only: the geometry token a late export must still match to resolve without a restart.
    public var preconditionGeometryStateHash: String?
    public var intendedAdjustments: Adjustments?
    public let beforeAdjustments: Adjustments?
    public var afterAdjustments: Adjustments?
    public var beforeNative: NativeSnapshot?
    public var afterNative: NativeSnapshot?
    public var nativePatch: [String: NativeValue]?
    public var nativeAction: String?
    public var beforeMetadata: VariantMetadata?
    public var intendedMetadata: VariantMetadata?
    public var afterMetadata: VariantMetadata?
    public var beforeGeometry: Geometry?
    public var intendedGeometry: Geometry?
    public var requestedGeometry: GeometryRequest?
    public var afterGeometry: Geometry?
    public var diff: [String: DoubleDiff]?
    public var status: String // "pending", "succeeded", "failed", "partial-failure", "outcome-unknown", "reconciled"
    /// How operation status ended the operation without a restart; only `late-preview`.
    public var resolution: String?
    public var error: String?
    public var previewOutputPath: String?
    public var previewSize: Int?
    /// Clone and baseline only: the current album Capture One put the new variant in and c1 removed it from.
    public var removedFromAlbum: String?

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
        try PerformanceTrace.measure("journal_read", handler: "OperationJournal.validatedEntries") {
            try JournalCache.shared.read(journalFile)
        }
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
        try PerformanceTrace.measure("journal_fsync", handler: "OperationJournal.append") { try handle.synchronize() }
        if entry.status == "pending" { RequestContext.current?.linkOperation(entry.operationId) }
    }

    public func find(operationId: String) -> OperationRecord? { loadEntries().first { $0.operationId == operationId } }
    public func unresolvedEntries() -> [OperationRecord] { loadEntries().filter(Self.isUnresolved) }
    public static func isUnresolved(_ entry: OperationRecord) -> Bool {
        ["pending", "partial-failure", "outcome-unknown"].contains(entry.status)
    }
    public func assertReady() throws {
        if let entry = try validatedEntries().first(where: Self.isUnresolved) {
            let action = entry.operationType == "preview"
                ? "Inspect operation status once its JPEG has landed; a complete preview resolves without a restart, otherwise restart Capture One first."
                : "Restart Capture One to end in-flight work, then inspect operation status."
            throw OperationFailure(operationId: entry.operationId, cause: C1Error.outcomeUnknown("An unresolved operation blocks further writes. " + action))
        }
    }
}

/// The reduced journal as of `decodedOffset`, which always follows a newline. Each process
/// validates the whole file on its first read; later reads decode only appended bytes while
/// the file identity and the bytes before the offset are unchanged. An in-place rewrite that
/// keeps the inode, the length up to the offset and those last bytes goes unnoticed until the
/// next process start.
private struct JournalView {
    static let tailLength = 4096

    let device: UInt64
    let inode: UInt64
    var decodedOffset = 0
    var tail = Data()
    var entries: [OperationRecord] = []
    var position: [String: Int] = [:]

    /// Folds `bytes` through their last newline and returns the entries including any
    /// unterminated last line, which stays outside the view to be decoded again. A throw
    /// leaves the view partly folded, so the caller must discard it.
    mutating func fold(_ bytes: Data) throws -> [OperationRecord] {
        let end = bytes.lastIndex(of: 0x0a).map { $0 + 1 } ?? bytes.startIndex
        let complete = bytes[..<end]
        try apply(complete)
        decodedOffset += complete.count
        tail = Data(tail.suffix(max(0, Self.tailLength - complete.count)) + complete.suffix(Self.tailLength))
        let trailing = bytes[end...]
        if trailing.isEmpty { return entries }
        var withTrailing = self
        try withTrailing.apply(trailing)
        return withTrailing.entries
    }

    private mutating func apply(_ bytes: Data) throws {
        guard let content = String(data: bytes, encoding: .utf8) else {
            throw C1Error.invalidRequest("Journal is not UTF-8; preserve it for recovery.")
        }
        for line in content.split(separator: "\n") {
            let record = try JSONDecoder().decode(OperationRecord.self, from: Data(line.utf8))
            if let index = position[record.operationId] {
                entries[index] = record
            } else {
                position[record.operationId] = entries.count
                entries.append(record)
            }
        }
    }
}

private final class JournalCache {
    static let shared = JournalCache()
    private let lock = NSLock()
    private var views: [String: JournalView] = [:]

    func read(_ file: URL) throws -> [OperationRecord] {
        let key = file.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: key) else { return [] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw C1Error.invalidRequest("Cannot inspect the operation journal; preserve it for recovery.")
        }
        lock.lock()
        defer { lock.unlock() }
        let fresh = JournalView(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        // Removed rather than copied, so folding mutates the only reference instead of copying history.
        var view = views.removeValue(forKey: key).flatMap { $0.device == fresh.device && $0.inode == fresh.inode ? $0 : nil } ?? fresh
        try handle.seek(toOffset: UInt64(view.decodedOffset - view.tail.count))
        var bytes = try handle.readToEnd() ?? Data()
        if bytes.prefix(view.tail.count) == view.tail {
            bytes = bytes.dropFirst(view.tail.count)
        } else {
            view = fresh
            try handle.seek(toOffset: 0)
            bytes = try handle.readToEnd() ?? Data()
        }
        let entries = try view.fold(bytes)
        views[key] = view
        return entries
    }
}
