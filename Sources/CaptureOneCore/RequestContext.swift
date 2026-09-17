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
    public var candidatesScanned = 0
    public var matchesFound = 0
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
    public func update(phase: String, scanned: Int? = nil, matches: Int? = nil, completed: Int? = nil, total: Int? = nil) {
        mutex.lock()
        let changed = state.phase != phase
        state.phase = phase
        if let scanned { if scanned > state.candidatesScanned { lastProgress = ProcessInfo.processInfo.systemUptime }; state.candidatesScanned = scanned }
        if let completed { if completed > state.summariesCompleted { lastProgress = ProcessInfo.processInfo.systemUptime }; state.summariesCompleted = completed }
        if let matches { state.matchesFound = matches }
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
    public func cancel() { mutex.lock(); cancelled = true; mutex.unlock() }
    /// Only top-level inventory requests honor cancellation. Nested inventory inside a mutation must finish its safety work.
    public func checkReadCancellation() throws {
        mutex.lock(); let stop = cancelled && state.tool == "variants_list"; mutex.unlock()
        if stop { throw C1Error.requestCancelled("Inventory cancelled between Apple Events; no partial inventory was returned.") }
    }
    public func finish(error: Error? = nil) {
        timer?.cancel(); timer = nil
        mutex.lock()
        if let error {
            let cause = (error as? OperationFailure)?.cause ?? error
            let code = (cause as? C1Error)?.errorCode
            state.status = code == "outcome-unknown" || (error is OperationFailure) ? "outcome-unknown" : (code == "request-cancelled" ? "cancelled" : "failed")
            if let failure = error as? OperationFailure { state.operationId = failure.operationId }
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
        default: break
        }
        if error["operationId"] != nil { error["recoveryAction"] = "Inspect operation status; do not retry the mutation." }
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
                let message = "[\(s.requestId)] \(s.phase): \(s.status), \(s.elapsedMs / 1000)s; scanned \(s.candidatesScanned), matches \(s.matchesFound), summaries \(s.summariesCompleted)\(waiting)\n"
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
