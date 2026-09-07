import Foundation

public final class ProvenanceStore {
    public let sessionDirectory: URL
    public let storeFile: URL

    public init(sessionDirectory: URL) {
        self.sessionDirectory = sessionDirectory
        let c1Dir = sessionDirectory.appendingPathComponent(".c1", isDirectory: true)
        self.storeFile = c1Dir.appendingPathComponent("provenance.json")
    }

    private func ensureDirectoryExists() throws {
        let dir = storeFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func loadRecords() -> [String: ProvenanceRecord] {
        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: storeFile)
            let records = try JSONDecoder().decode([String: ProvenanceRecord].self, from: data)
            return records
        } catch {
            return [:]
        }
    }

    public func saveRecords(_ records: [String: ProvenanceRecord]) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        // Atomic write
        try data.write(to: storeFile, options: .atomic)
    }

    public func register(record: ProvenanceRecord) throws {
        var records = loadRecords()
        records[record.workingRef] = record
        try saveRecords(records)
    }

    public func find(workingRef: String) -> ProvenanceRecord? {
        let records = loadRecords()
        return records[workingRef]
    }

    public func find(byCloneId cloneId: String) -> ProvenanceRecord? {
        let records = loadRecords()
        return records.values.first { $0.cloneVariantId == cloneId }
    }

    public func remove(workingRef: String) throws {
        var records = loadRecords()
        records.removeValue(forKey: workingRef)
        try saveRecords(records)
    }

    public func allRecords() -> [ProvenanceRecord] {
        Array(loadRecords().values)
    }

    /// Validates that a reference is a managed working reference and belongs to the specified document path.
    public func resolveManagedWorkingReference(_ refString: String, currentDocumentPath: String) throws -> ProvenanceRecord {
        guard WorkingRef.isWorkingRefString(refString) else {
            throw C1Error.unmanagedVariant("Reference '\(refString)' is not a c1-managed working reference. The core rejects mutations to original variants or raw native IDs.")
        }
        guard let record = find(workingRef: refString) else {
            throw C1Error.unmanagedVariant("Working reference '\(refString)' has no provenance record in this Session.")
        }
        // Normalize paths for comparison
        let recPath = (record.documentPath as NSString).standardizingPath
        let curPath = (currentDocumentPath as NSString).standardizingPath
        guard recPath == curPath || recPath.contains(curPath) || curPath.contains(recPath) else {
            throw C1Error.documentChanged("Working reference '\(refString)' is bound to document '\(record.documentPath)', but current document is '\(currentDocumentPath)'.")
        }
        return record
    }
}
