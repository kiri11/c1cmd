import Foundation

/// Opt-in diagnostics on stderr; never include arguments, paths or property values.
public enum PerformanceTrace {
    private static let enabled = ProcessInfo.processInfo.environment["C1_PROFILE"] == "1"
    private static let outputLock = NSLock()

    public static func measure<T>(_ phase: String, handler: String,
                                  _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        var succeeded = false
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let record: [String: Any] = ["type": "c1-profile", "version": 1,
                "pid": ProcessInfo.processInfo.processIdentifier, "phase": phase,
                "handler": handler, "elapsedMs": elapsed, "succeeded": succeeded]
            if var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                data.append(10)
                outputLock.lock()
                // Diagnostic failures must never alter an operation's result.
                try? FileHandle.standardError.write(contentsOf: data)
                outputLock.unlock()
            }
        }
        let result = try body()
        succeeded = true
        return result
    }
}
