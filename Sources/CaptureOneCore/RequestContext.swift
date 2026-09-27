import Foundation
import CryptoKit

/// Best-effort diagnostics only. This is deliberately separate from the durable mutation journal.
public struct RequestSnapshot: Codable, Sendable {
    public var requestId: String
    public var tool: String
    public var processId: Int32
    public var startedAt: Double
    public var updatedAt: Double
    public var phase = "validating"
    public var status = "running"
    public var elapsedMs = 0
    public var lastProgressAgoMs: Int?
    /// Bounded rows read in the first pass. Revalidation rows are counted separately.
    public var candidatesScanned = 0
    /// Matches confirmed by the final revalidation; first-pass matches are `unconfirmedMatches`.
    public var matchesFound = 0
    /// 1 while reading, 2 while revalidating what the first pass observed.
    public var pass: Int?
    public var unconfirmedMatches: Int?
    public var revalidatedRows: Int?
    public var summariesCompleted = 0
    public var totalCandidates: Int?
    public var documentIdentity: String?
    public var scope: String?
    public var inventoryStrategy: String?
    public var rating: Int?
    public var minRating: Int?
    public var operationId: String?
    public var handler: String?
    public var handlerCalls = 0
    public var slow = false
    public var waitingForAppleEvent = false
    public var applicationProgress = "unknown"
    public var processAlive: Bool?
    public var stale: Bool?
    /// Set once a cancellation arrives; the request still ends at its next safe boundary.
    public var cancelRequested: Bool?
    /// Terminal error, redacted like the rest of these diagnostics.
    public var errorCode: String?
    public var errorMessage: String?
    public var missingIds: [String]?
    public var outOfScopeIds: [String]?

    /// Removes paths and quoted names from an error message; quoted IDs and references stay.
    public static func redacted(_ message: String) -> String {
        var text = message
        let keep = try! NSRegularExpression(pattern: #"^(\d+|c1_[A-Za-z0-9_-]+|req-[0-9A-Fa-f-]{36}|[0-9A-Fa-f-]{32,64})$"#)
        let quoted = try! NSRegularExpression(pattern: #"'[^'\n]*'|"[^"\n]*"|“[^”\n]*”"#)
        for match in quoted.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let range = Range(match.range, in: text)!
            let inner = String(text[range].dropFirst().dropLast())
            if keep.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)) == nil {
                text.replaceSubrange(range, with: "\(text[range].first!)…\(text[range].last!)")
            }
        }
        // An unquoted path may contain spaces, so everything after its start is dropped.
        let path = try! NSRegularExpression(pattern: #"(^|[\s:(=])(~?/)[^'"“”]*"#)
        return path.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1<path>")
    }
}

