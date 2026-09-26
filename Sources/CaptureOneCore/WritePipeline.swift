import Foundation

/// What one mutation kind supplies to the write pipeline: read its state from a
/// fresh observation, dispatch, and verify the readback. The pipeline owns every
/// guard around these steps; a kind never takes the lock, checks the document or
/// writes the journal itself.
protocol WriteKind {
    associatedtype State
    associatedtype Intended
    associatedtype Reply

    /// Journal operation type and the name used in guard messages.
    var operationType: String { get }
    /// Set when the kind is qualified only on the exact pinned build.
    var pinnedBuildRequirement: String? { get }
    /// Reported when the precondition token no longer matches.
    var staleMessage: String { get }

    /// The kind's state in a fresh observation, or nil when unavailable.
    func read(_ observation: GetResult) -> State?
    func token(_ state: State) -> String
    func plan(from before: State) throws -> Intended
    func dispatch(_ intended: Intended, before: State, to target: WriteTarget) throws -> Reply
    /// Pure: nil when the readback confirms the write, otherwise why it does not.
    func verify(before: Observed<State>, intended: Intended, reply: Reply, after: Observed<State>?) -> String?
    /// Kind-specific journal fields. `after` is nil before dispatch.
    func record(_ entry: inout OperationRecord, before: State, intended: Intended, after: State?)
}

struct Observed<State> {
    let observation: GetResult
    let state: State
}

/// The resolved native destination of one write.
struct WriteTarget {
    let documentId: String
    let variantId: String
    let parentImagePath: String
    let executor: ScriptExecuting
}

struct WriteOutcome<Kind: WriteKind> {
    let operationId: String
    let before: Kind.State
    let intended: Kind.Intended
    let isDryRun: Bool
}

/// A durable pending journal entry, which ends at most once. A failed append of
/// the ending leaves the entry pending, which still blocks further writes.
struct PendingWrite {
    enum Ending: String {
        case succeeded
        /// The readback was observed and differs from the intended write.
        case partialFailure = "partial-failure"
        /// Dispatch or its readback did not complete, so the native outcome is unknown.
        case outcomeUnknown = "outcome-unknown"
    }

    private(set) var entry: OperationRecord
    private let journal: OperationJournal

    /// A failed append here prevents dispatch.
    init(_ entry: OperationRecord, journal: OperationJournal) throws {
        precondition(entry.status == "pending")
        self.entry = entry
        self.journal = journal
        try journal.append(entry: entry)
    }

    mutating func update(_ change: (inout OperationRecord) -> Void) { change(&entry) }

    func end(_ ending: Ending, error: String? = nil) throws {
        var final = entry
        final.status = ending.rawValue
        final.error = error
        try journal.append(entry: final)
    }
}

extension SessionController {
    /// The whole guard sequence of one mutation. Never retries or undoes: a dispatch
    /// that may have run leaves a journal entry that blocks writes until reconciled.
    func write<Kind: WriteKind>(_ kind: Kind, workingRef: String, precondition: String, dryRun: Bool) throws -> WriteOutcome<Kind> {
        try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: kind.operationType)
            if let requirement = kind.pinnedBuildRequirement, doc.appVersion != Self.pinnedBuild {
                throw C1Error.unsupportedVersion(requirement)
            }
            try checkedDocument(doc, writes: !dryRun)
            let target = try adjustmentTarget(workingRef, document: doc)
            let current = try get(ref: workingRef)
            try assertWritableImage(doc: doc, source: current)
            guard current.id == target.variantId else {
                throw C1Error.identityAmbiguous("The reference resolved to a different native variant than its record.")
            }
            guard let before = kind.read(current), kind.token(before) == precondition else {
                throw C1Error.stateChanged(kind.staleMessage)
            }
            let intended = try kind.plan(from: before)
            if dryRun { return WriteOutcome(operationId: "dry-run", before: before, intended: intended, isDryRun: true) }

