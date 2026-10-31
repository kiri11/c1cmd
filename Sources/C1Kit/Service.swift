import Foundation

/// Runs commands: SQLite reads directly, every Capture One call through the queue.
public final class Service {
    let captureOne: CaptureOne
    let queue: CaptureOneQueue
    let openDatabase: (String) throws -> Database
    let defaults: () throws -> Defaults

    public static let maxGetIDs = 100

    public init(captureOne: CaptureOne, queue: CaptureOneQueue,
                openDatabase: @escaping (String) throws -> Database = { try Database(path: $0) },
                defaults: @escaping () throws -> Defaults = { try Defaults.bundled() }) {
        self.captureOne = captureOne; self.queue = queue; self.openDatabase = openDatabase; self.defaults = defaults
    }

    public func get(ids requested: [VariantID], changed: Bool = false) throws -> JSONValue {
        var seen = Set<VariantID>()
        let ids = requested.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, ids.count <= Self.maxGetIDs else {
            throw C1Failure(.invalidArguments, "get takes 1–\(Self.maxGetIDs) ids, got \(ids.count).")
        }
        let defaults = changed ? try self.defaults() : nil
        let (results, routes) = try queue.run { () throws -> ([VariantID: ReadResult], [VariantID: Route]) in
            let document = try captureOne.document()
            let database = try openDatabase(document.databasePath)
            guard database.kind == document.kind else {
                throw C1Failure(.database, "The database at \(document.databasePath) is a \(database.kind.rawValue), but Capture One reports a \(document.kind.rawValue).")
            }
            let folders = try database.routes(for: ids)
            let fallback: Route
            switch document.kind {
            case .catalog:
                guard let allImages = try database.allImagesCollection() else {
                    throw C1Failure(.database, "The Catalog database names no All Images collection.")
                }
                fallback = .allImages(allImages)
            case .session:
                fallback = .favoritesScan
            }
            var routes = Dictionary(uniqueKeysWithValues: ids.map { ($0, folders[$0].map(Route.collection) ?? fallback) })
            var results = try captureOne.read(ids.map { ReadTarget($0, routes[$0]!) })
            // SQLite lags Capture One, so a moved image can be missing from its recorded folder.
            let retry = ids.filter { results[$0] == .notFound && routes[$0] != fallback }
            if !retry.isEmpty {
                for id in retry { routes[id] = fallback }
                results.merge(try captureOne.read(retry.map { ReadTarget($0, fallback) })) { $1 }
            }
            return (results, routes)
        }
        return .object(["variants": .array(ids.map { id -> JSONValue in
            switch results[id] ?? .failed("Capture One returned no result for this id.") {
            case .state(let state):
                guard case .object(var fields) = defaults?.changed(state) ?? state.json else { return state.json }
                fields["route"] = .string(Self.describe(routes[id]!))
                return .object(fields)
            case .notFound:
                return Self.variantError(id, "not-found", "Capture One has no variant \(id) in this document.")
            case .failed(let reason):
                return Self.variantError(id, "read-failed", reason)
            }
        })])
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
            return try openDatabase(try queue.run { try captureOne.document() }.databasePath)
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
