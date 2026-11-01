import Foundation

/// Runs commands: SQLite reads directly, every Capture One call through the queue.
public final class Service {
    let captureOne: CaptureOne
    let queue: CaptureOneQueue
    let home: URL
    let caches: URL
    let openDatabase: (String) throws -> Database
    let defaults: () throws -> Defaults
    let schema: () throws -> WriteSchema
    let now: () -> Date
    /// The live sdef's terms, which `doctor` compares with the built-in snapshot.
    let liveTerms: () throws -> Terminology
    let memory: DocumentMemory

    public static let maxIDs = 100
    public static let testedBuilds = ["16.8.5.30"]
    public static let backupAge: TimeInterval = 24 * 60 * 60

    public init(captureOne: CaptureOne, queue: CaptureOneQueue, home: URL = C1Home.url, caches: URL = C1Home.caches,
                openDatabase: @escaping (String) throws -> Database = { try Database(path: $0) },
                defaults: @escaping () throws -> Defaults = { try Defaults.bundled() },
                schema: @escaping () throws -> WriteSchema = { throw C1Failure(.internal, "No write schema.") },
                now: @escaping () -> Date = Date.init, liveTerms: @escaping () throws -> Terminology = { try Terminology.load().used() }) {
        self.captureOne = captureOne; self.queue = queue; self.home = home; self.caches = caches; self.openDatabase = openDatabase
        self.defaults = defaults; self.schema = schema; self.now = now; self.liveTerms = liveTerms; self.memory = DocumentMemory(home: home)
    }

    public func get(ids requested: [VariantID], changed: Bool = false) throws -> JSONValue {
        let ids = try Self.unique(requested, command: "get")
        let defaults = changed ? try self.defaults() : nil
        let read = try queue.run { try liveRead(ids) }
        return .object(["variants": .array(ids.map { id -> JSONValue in
            switch read.results[id] ?? .failed("Capture One returned no result for this id.") {
            case .state(let state):
                guard case .object(var fields) = defaults?.changed(state) ?? state.json else { return state.json }
                if defaults != nil, let bounds = state.cropBounds { fields["cropBounds"] = bounds.json }
                fields["route"] = .string(Self.describe(read.routes[id]!))
                return .object(fields)
            case .notFound:
                return Self.variantError(id, "not-found", "Capture One has no variant \(id) in this document.")
            case .failed(let reason):
                return Self.variantError(id, "read-failed", reason)
            }
        })])
    }

    static func unique(_ requested: [VariantID], command: String) throws -> [VariantID] {
        var seen = Set<VariantID>()
        let ids = requested.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, ids.count <= maxIDs else {
            throw C1Failure(.invalidArguments, "\(command) takes 1–\(maxIDs) ids, got \(ids.count).")
        }
        return ids
    }

    struct LiveRead {
        let document: LiveDocument
        let database: Database
        let results: [VariantID: ReadResult]
        let routes: [VariantID: Route]
    }

    /// Reads live state in one Apple Event when the open document is the remembered one: routes come
    /// from that document's database, and the read reports the live document. Call inside the queue.
    func liveRead(_ ids: [VariantID]) throws -> LiveRead {
        var candidate = memory.load()
        for _ in 0..<3 {
            let document = try candidate ?? captureOne.document()
            let database: Database
            let routes: [VariantID: Route]
            let fallback: Route
            do {
                database = try openDatabase(document.databasePath)
                guard database.kind == document.kind else {
                    throw C1Failure(.database, "The database at \(document.databasePath) is a \(database.kind.rawValue), but Capture One reports a \(document.kind.rawValue).")
                }
                switch document.kind {
                case .catalog:
                    guard let allImages = try database.allImagesCollection() else {
                        throw C1Failure(.database, "The Catalog database names no All Images collection.")
                    }
                    fallback = .allImages(allImages)
                case .session:
                    fallback = .favoritesScan
                }
                let collections = try database.routes(for: ids)
                routes = Dictionary(uniqueKeysWithValues: ids.map { ($0, collections[$0].map(Route.collection) ?? fallback) })
            } catch where candidate != nil {
                memory.forget(); candidate = nil
                continue
            }
            let batch = try captureOne.read(ids.map { ReadTarget($0, routes[$0]!) })
            guard batch.document == document else {
                candidate = batch.document
                continue
            }
            memory.save(document)
            var results = batch.results, settled = routes
            // SQLite lags Capture One, so a moved image can be missing from its recorded collection.
            let retry = ids.filter { results[$0] == .notFound && routes[$0] != fallback }
            if !retry.isEmpty {
                for id in retry { settled[id] = fallback }
                let again = try captureOne.read(retry.map { ReadTarget($0, fallback) })
                guard again.document == document else {
                    throw C1Failure(.documentChanged, "Capture One's open document changed during the call.", hint: "Call it again.")
                }
                results.merge(again.results) { $1 }
            }
            return LiveRead(document: document, database: database, results: results, routes: settled)
        }
        throw C1Failure(.documentChanged, "Capture One's open document kept changing during the call.", hint: "Call it again.")
    }

    public func selection() throws -> JSONValue {
        let ids = try queue.run { try captureOne.selection() }
        return .object(["ids": .array(ids.map { .string($0.description) })])
    }

    public func list(_ query: ListQuery, document: String?) throws -> JSONValue {
        let (rows, next) = try database(document).list(query)
        var output: [String: JSONValue] = ["variants": try Self.json(rows)]
        if let next { output["next"] = .string(next.description) }
        return .object(output)
    }

    public func collections(document: String?) throws -> JSONValue {
        .object(["collections": try Self.json(try database(document).collections())])
    }

    /// The database at `document`, a Catalog or Session path, or the live document's.
    func database(_ document: String?) throws -> Database {
        guard let document else {
            let live = try queue.run { () throws -> LiveDocument in
                let document = try captureOne.document()
                memory.save(document)
                return document
            }
            return try openDatabase(live.databasePath)
        }
        let url = URL(fileURLWithPath: document)
        switch url.pathExtension {
        case "cocatalog":
            return try openDatabase(url.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cocatalogdb").path)
        case "cocatalogdb", "cosessiondb":
            return try openDatabase(url.path)
        default:
            let sessions = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { $0.hasSuffix(".cosessiondb") } ?? []
            guard sessions.count == 1 else {
                throw C1Failure(.invalidArguments, "\(document) is not a .cocatalog, .cocatalogdb, .cosessiondb or a Session folder holding one .cosessiondb.")
            }
            return try openDatabase(url.appendingPathComponent(sessions[0]).path)
        }
    }

    static func describe(_ route: Route) -> String {
        switch route {
        case .collection(let id): return "collection \(id)"
        case .allImages(let id): return "all images \(id)"
        case .favoritesScan: return "favorites scan"
        }
    }

    static func variantError(_ id: VariantID, _ code: String, _ message: String) -> JSONValue {
        .object(["id": .string(id.description), "error": .object(["code": .string(code), "message": .string(message)])])
    }

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
