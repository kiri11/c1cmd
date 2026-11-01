import Foundation

/// c1's own files: `~/.c1`, or `$C1_HOME`.
public enum C1Home {
    public static var url: URL {
        if let path = ProcessInfo.processInfo.environment["C1_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".c1")
    }
}

/// A variant's full state before c1's first write to it, kept until a `revert` of everything succeeds.
public struct Snapshot: Codable, Equatable {
    public let taken: String
    public let document: String
    public let state: JSONValue
    public var masks = "Mask pixels are not readable through Capture One's scripting, so this snapshot lacks them and revert cannot restore them."
    public var skinTone = "Skin tone corrections in the color editor are not exposed through Capture One's scripting, so this snapshot lacks them and revert cannot restore them."

    public init(taken: Date, document: String, state: VariantState) {
        self.taken = ISO8601DateFormatter().string(from: taken); self.document = document; self.state = state.json
    }
}

/// `~/.c1/documents/<document UUID>/`: the write log and the snapshots.
public struct DocumentStore {
    public let directory: URL

    public init(home: URL, documentUUID: String) {
        directory = home.appendingPathComponent("documents").appendingPathComponent(documentUUID)
    }

    var logURL: URL { directory.appendingPathComponent("log.jsonl") }

    func snapshotURL(_ id: VariantID) -> URL {
        directory.appendingPathComponent("snapshots").appendingPathComponent("\(id).json")
    }

    public func snapshot(_ id: VariantID) throws -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: snapshotURL(id).path) else { return nil }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw C1Failure(.internal, "The snapshot \(snapshotURL(id).path) is unreadable: \(error).",
                            hint: "c1 keeps it as it is; move it away only if you no longer need to revert this variant.")
        }
    }

    public func save(_ snapshot: Snapshot, for id: VariantID) throws {
        try write(Data(JSONValue.from(snapshot).encoded(pretty: true).utf8), to: snapshotURL(id))
    }

    public func deleteSnapshot(_ id: VariantID) throws {
        let url = snapshotURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func append(_ line: JSONValue) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw C1Failure(.internal, "Cannot open \(logURL.path): \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        let bytes = Array((line.encoded() + "\n").utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else {
            throw C1Failure(.internal, "Cannot append to \(logURL.path): \(String(cString: strerror(errno))).")
        }
    }

    /// Readers never see a half-written file.
    func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw C1Failure(.internal, "Cannot write \(url.path): \(error.localizedDescription)")
        }
    }
}

/// The document of the last live call, so the next call can plan its routes without first asking
/// Capture One. Each read reports the live document, so a stale memory costs one replanned read.
struct DocumentMemory {
    let url: URL
    init(home: URL) { url = home.appendingPathComponent("document.json") }

    func load() -> LiveDocument? {
        FileManager.default.contents(atPath: url.path).flatMap { try? JSONDecoder().decode(LiveDocument.self, from: $0) }
    }

    func save(_ document: LiveDocument) {
        guard load() != document, let data = try? JSONEncoder().encode(document) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func forget() { try? FileManager.default.removeItem(at: url) }
}

extension JSONValue {
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
