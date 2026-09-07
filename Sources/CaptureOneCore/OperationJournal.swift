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
    public let timestamp: String
    public let operationType: String
    public let workingRef: String?
    public let documentPath: String
    public let preconditionStateHash: String?
    public let intendedAdjustments: Adjustments?
    public let beforeAdjustments: Adjustments?
    public var afterAdjustments: Adjustments?
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
        previewOutputPath: String? = nil
    ) {
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

    public func loadEntries() -> [OperationRecord] {
        guard FileManager.default.fileExists(atPath: journalFile.path),
              let content = try? String(contentsOf: journalFile, encoding: .utf8) else {
            return []
        }
        var entries: [OperationRecord] = []
        let decoder = JSONDecoder()
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let data = trimmed.data(using: .utf8),
               let record = try? decoder.decode(OperationRecord.self, from: data) {
                entries.append(record)
            }
        }
        return entries
    }

    public func append(entry: OperationRecord) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: journalFile.path) {
            if let handle = try? FileHandle(forWritingTo: journalFile) {
                handle.seekToEndOfFile()
                if let lineData = line.data(using: .utf8) {
                    handle.write(lineData)
                }
                try? handle.close()
            }
        } else {
            try line.write(to: journalFile, atomically: true, encoding: .utf8)
        }
    }

    public func update(
        operationId: String,
        status: String,
        afterAdjustments: Adjustments? = nil,
        diff: [String: DoubleDiff]? = nil,
        error: String? = nil,
        previewOutputPath: String? = nil
    ) throws {
        var entries = loadEntries()
        guard let idx = entries.firstIndex(where: { $0.operationId == operationId }) else {
            return
        }
        entries[idx].status = status
        if let after = afterAdjustments { entries[idx].afterAdjustments = after }
        if let d = diff { entries[idx].diff = d }
        if let err = error { entries[idx].error = err }
        if let pop = previewOutputPath { entries[idx].previewOutputPath = pop }

        // Rewrite entire journal atomically
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        var fullContent = ""
        for entry in entries {
            let data = try encoder.encode(entry)
            if let line = String(data: data, encoding: .utf8) {
                fullContent += line + "\n"
            }
        }
        try fullContent.write(to: journalFile, atomically: true, encoding: .utf8)
    }

    public func find(operationId: String) -> OperationRecord? {
        loadEntries().first { $0.operationId == operationId }
    }

    public func unresolvedEntries() -> [OperationRecord] {
        loadEntries().filter {
            $0.status == "pending" || $0.status == "partial-failure" || $0.status == "outcome-unknown"
        }
    }
}
