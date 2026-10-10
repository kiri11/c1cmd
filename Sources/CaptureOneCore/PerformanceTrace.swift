import Foundation

/// Opt-in diagnostics on stderr; never include arguments, paths or property values.
public enum PerformanceTrace {
    private static var enabled: Bool { getenv("C1_PROFILE").map { strcmp($0, "1") == 0 } ?? false }
    private static let stepKey = "c1.profile.step"
    private static let outputLock = NSLock()

    /// Labels every record measured inside `body` with the step name.
    public static func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        return try measure("step", handler: name) {
            let dictionary = Thread.current.threadDictionary
            let parent = dictionary[stepKey]
            dictionary[stepKey] = name
            defer { dictionary[stepKey] = parent }
            return try body()
        }
    }

    public static func measure<T>(_ phase: String, handler: String,
                                  _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        var succeeded = false
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            var record: [String: Any] = ["type": "c1-profile", "version": 1,
                "pid": ProcessInfo.processInfo.processIdentifier, "phase": phase,
                "handler": handler, "elapsedMs": elapsed, "succeeded": succeeded]
            record["step"] = Thread.current.threadDictionary[stepKey]
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
