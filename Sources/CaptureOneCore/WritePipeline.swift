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

    /// A fresh observation of the target; `afterDispatch` selects the readback.
    func observe(_ ref: String, afterDispatch: Bool, with core: SessionController) throws -> GetResult
    /// The kind's state in a fresh observation, or nil when unavailable.
    func read(_ observation: GetResult) -> State?
    /// Why the write is refused when `read` finds no state before dispatch.
    func unavailable(_ observation: GetResult) -> C1Error
    func token(_ state: State) -> String
    func plan(from before: State, target: WriteTarget, dryRun: Bool) throws -> Intended
    /// A throw means the native outcome is unknown.
    func dispatch(_ intended: Intended, before: Observed<State>, to target: WriteTarget) throws -> Reply
    /// Pure: nil when the readback confirms the write, otherwise why it does not.
    func verify(before: Observed<State>, intended: Intended, reply: Reply, after: Observed<State>) -> String?
    /// Kind-specific journal fields. `reply` and `after` are nil until observed.
    func record(_ entry: inout OperationRecord, before: State, intended: Intended, reply: Reply?, after: State?)
    /// The definite error for a dispatch error Capture One is qualified to raise
    /// without changing the target; nil keeps the outcome unknown.
    func refusal(_ error: Error) -> C1Error?
    /// Pure: true when a readback after a refusal shows the target exactly as before.
    func unchanged(before: Observed<State>, after: Observed<State>) -> Bool
}

extension WriteKind {
    var pinnedBuildRequirement: String? { nil }
    func observe(_ ref: String, afterDispatch: Bool, with core: SessionController) throws -> GetResult {
        try core.get(ref: ref)
    }
    func unavailable(_ observation: GetResult) -> C1Error { .stateChanged(staleMessage) }
    func refusal(_ error: Error) -> C1Error? { nil }
    func unchanged(before: Observed<State>, after: Observed<State>) -> Bool { false }
}

struct Observed<State> {
    let observation: GetResult
    let state: State
}

/// The resolved native destination of one write and the saved baseline of its reference.
struct WriteTarget {
    let documentId: String
    let workingRef: String
    let variantId: String
    let parentImagePath: String
    let baselineAdjustments: Adjustments
    let baselineGeometry: Geometry?
    let executor: ScriptExecuting
}

struct WriteOutcome<Kind: WriteKind> {
    let operationId: String
    let workingRef: String
    let before: Observed<Kind.State>
    let intended: Kind.Intended
    /// The verified readback; nil for a dry run.
    let after: Observed<Kind.State>?
    var isDryRun: Bool { after == nil }
}

/// What a dispatched write observed: its confirmed result, or a difference from the intent.
enum Readback<Value> {
    case confirmed(Value)
    case mismatch(C1Error)
}