            var entry = try prepare(OperationRecord(operationType: kind.operationType, workingRef: workingRef,
                documentPath: doc.documentPath, preconditionStateHash: precondition,
                beforeAdjustments: current.adjustments, beforeGeometry: current.geometry), doc: doc, source: current)
            kind.record(&entry, before: before, intended: intended, after: nil)
            var pending = try PendingWrite(entry, journal: OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath)))
            let operationId = entry.operationId

            let reply: Kind.Reply, readback: GetResult
            do {
                reply = try kind.dispatch(intended, before: before, to: WriteTarget(documentId: doc.documentId,
                    variantId: target.variantId, parentImagePath: current.parentImagePath ?? "", executor: executor))
                try checkedDocument(doc, writes: false)
                readback = try get(ref: workingRef)
            } catch {
                try? pending.end(.outcomeUnknown, error: error.localizedDescription)
                throw OperationFailure(operationId: operationId, cause: error)
            }
            let after = kind.read(readback)
            pending.update {
                $0.afterAdjustments = readback.adjustments
                $0.afterGeometry = readback.geometry
                kind.record(&$0, before: before, intended: intended, after: after)
            }
            if let mismatch = kind.verify(before: Observed(observation: current, state: before), intended: intended,
                                          reply: reply, after: after.map { Observed(observation: readback, state: $0) }) {
                try? pending.end(.partialFailure, error: mismatch)
                throw OperationFailure(operationId: operationId, cause: C1Error.readbackMismatch(mismatch))
            }
            do { try pending.end(.succeeded) } catch { throw OperationFailure(operationId: operationId, cause: error) }
            return WriteOutcome(operationId: operationId, before: before, intended: intended, isDryRun: false)
        }
    }
}

/// Rating and color tag, verified against the native reply and an independent readback.
struct MetadataWrite: WriteKind {
    let rating: Int?
    let colorTag: Int?

    struct Reply: Decodable { let variantId: String; let ratingVal: Int; let colorTagVal: Int }

    var operationType: String { "metadata_set" }
    var pinnedBuildRequirement: String? { "Metadata writes require Capture One \(SessionController.pinnedBuild)." }
    var staleMessage: String { "Rating or color tag changed or is unavailable; read get again." }

    func read(_ observation: GetResult) -> VariantMetadata? { VariantMetadata.from(observation.metadata) }
    func token(_ state: VariantMetadata) -> String { state.stateHash }
    func plan(from before: VariantMetadata) -> VariantMetadata {
        VariantMetadata(rating: rating ?? before.rating, colorTag: colorTag ?? before.colorTag)
    }

    func dispatch(_ intended: VariantMetadata, before: VariantMetadata, to target: WriteTarget) throws -> Reply {
        try target.executor.executeAndDecode(handler: "applyMetadata", args: [
            NSAppleEventDescriptor(string: target.documentId), NSAppleEventDescriptor(string: target.variantId),
            rating.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
            colorTag.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
            NSAppleEventDescriptor(int32: Int32(before.rating)), NSAppleEventDescriptor(int32: Int32(before.colorTag)),
            NSAppleEventDescriptor(string: target.parentImagePath)])
    }

    func verify(before: Observed<VariantMetadata>, intended: VariantMetadata, reply: Reply,
                after: Observed<VariantMetadata>?) -> String? {
        let id = before.observation.id
        guard let after else { return "Rating or color tag is unreadable after the write." }
        guard reply.variantId == id, after.observation.id == id else { return "Metadata write reported a different variant." }
        guard reply.ratingVal == intended.rating, reply.colorTagVal == intended.colorTag, after.state == intended else {
            return "Metadata readback did not match: intended rating \(intended.rating) and color tag \(intended.colorTag), observed rating \(after.state.rating) and color tag \(after.state.colorTag)."
        }
        guard after.observation.stateHash == before.observation.stateHash,
              after.observation.geometryStateHash == before.observation.geometryStateHash else {
            return "Tone or geometry changed during the metadata write."
        }
        return nil
    }

    func record(_ entry: inout OperationRecord, before: VariantMetadata, intended: VariantMetadata, after: VariantMetadata?) {
        entry.beforeMetadata = before
        entry.intendedMetadata = intended
        entry.afterMetadata = after
        entry.diff = after?.changes(from: before)
    }
}
