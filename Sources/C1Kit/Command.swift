import Foundation

/// Every command, declared once. Step 4 generates the CLI, MCP tools and reference from this table.
public enum Command: String, CaseIterable {
    case list, collections, get, selection

    public var summary: String {
        switch self {
        case .list: return "List variants from the database, filtered and paged."
        case .collections: return "List collections with kind, parent and variant count."
        case .get: return "Read live settings, geometry and layers of 1–100 variants."
        case .selection: return "Read the ids of the variants selected in Capture One."
        }
    }

    /// Argument names; anything else is rejected.
    public var arguments: [String] {
        switch self {
        case .list: return ["rating", "minRating", "colorTag", "collection", "ids", "edited", "after", "limit"]
        case .collections, .selection: return []
        case .get: return ["ids", "changed"]
        }
    }

    /// Commands that can read a database file without Capture One.
    public var acceptsDocumentPath: Bool { self == .list || self == .collections }

    public func run(_ service: Service, arguments json: Data, document: String? = nil) throws -> JSONValue {
        if document != nil, !acceptsDocumentPath {
            throw C1Failure(.invalidArguments, "\(rawValue) reads Capture One's open document and takes no document path.")
        }
        switch self {
        case .list:
            return try service.list(try decode(ListQuery.self, json), document: document)
        case .collections:
            _ = try decode(Empty.self, json)
            return try service.collections(document: document)
        case .get:
            let arguments = try decode(GetArguments.self, json)
            return try service.get(ids: arguments.ids, changed: arguments.changed ?? false)
        case .selection:
            _ = try decode(Empty.self, json)
            return try service.selection()
        }
    }

    struct Empty: Decodable {}
    struct GetArguments: Decodable { let ids: [VariantID]; let changed: Bool? }

    private func decode<T: Decodable>(_ type: T.Type, _ json: Data) throws -> T {
        let data = json.isEmpty ? Data("{}".utf8) : json
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw C1Failure(.invalidArguments, "\(rawValue) takes a JSON object of arguments.")
        }
        let unknown = object.keys.filter { !arguments.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw C1Failure(.invalidArguments, "\(rawValue) does not take \(unknown.joined(separator: ", ")); it takes \(arguments.isEmpty ? "no arguments" : arguments.joined(separator: ", ")).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw C1Failure(.invalidArguments, "\(rawValue) needs \(key.stringValue).")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.dataCorrupted(context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw C1Failure(.invalidArguments, "\(rawValue): bad value at \(path.isEmpty ? "top level" : path): \(context.debugDescription)")
        }
    }
}