/// A durable pending journal entry, which ends at most once. A failed append of
/// the ending leaves the entry pending, which still blocks further writes.
struct PendingWrite {
    enum Ending: String {
        case succeeded
        /// Capture One refused the write and the readback showed no change.
        case failed
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
    /// The guards every write shares before reading its target: the application
    /// lock, one active writable document on an allowed build, and no unresolved operation.
    func guarded<T>(_ operation: String, pinned requirement: String? = nil, dryRun: Bool = false,
                    _ body: (DocumentInfo) throws -> T) throws -> T {
        try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: operation)
            if let requirement, doc.appVersion != Self.pinnedBuild { throw C1Error.unsupportedVersion(requirement) }
            try checkedDocument(doc, writes: !dryRun)
            return try body(doc)
        }
    }

    /// Dispatches one write under a durable pending journal entry and classifies it.
    /// A throw from dispatch, the document re-check or the readback leaves the outcome
    /// unknown; an observed difference is a partial failure. Both block writes until
    /// reconciled after a restart; nothing is retried or undone. The one exception is
    /// a qualified refusal: when `refusal` recognises the dispatch error, the document
    /// is re-checked and `unchanged` must confirm from a fresh readback that nothing
    /// changed; the operation then resolves as failed. Other errors add no Apple Event.
    func journaled<Reply, Value>(_ entry: OperationRecord, doc: DocumentInfo, source: GetResult,
                                 dispatch: () throws -> Reply,
                                 readback: (inout PendingWrite, Reply) throws -> Readback<Value>,
                                 refusal: (Error) -> C1Error? = { _ in nil },
                                 unchanged: (inout PendingWrite) throws -> Bool = { _ in false }) throws -> (operationId: String, value: Value) {
        var prepared = entry
        prepared.compoundId = compoundId
        prepared.appInstance = try appInstance()
        prepared.documentIdentity = try databaseIdentity(databasePath(doc))
        prepared.nativeVariantId = source.id
        prepared.parentImagePath = source.parentImagePath
        var pending = try PendingWrite(prepared, journal: OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath)))
        let operationId = prepared.operationId
        let result: Readback<Value>
        do {
            let reply = try dispatch()
            try checkedDocument(doc, writes: false)
            result = try readback(&pending, reply)
        } catch {
            if let definite = refusal(error), (try? { try checkedDocument(doc, writes: false); return try unchanged(&pending) }()) == true {
                do { try pending.end(.failed, error: String(describing: error)) } catch { throw OperationFailure(operationId: operationId, cause: error) }
                throw definite
            }
            try? pending.end(.outcomeUnknown, error: String(describing: error))
            throw OperationFailure(operationId: operationId, cause: error)
        }
        switch result {
        case .mismatch(let error):
            try? pending.end(.partialFailure, error: String(describing: error))
            throw OperationFailure(operationId: operationId, cause: error)
        case .confirmed(let value):
            do { try pending.end(.succeeded) } catch { throw OperationFailure(operationId: operationId, cause: error) }
            return (operationId, value)
        }
    }

    /// The whole guard sequence of one mutation of an editing reference or managed clone.
    func write<Kind: WriteKind>(_ kind: Kind, workingRef: String, precondition: String, dryRun: Bool) throws -> WriteOutcome<Kind> {
        try guarded(kind.operationType, pinned: kind.pinnedBuildRequirement, dryRun: dryRun) { doc in
            let resolved = try adjustmentTarget(workingRef, document: doc)
            let current = try kind.observe(workingRef, afterDispatch: false, with: self)
            try assertWritableImage(doc: doc, source: current)
            guard current.id == resolved.variantId else {
                throw C1Error.identityAmbiguous("The reference resolved to a different native variant than its record.")
            }
            if let token = current.openToken, token != doc.openToken {
                throw C1Error.documentChanged("Active database changed while the write was prepared.")
            }
            guard let state = kind.read(current) else { throw kind.unavailable(current) }
            guard kind.token(state) == precondition else { throw C1Error.stateChanged(kind.staleMessage) }
            let before = Observed(observation: current, state: state)
            let target = WriteTarget(documentId: doc.documentId, workingRef: resolved.workingRef, variantId: resolved.variantId,
                parentImagePath: current.parentImagePath ?? "", baselineAdjustments: resolved.baselineAdjustments,
                baselineGeometry: resolved.baselineGeometry, executor: executor)
            let intended = try kind.plan(from: state, target: target, dryRun: dryRun)
            if dryRun {
                return WriteOutcome(operationId: "dry-run", workingRef: resolved.workingRef, before: before, intended: intended, after: nil)
            }

            var entry = OperationRecord(operationType: kind.operationType, workingRef: resolved.workingRef,
                documentPath: doc.documentPath, preconditionStateHash: precondition,
                beforeAdjustments: current.adjustments, beforeGeometry: current.geometry)
            kind.record(&entry, before: state, intended: intended, reply: nil, after: nil)
            /// The fresh post-dispatch observation, recorded in the pending entry; nil when unavailable.
            func observeAfter(_ pending: inout PendingWrite, reply: Kind.Reply?) throws -> Observed<Kind.State>? {
                let readback = try kind.observe(workingRef, afterDispatch: true, with: self)
                let after = kind.read(readback)
                pending.update {
                    $0.afterAdjustments = readback.adjustments
                    $0.afterGeometry = readback.geometry
                    kind.record(&$0, before: state, intended: intended, reply: reply, after: after)
                }
                guard readback.id == resolved.variantId, let after else { return nil }
                return Observed(observation: readback, state: after)
            }
            let (operationId, after) = try journaled(entry, doc: doc, source: current,
                dispatch: { try kind.dispatch(intended, before: before, to: target) },
                readback: { (pending: inout PendingWrite, reply: Kind.Reply) -> Readback<Observed<Kind.State>> in
                    pending.update { kind.record(&$0, before: state, intended: intended, reply: reply, after: nil) }
                    guard let observed = try observeAfter(&pending, reply: reply) else {
                        return .mismatch(.readbackMismatch("The \(kind.operationType) readback is unavailable after the write."))
                    }
                    if let mismatch = kind.verify(before: before, intended: intended, reply: reply, after: observed) {
                        return .mismatch(.readbackMismatch(mismatch))
                    }
                    return .confirmed(observed)
                },
                refusal: kind.refusal,
                unchanged: { (pending: inout PendingWrite) -> Bool in
                    guard let observed = try observeAfter(&pending, reply: nil) else { return false }
                    return kind.unchanged(before: before, after: observed)
                })
            return WriteOutcome(operationId: operationId, workingRef: resolved.workingRef, before: before, intended: intended, after: after)
        }
    }
}
