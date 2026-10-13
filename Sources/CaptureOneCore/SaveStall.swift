import Foundation

/// Capture One acknowledges a write live and saves its database later. A database file
/// not modified since a write was dispatched has not saved that write. Once the oldest such
/// write in the running Capture One process has waited `stallSeconds`, saving has stalled
/// (#43): Capture One can lose those writes for good, even when the document closes.
public enum SaveStall {
    public static let stallSeconds: TimeInterval = 300

    /// Every unsaved write of `appInstance` once one has waited `stallSeconds`; otherwise none.
    /// A write is unsaved when it succeeded, or was reconciled behind the probe barrier, changed
    /// the variant and was dispatched after the database was last modified. The journal records dispatch time to the second, so a save
    /// within that second counts as saving the write; the next write still exposes a stall.
    /// `databaseModified` is read only when some write is old enough to have stalled.
    public static func stalled(_ entries: [OperationRecord], appInstance: String, now: Date,
                               databaseModified: () throws -> Date) throws -> [OperationRecord] {
        let candidates = entries.compactMap { entry -> (OperationRecord, Date)? in
            guard entry.status == "succeeded" || (entry.status == "reconciled" && entry.resolution == .probeBarrier),
                  entry.appInstance == appInstance, changesDatabase(entry),
                  let dispatched = dispatchDate(entry) else { return nil }
            return (entry, dispatched)
        }
        guard candidates.contains(where: { now.timeIntervalSince($0.1) >= stallSeconds }) else { return [] }
        let modified = try databaseModified()
        let unsaved = candidates.filter { modified < $0.1 }
        guard unsaved.contains(where: { now.timeIntervalSince($0.1) >= stallSeconds }) else { return [] }
        return unsaved.map(\.0)
    }

    public static func changesDatabase(_ entry: OperationRecord) -> Bool {
        if entry.status == "reconciled" { return observedChange(entry) }
        switch entry.operationType {
        case "preview": return false
        case "clone", "baseline", "delete": return true
        case "native": return entry.beforeNative != entry.afterNative
        default: return !(entry.diff ?? [:]).isEmpty
        }
    }

    /// A reconciled write has no dispatch diff; compare what status observed with the before state.
    /// A delete counts as a change, since an absent variant leaves nothing to compare.
    static func observedChange(_ entry: OperationRecord) -> Bool {
        switch entry.operationType {
        case "preview": return false
        case "clone", "baseline": return !(entry.observedVariantIds ?? []).isEmpty
        case "delete": return true
        case "native": return entry.beforeNative != entry.afterNative
        default:
            return entry.afterAdjustments != entry.beforeAdjustments || entry.afterGeometry != entry.beforeGeometry
                || (entry.beforeMetadata != nil && entry.afterMetadata != entry.beforeMetadata)
        }
    }

    public static func dispatchDate(_ entry: OperationRecord) -> Date? {
        ISO8601DateFormatter().date(from: entry.timestamp)
    }

    /// When SQLite last wrote the database: the main file, or its write-ahead log in WAL mode.
    /// A rollback journal appears when a transaction starts and proves no save.
    public static func databaseModified(_ path: String) throws -> Date {
        let dates = [path, path + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        guard let latest = dates.max() else {
            throw C1Error.identityAmbiguous("Cannot read the database modification time: \(path)")
        }
        return latest
    }
}

extension SessionController {
    /// Marks this Capture One process's unsaved writes `outcome-unknown` once saving has stalled,
    /// so every write stays blocked until a restart and `operation_status` reconciliation.
    /// Call under the application lock.
    func recordSaveStall(_ doc: DocumentInfo) throws {
        let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
        let now = now()
        var modified: Date?
        let stalled = try SaveStall.stalled(try journal.validatedEntries(), appInstance: try appInstance(), now: now) {
            let date = try databaseModified(databasePath(doc))
            modified = date
            return date
        }
        guard let modified else { return }
        let formatter = ISO8601DateFormatter()
        for var entry in stalled {
            let age = Int(now.timeIntervalSince(SaveStall.dispatchDate(entry) ?? now))
            entry.status = "outcome-unknown"
            entry.saveStalledAt = formatter.string(from: now)
            entry.error = "Capture One acknowledged this write \(age) s ago and has not saved the database since \(formatter.string(from: modified)). It can lose unsaved writes for good. Restart Capture One, reopen the document, then inspect operation status."
            try journal.append(entry: entry)
        }
    }
}