public final class RequestContext: @unchecked Sendable {
    private static let threadKey = "c1.request-context"
    public static var current: RequestContext? { Thread.current.threadDictionary[threadKey] as? RequestContext }
    public func withCurrent<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[Self.threadKey]
        Thread.current.threadDictionary[Self.threadKey] = self
        defer { Thread.current.threadDictionary[Self.threadKey] = previous }
        return try body()
    }

    private let mutex = NSLock()
    private let outputQueue: DispatchQueue
    private var state: RequestSnapshot
    private let start = ProcessInfo.processInfo.systemUptime
    private var lastProgress: Double?
    private var cancelled = false
    private var timer: DispatchSourceTimer?
    private let directory: URL?
    private let diagnostics: Bool
    private let slowThreshold: Double
    private let progressMode: String
    private let observer: (@Sendable (RequestSnapshot) -> Void)?
    private var lastEmission: Double = 0
    private var terminalEmitted = false

    public init(tool: String, progressMode: String? = nil, directory: URL? = RequestContext.defaultDirectory,
                observer: (@Sendable (RequestSnapshot) -> Void)? = nil, heartbeatSeconds: Double = 5) {
        let now = Date().timeIntervalSince1970
        let id = "req-" + UUID().uuidString.lowercased()
        state = RequestSnapshot(requestId: id, tool: tool, processId: getpid(), startedAt: now, updatedAt: now)
        outputQueue = DispatchQueue(label: "c1.diagnostics.\(id)", qos: .utility)
        self.directory = directory
        self.observer = observer
        let env = ProcessInfo.processInfo.environment
        diagnostics = env["C1_DIAGNOSTICS"] == "1"
        let threshold = env["C1_SLOW_REQUEST_SECONDS"].flatMap(Double.init) ?? 10
        slowThreshold = threshold.isFinite && threshold > 0 ? threshold : 10
        self.progressMode = progressMode ?? env["C1_PROGRESS"] ?? (isatty(STDERR_FILENO) == 1 ? "human" : "quiet")
        emit(force: true)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.05, heartbeatSeconds), repeating: max(0.05, heartbeatSeconds))
        timer.setEventHandler { [weak self] in self?.emit(force: true) }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }
    public static var defaultDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        if env["C1_REQUEST_DIR"] == "off" { return nil }
        if let path = env["C1_REQUEST_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/c1/requests", isDirectory: true)
    }
    public var snapshot: RequestSnapshot {
        mutex.lock(); defer { mutex.unlock() }
        return snapshotLocked()
    }
    private func snapshotLocked() -> RequestSnapshot {
        var copy = state
        let now = ProcessInfo.processInfo.systemUptime
        copy.elapsedMs = Int((now - start) * 1000)
        copy.slow = now - start >= slowThreshold
        copy.lastProgressAgoMs = lastProgress.map { Int((now - $0) * 1000) }
        copy.updatedAt = Date().timeIntervalSince1970
        return copy
    }
    public func update(phase: String, scanned: Int? = nil, matches: Int? = nil, completed: Int? = nil, total: Int? = nil,
                       pass: Int? = nil, unconfirmed: Int? = nil, revalidated: Int? = nil) {
        mutex.lock()
        let changed = state.phase != phase
        state.phase = phase
        if let scanned { if scanned > state.candidatesScanned { lastProgress = ProcessInfo.processInfo.systemUptime }; state.candidatesScanned = scanned }
        if let completed { if completed > state.summariesCompleted { lastProgress = ProcessInfo.processInfo.systemUptime }; state.summariesCompleted = completed }
        if let revalidated { if revalidated > state.revalidatedRows ?? 0 { lastProgress = ProcessInfo.processInfo.systemUptime }; state.revalidatedRows = revalidated }
        if let matches { state.matchesFound = matches }
        if let pass { state.pass = pass }
        if let unconfirmed { state.unconfirmedMatches = unconfirmed }
        if let total { state.totalCandidates = total }
        mutex.unlock()
        emit(force: changed && !["ratings", "metadata"].contains(phase))
    }
    public func inventoryScope(collection: String?, selected: Bool, rating: Int?, minRating: Int?) {
        mutex.lock()
        state.scope = (collection == nil ? "document" : "collection") + (selected ? ":selected" : ":all")
        state.rating = rating; state.minRating = minRating
        mutex.unlock()
    }
    public func inventoryStrategy(_ strategy: String) {
        mutex.lock(); state.inventoryStrategy = strategy; mutex.unlock()
    }
    public func document(_ token: String) {
        mutex.lock()
        state.documentIdentity = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        mutex.unlock()
    }
    public func appleEvent(_ handler: String?, waiting: Bool) {
        mutex.lock(); state.handler = handler; state.waitingForAppleEvent = waiting
        if waiting { state.handlerCalls += 1 }
        mutex.unlock()
        emit(force: false)
    }
    public func linkOperation(_ id: String) {
        mutex.lock(); state.operationId = id; mutex.unlock()
        update(phase: "mutation-prepared")
    }
    public func cancel() {
        mutex.lock(); cancelled = true; state.cancelRequested = true; mutex.unlock()
        emit(force: true)
    }
    public var cancellationRequested: Bool { mutex.lock(); defer { mutex.unlock() }; return cancelled }
    /// Only top-level batched reads honor read cancellation. Nested inventory inside a mutation must finish its safety work.
    public func checkReadCancellation() throws {
        mutex.lock(); let stop = cancelled && ["variants_list", "dump"].contains(state.tool); mutex.unlock()
        if stop { throw C1Error.requestCancelled("Inventory cancelled between Apple Events; no partial inventory was returned.") }
    }
    /// Compound workflows stop only after the current guarded operation has returned.
    public func checkCompoundCancellation() throws {
        mutex.lock(); let stop = cancelled; mutex.unlock()
        if stop { throw C1Error.requestCancelled("Compound edit cancelled between steps; inspect its completion report.") }
    }
    public func finish(error: Error? = nil) {
        timer?.cancel(); timer = nil
        mutex.lock()
        if let error {
            let cause = (error as? OperationFailure)?.cause ?? error
            let code = (cause as? C1Error)?.errorCode
            state.status = code == "outcome-unknown" || (error is OperationFailure) ? "outcome-unknown" : (code == "request-cancelled" ? "cancelled" : "failed")
            if let failure = error as? OperationFailure { state.operationId = failure.operationId }
            let body = ErrorResponse.payload(error)["error"] as? [String: Any] ?? [:]
            state.errorCode = body["code"] as? String
            state.errorMessage = (body["message"] as? String).map(RequestSnapshot.redacted)
            state.missingIds = body["missingIds"] as? [String]
            state.outOfScopeIds = body["outOfScopeIds"] as? [String]
        } else { state.status = "completed" }
        mutex.unlock()
        emit(force: true)
        outputQueue.sync {} // terminal record is visible before the result
    }
    public func annotate(_ payload: [String: Any]) -> [String: Any] {
        var payload = payload
        var error = payload["error"] as? [String: Any] ?? [:]
        let s = snapshot
        error["requestId"] = s.requestId; error["phase"] = s.phase; error["elapsedMs"] = s.elapsedMs
        if error["operationId"] == nil { error["operationId"] = s.operationId }
        switch error["code"] as? String {
        case "outcome-unknown", "partial-failure": error["recoveryAction"] = "Inspect operation status; do not retry the mutation."
        case "capture-one-busy": error["recoveryAction"] = "Inspect request status and wait for the owning workflow to finish."
        case "timeout", "deadline-exceeded": error["recoveryAction"] = s.operationId == nil ? "Inspect request status and Capture One responsiveness before another request; a deadline does not stop an Apple Event." : "Inspect operation status; do not retry the mutation."
        case "permission-denied": error["recoveryAction"] = "Enable Capture One Automation permission for the host application."
        case "app-not-running": error["recoveryAction"] = "Launch Capture One and open the intended document."
        case "no-document": error["recoveryAction"] = "Open the intended Session or Catalog."
        // A definite refusal: its operation resolved as failed and blocks nothing.
        case "no-people-detected": error["recoveryAction"] = "Nothing was changed; choose another mask for this photo."
        default: break
        }
        if error["operationId"] != nil && error["code"] as? String != "no-people-detected" { error["recoveryAction"] = "Inspect operation status; do not retry the mutation." }
        payload["error"] = error
        return payload
    }
    private func emit(force: Bool) {
        mutex.lock()
        guard !terminalEmitted else { mutex.unlock(); return }
        if state.status != "running" { terminalEmitted = true }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEmission >= 1 else { mutex.unlock(); return }
        lastEmission = now
        let s = snapshotLocked()
        // Queue insertion under the mutex preserves event order across heartbeat and main threads.
        outputQueue.async { [self] in
            defer { observer?(s) }
            guard let data = try? JSONEncoder().encode(s) else { return }
            if progressMode == "json" { try? FileHandle.standardError.write(contentsOf: data + Data([10])) }
            if progressMode == "human" {
                let waiting = (s.slow ? "; slow request" : "") + (s.waitingForAppleEvent ? "; Apple Event progress unknown" : "")
                let pass = s.pass.map { "pass \($0), " } ?? ""
                let unconfirmed = s.unconfirmedMatches.map { " (\($0) unconfirmed)" } ?? ""
                let revalidated = s.revalidatedRows.map { ", revalidated \($0)" } ?? ""
                let message = "[\(s.requestId)] \(s.phase): \(s.status), \(s.elapsedMs / 1000)s; \(pass)scanned \(s.candidatesScanned), matches \(s.matchesFound)\(unconfirmed), summaries \(s.summariesCompleted)\(revalidated)\(waiting)\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            }
            guard let directory else { return }
            // Diagnostic storage failures must never change a Capture One result.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let status = directory.appendingPathComponent(s.requestId + ".json")
                try data.write(to: status, options: .atomic)
                if diagnostics {
                    let log = directory.appendingPathComponent(s.requestId + ".jsonl")
                    if let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size]) as? NSNumber, size.intValue > 1_048_576 {
                        let old = log.appendingPathExtension("1")
                        try? FileManager.default.removeItem(at: old)
                        try FileManager.default.moveItem(at: log, to: old)
                    }
                    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                    let handle = try FileHandle(forWritingTo: log)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
                }
            } catch { /* diagnostics are best effort */ }
        }
        mutex.unlock()
    }
    /// Reads local diagnostics only. Never acquires the Capture One lock or executes AppleScript.
    public static func status(requestId: String, directory: URL? = defaultDirectory) throws -> RequestSnapshot {
        guard requestId.hasPrefix("req-"), UUID(uuidString: String(requestId.dropFirst(4))) != nil, let directory else {
            throw C1Error.invalidRequest("Expected req-<UUID> and an enabled request status directory.")
        }
        let url = directory.appendingPathComponent(requestId + ".json")
        guard let data = try? Data(contentsOf: url), var result = try? JSONDecoder().decode(RequestSnapshot.self, from: data) else {
            throw C1Error.invalidRequest("Request status is unavailable; verify the request ID and C1_REQUEST_DIR.")
        }
        result.processAlive = kill(result.processId, 0) == 0 || errno == EPERM
        result.stale = result.status == "running" && (result.processAlive == false || Date().timeIntervalSince1970 - result.updatedAt > 15)
        return result
    }
}

/// Routes process signals to request cancellation while a request runs. The request then
/// stops at its next safe boundary; an outstanding Apple Event is never interrupted, and
/// commands without such a boundary finish normally. Call `stop()` when the request ends
/// to restore the previous signal dispositions.
public final class SignalCancellation: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private var previous: [Int32: sigaction] = [:]
    private let mutex = NSLock()
    private var received = 0

    /// `notice` receives the running count of signals, on a background queue.
    public init(_ context: RequestContext, signals: [Int32] = [SIGINT, SIGTERM], notice: (@Sendable (Int) -> Void)? = nil) {
        for number in signals {
            // Ignore the default action so the process survives; the dispatch source still observes the signal.
            var ignore = sigaction(), old = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            sigaction(number, &ignore, &old)
            previous[number] = old
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                context.cancel()
                mutex.lock(); received += 1; let count = received; mutex.unlock()
                notice?(count)
            }
            source.resume()
            sources.append(source)
        }
    }

    public func stop() {
        sources.forEach { $0.cancel() }; sources = []
        for (number, var old) in previous { sigaction(number, &old, nil) }
        previous = [:]
    }
    deinit { stop() }
}
