import Foundation
import CryptoKit

/// Optional browsing acceleration. Never called by mutation or recovery code.
/// State is disposable; the existing journal and native readback remain authoritative.
public final class ReadWorkflow {
    public static let shared = ReadWorkflow()
    private static let defaultPointer = URL(fileURLWithPath: "/private/tmp/c1-read-workflow-\(getuid()).active")
    private let pointer: URL
    private let core: SessionController
    private let now: () -> Double
    private let requestedWorkflowID: () -> String?
    public init(core: SessionController = .shared, now: @escaping () -> Double = { Date().timeIntervalSince1970 }, indexURL: URL? = nil, workflowID: @escaping () -> String? = { ProcessInfo.processInfo.environment["C1_READ_WORKFLOW"] }) {
        self.core = core; self.now = now; self.pointer = indexURL ?? Self.defaultPointer; self.requestedWorkflowID = workflowID
    }
    struct Item: Codable {
        var summary: VariantSummary
        var value: GetResult?
        var confirmedAt: Double
        var checkAfter: Double
        var metadataInSQL = false
        var tonalInSQL = false
    }
    struct State: Codable {
        var version = 1
        var id = UUID().uuidString.lowercased()
        var document: DocumentInfo
        var collection: String?
        var selected: Bool
        var active = true
        var reason: String?
        var journal: [String: String]
        var items: [Item]
        var sqlite: Bool
    }
    private func file(_ doc: DocumentInfo) -> URL {
        URL(fileURLWithPath: doc.documentPath).appendingPathComponent(".c1/read-workflow.json")
    }
    private func save(_ state: State) throws {
        let url = file(state.document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    private func load(_ doc: DocumentInfo) throws -> State? {
        guard FileManager.default.fileExists(atPath: file(doc).path) else { return nil }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: file(doc))), state.version == 1 else {
            // Corrupt optimization state cannot affect native safety paths.
            try? FileManager.default.removeItem(at: file(doc)); return nil
        }
        return state
    }
    private func entries(_ doc: DocumentInfo) throws -> [OperationRecord] {
        try OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath)).validatedEntries()
    }
    static func digest(_ entry: OperationRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(entry)).map { String(format: "%02x", $0) }.joined()
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    public static func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!
    }
    private func validateEnd(_ doc: DocumentInfo) throws {
        let current = try core.getDocumentInfo()
        guard current.openToken == doc.openToken, current.documentId == doc.documentId else {
            throw C1Error.documentChanged("Document changed during browsing; discard the result.")
        }
    }
    public func begin(collection: String? = nil, selected: Bool = false) throws -> [String: Any] {
        try CaptureOneLock.shared.withLock {
            let doc = try core.getDocumentInfo()
            // Explicit handoff: discard any previous baseline before acquiring a new one.
            try? FileManager.default.removeItem(at: file(doc))
            let journal = try entries(doc)
            guard !journal.contains(where: OperationJournal.isUnresolved) else {
                throw C1Error.invalidRequest("Resolve uncertain operations before starting a browsing workflow.")
            }
            let inventory = try core.listVariants(collectionName: collection, selectedOnly: selected)
            guard inventory.count <= 10000 else { throw C1Error.invalidRequest("Read workflows support at most 10000 variants per scope.") }
            var state = State(document: doc, collection: collection, selected: selected,
                              journal: try Dictionary(uniqueKeysWithValues: journal.map { ($0.operationId, try Self.digest($0)) }),
                              items: inventory.map { Item(summary: $0, confirmedAt: now(), checkAfter: 0) }, sqlite: !doc.isSession)
            if state.sqlite {
                do { try reconcileSQL(&state) }
                catch { state.sqlite = false; state.reason = "SQLite projection unavailable; using native-confirmed browsing cache." }
            }
            try validateEnd(doc)
            try save(state)
            try Data(doc.documentPath.utf8).write(to: pointer, options: .atomic)
            return status(state)
        }
    }
    public func end(workflowID: String? = nil) throws -> [String: Any] {
        guard let expected = workflowID ?? requestedWorkflowID() else { throw C1Error.invalidRequest("Supply the read workflow ID to end the handoff.") }
        return try CaptureOneLock.shared.withLock {
            guard let path = try? String(contentsOf: pointer, encoding: .utf8) else { return ["active": false] }
            let url = URL(fileURLWithPath: path).appendingPathComponent(".c1/read-workflow.json")
            guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: url)), state.id == expected else {
                throw C1Error.invalidRequest("Read workflow ID does not match the current handoff.")
            }
            try FileManager.default.removeItem(at: url)
            try FileManager.default.removeItem(at: pointer)
            return ["active": false, "reason": "Handoff to photographer; native reads restored."]
        }
    }
    private func status(_ state: State) -> [String: Any] {
        ["active": state.active, "workflowId": state.id, "documentPath": state.document.documentPath,
         "variantCount": state.items.count, "sqliteEnabled": state.sqlite,
         "pendingVariantCount": state.items.filter { !$0.metadataInSQL || ($0.value != nil && !$0.tonalInSQL) }.count,
         "catchUpIntervalSeconds": 60, "reason": state.reason ?? "Exclusive c1 workflow; end before UI edits."]
    }
    public func status(workflowID: String? = nil) throws -> [String: Any] {
        guard let expected = workflowID ?? requestedWorkflowID() else { return ["active": false] }
        guard FileManager.default.fileExists(atPath: pointer.path) else { return ["active": false] }
        return try CaptureOneLock.shared.withLock {
            let doc = try core.getDocumentInfo()
            guard var state = try load(doc), state.id == expected else { return ["active": false] }
            try synchronize(&state, doc: doc)
            try save(state)
            return status(state)
        }
    }
    static func apply(_ records: [OperationRecord], to state: inout State, at time: Double) throws {
        guard Set(state.journal.keys).isSubset(of: Set(records.map(\.operationId))) else {
            state.active = false; state.reason = "Journal history was removed."; return
        }
        for record in records {
            let hash = try digest(record)
            if state.journal[record.operationId] == hash { continue }
            state.journal[record.operationId] = hash
            guard record.status == "succeeded", record.appInstance != nil, record.documentIdentity != nil, "\(record.appInstance!)|\(record.documentIdentity!)" == state.document.openToken else {
                state.active = false; state.reason = "Uncertain, failed, or differently bound operation; establish a new native baseline."; return
            }
            // Structural, export, native-action and geometry effects are broader than
            // the qualified metadata/tonal projection; never infer their scope.
            guard ["set", "add", "reset", "metadata_set"].contains(record.operationType) else {
                state.active = false; state.reason = "Operation \(record.operationType) invalidated the browsing scope; begin again."; return
            }
            guard let id = record.nativeVariantId else {
                state.active = false; state.reason = "Operation has no verified variant identity."; return
            }
            guard let index = state.items.firstIndex(where: { $0.summary.id == id }) else { continue }
            var item = state.items[index]
            guard record.parentImagePath == item.summary.parentImagePath else {
                state.active = false; state.reason = "Variant parent identity changed."; return
            }
            if record.operationType == "metadata_set" {
                guard let metadata = record.afterMetadata else { state.active = false; state.reason = "Missing native metadata readback."; return }
                let old = item.summary
                item.summary = VariantSummary(id: old.id, name: old.name, parentImagePath: old.parentImagePath,
                    isSelected: old.isSelected, rating: metadata.rating, colorTag: metadata.colorTag,
                    isManagedWorkingClone: old.isManagedWorkingClone, workingRef: old.workingRef)
                if let value = item.value {
                    var fields = value.metadata; fields.rating = metadata.rating; fields.colorTag = metadata.colorTag
                    item.value = copy(value, metadata: fields)
                }
                item.metadataInSQL = false
            } else {
                guard let adjustments = record.afterAdjustments else { state.active = false; state.reason = "Missing native adjustment readback."; return }
                if let value = item.value { item.value = copy(value, adjustments: adjustments) }
                item.tonalInSQL = false
            }
            // The journal timestamp is dispatch time, not completion. Starting at
            // first observation of success is conservative and needs no journal change.
            item.confirmedAt = time; item.checkAfter = time + 60
            state.items[index] = item
        }
    }
    private static func copy(_ old: GetResult, adjustments: Adjustments? = nil, metadata: Metadata? = nil) -> GetResult {
        GetResult(geometry: old.geometry, geometryUsableBounds: old.geometryUsableBounds,
                  geometryUnavailableReason: old.geometryUnavailableReason, id: old.id, workingRef: old.workingRef,
                  adjustments: adjustments ?? old.adjustments, metadata: metadata ?? old.metadata,
                  stateHash: "", parentImagePath: old.parentImagePath)
    }
    private func synchronize(_ state: inout State, doc: DocumentInfo) throws {
        guard state.active else { return }
        guard state.document.openToken == doc.openToken, state.document.documentId == doc.documentId else {
            state.active = false; state.reason = "Application or database identity changed."; return
        }
        do { try Self.apply(entries(doc), to: &state, at: now()) }
        catch { state.active = false; state.reason = "Journal could not be validated." }
    }
    private func reconcileSQL(_ state: inout State) throws {
        guard state.sqlite else { return }
        let location = try CatalogLocation(nativeID: state.document.documentId, readOnly: true)
        let records = try CatalogReader(database: location.database.path).readProjection()
        let byID = Dictionary(uniqueKeysWithValues: records.map { (String($0.id), $0) })
        for index in state.items.indices {
            var item = state.items[index]
            guard let row = byID[item.summary.id], let path = row.path,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: item.summary.parentImagePath).resolvingSymlinksInPath().standardizedFileURL,
                  row.name == item.summary.name else {
                if item.metadataInSQL || item.tonalInSQL {
                    throw C1Error.stateChanged("Stored variant identity diverged from the controlled workflow.")
                }
                continue
            }
            let check = now() >= item.checkAfter
            let metadataMatch = row.rating == item.summary.rating && row.colorTag == item.summary.colorTag
            if item.metadataInSQL && !metadataMatch {
                throw C1Error.stateChanged("Stored metadata diverged from the controlled workflow.")
            }
            if check { item.metadataInSQL = metadataMatch }
            if let value = item.value {
                let tonalMatch = [(row.exposure, value.adjustments.exposure), (row.contrast, value.adjustments.contrast),
                                  (row.saturation, value.adjustments.saturation)].allSatisfy { a, b in
                    guard let a, let b else { return false }; return abs(a-b) <= 0.0001
                }
                if item.tonalInSQL && !tonalMatch { throw C1Error.stateChanged("Stored adjustments diverged from the controlled workflow.") }
                if check { item.tonalInSQL = tonalMatch }
                if item.tonalInSQL {
                    var adjustments = value.adjustments
                    adjustments.exposure = row.exposure; adjustments.contrast = row.contrast; adjustments.saturation = row.saturation
                    item.value = Self.copy(value, adjustments: adjustments)
                }
            }
            // Values are only admitted from SQL after agreement with native-confirmed
            // state. Other fields (WB conversion, geometry, selection) stay native-cached.
            if item.metadataInSQL {
                let old = item.summary
                item.summary = VariantSummary(id: old.id, name: old.name, parentImagePath: old.parentImagePath,
                    isSelected: old.isSelected, rating: row.rating!, colorTag: row.colorTag!,
                    isManagedWorkingClone: old.isManagedWorkingClone, workingRef: old.workingRef)
            }
            if check { item.checkAfter = now() + 60 }
            state.items[index] = item
        }
    }
    private func observation(_ state: State, _ item: Item) -> [String: Any] {
        ["workflowId": state.id, "backend": item.metadataInSQL || item.tonalInSQL ? "sqlite+native-cache" : "native-cache",
         "nativeConfirmedAt": item.confirmedAt, "metadataInSQLite": item.metadataInSQL, "tonalInSQLite": item.tonalInSQL,
         "mutationTokensAvailable": false]
    }
    private func browsing(_ state: State, _ item: Item) throws -> [String: Any] {
        var result = try Self.object(item.value!)
        for key in ["stateHash", "metadataStateHash", "geometryStateHash", "openToken", "nativeSnapshots"] { result.removeValue(forKey: key) }
        result["readObservation"] = observation(state, item)
        return result
    }
    private func value(_ id: String, state: inout State) throws -> Item? {
        guard let index = state.items.firstIndex(where: { $0.summary.id == id }) else { return nil }
        if state.items[index].value == nil {
            let value = try core.get(ref: id)
            guard value.id == id, value.parentImagePath == state.items[index].summary.parentImagePath,
                  value.metadata.rating == state.items[index].summary.rating, value.metadata.colorTag == state.items[index].summary.colorTag else {
                throw C1Error.stateChanged("Native state diverged from the browsing baseline.")
            }
            state.items[index].value = value; state.items[index].confirmedAt = now()
        }
        return state.items[index]
    }
    private func route<T>(workflowID: String?, _ body: (inout State) throws -> T?) throws -> T? {
        guard let expected = workflowID ?? requestedWorkflowID(), FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        return try CaptureOneLock.shared.withLock {
            let doc = try core.getDocumentInfo()
            guard (try? String(contentsOf: pointer, encoding: .utf8)) == doc.documentPath else {
                try? FileManager.default.removeItem(at: pointer); return nil
            }
            guard var state = try load(doc), state.id == expected else { return nil }
            try synchronize(&state, doc: doc)
            guard state.active else { try save(state); return nil }
            do {
                try RequestContext.current?.checkReadCancellation()
                try reconcileSQL(&state)
                let result = try body(&state)
                try validateEnd(doc)
                try RequestContext.current?.checkReadCancellation()
                try save(state)
                return result
            } catch let error as C1Error {
                state.active = false; state.reason = "Native fallback: \(error)"; try? save(state)
                if error.errorCode == "request-cancelled" || error.errorCode == "document-changed" { throw error }
                return nil
            } catch {
                state.active = false; state.reason = "Read cache unavailable; native fallback."; try? save(state)
                return nil
            }
        }
    }
    public func variants(collection: String?, selected: Bool, rating: Int?, minRating: Int?, workflowID: String? = nil) throws -> [[String: Any]]? {
        var args: [String: Any] = [:]; if let rating { args["rating"] = rating }; if let minRating { args["minRating"] = minRating }
        try ContractSchema.validate(tool: "variants_list", arguments: args)
        return try route(workflowID: workflowID) { state in
            guard state.collection == collection, state.selected == selected else { return nil }
            RequestContext.current?.inventoryStrategy("catalog-workflow-overlay")
            // Filter AFTER overlaying every journaled metadata change, including
            // variants absent from the SQLite rating-filtered candidate set.
            return try state.items.filter { (rating == nil || $0.summary.rating == rating!) && (minRating == nil || $0.summary.rating >= minRating!) }.map {
                var result = try Self.object($0.summary); result["readObservation"] = observation(state, $0); return result
            }
        }
    }
    public func get(ref: String, workflowID: String? = nil) throws -> [String: Any]? {
        guard !EditingRecord.isEditingReference(ref), !WorkingRef.isWorkingRefString(ref) else { return nil }
        return try route(workflowID: workflowID) { state in
            guard let item = try value(ref, state: &state) else { return nil }
            return try browsing(state, item)
        }
    }
    public func dump(collection: String?, selected: Bool, workflowID: String? = nil) throws -> [[String: Any]]? {
        try route(workflowID: workflowID) { state in
            guard state.collection == collection, state.selected == selected else { return nil }
            var result: [[String: Any]] = []
            for id in state.items.map({ $0.summary.id }) {
                try RequestContext.current?.checkReadCancellation()
                guard let item = try value(id, state: &state) else { return nil }
                var record = try Self.object(item.summary)
                record.merge(try browsing(state, item)) { _, value in value }
                result.append(record)
            }
            return result
        }
    }
    public func diff(ref1: String, ref2: String?, workflowID: String? = nil) throws -> [String: Any]? {
        guard let ref2, ![ref1, ref2].contains(where: { EditingRecord.isEditingReference($0) || WorkingRef.isWorkingRefString($0) }) else { return nil }
        return try route(workflowID: workflowID) { state in
            guard let a = try value(ref1, state: &state), let b = try value(ref2, state: &state), let av = a.value, let bv = b.value else { return nil }
            let result = DiffResult(ref1: ref1, ref2: ref2, stateHash1: "", stateHash2: "", diff: core.computeDiff(before: av.adjustments, after: bv.adjustments),
                                    geometryBefore: av.geometry, geometryAfter: bv.geometry,
                                    metadataBefore: VariantMetadata.from(av.metadata), metadataAfter: VariantMetadata.from(bv.metadata))
            var object = try Self.object(result); object.removeValue(forKey: "stateHash1"); object.removeValue(forKey: "stateHash2")
            object["readObservation"] = observation(state, b); return object
        }
    }
}
