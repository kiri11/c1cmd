import Foundation

/// A Capture One object id: the SQLite `Z_PK`, which AppleScript reports as text.
/// Digits only, so it is safe to splice into AppleScript and SQL.
public struct NumericID<Kind>: Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Int64

    public init?(_ text: String) {
        guard !text.isEmpty, text.count <= 18, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(text), value > 0 else { return nil }
        self.value = value
    }

    public init(_ value: Int64) { self.value = value }

    public var description: String { String(value) }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = Self(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected a positive integer id as a string, got \"\(text)\"")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum VariantTag {}
public enum CollectionTag {}
public typealias VariantID = NumericID<VariantTag>
public typealias CollectionID = NumericID<CollectionTag>

public enum DocumentKind: String, Codable { case catalog, session }

/// How a live read finds a variant. `variant id X of d` resolves only through the current collection,
/// so every read names a collection.
public enum Route: Hashable {
    /// The image's folder collection (Catalog) or matching favorite (Session); cost scales with that folder.
    case collection(CollectionID)
    /// Catalog fallback; cost scales with the whole Catalog (#61).
    case allImages(CollectionID)
    /// Session fallback: try each favorite in turn.
    case favoritesScan
}

public struct ReadTarget: Hashable {
    public let id: VariantID
    public let route: Route
    public init(_ id: VariantID, _ route: Route) { self.id = id; self.route = route }
}

public struct LiveDocument: Equatable {
    public let kind: DocumentKind
    public let name: String
    /// The document's own folder item: the `.cocatalog` package, an unpackaged `.cocatalogdb`, or the Session folder.
    public let folder: String
    public let appVersion: String

    public init(kind: DocumentKind, name: String, folder: String, appVersion: String) {
        self.kind = kind; self.name = name; self.folder = folder; self.appVersion = appVersion
    }

    public var databasePath: String {
        let url = URL(fileURLWithPath: folder)
        switch kind {
        case .catalog:
            return url.pathExtension == "cocatalogdb" ? url.path : url.appendingPathComponent("\(name).cocatalogdb").path
        case .session:
            return url.appendingPathComponent("\(name).cosessiondb").path
        }
    }
}

/// A variant's live editing state; keys are Capture One's AppleScript property names.
public struct VariantState: Equatable {
    public var id: VariantID
    public var variant: [String: JSONValue]
    /// The Image (background) layer's adjustments, which are the variant's adjustments.
    public var adjustments: [String: JSONValue]
    public var lensCorrection: [String: JSONValue]
    /// Every layer; non-background layers carry their own `adjustments`.
    public var layers: [[String: JSONValue]]

    public init(id: VariantID, variant: [String: JSONValue], adjustments: [String: JSONValue],
                lensCorrection: [String: JSONValue], layers: [[String: JSONValue]]) {
        self.id = id; self.variant = variant; self.adjustments = adjustments
        self.lensCorrection = lensCorrection; self.layers = layers
    }

    public var json: JSONValue {
        .object([
            "id": .string(id.description), "variant": .object(variant), "adjustments": .object(adjustments),
            "lensCorrection": .object(lensCorrection), "layers": .array(layers.map(JSONValue.object)),
        ])
    }
}

public enum ReadResult: Equatable {
    case state(VariantState)
    case notFound
    case failed(String)
}

/// The seam between c1 and Capture One. `AppleScriptCaptureOne` is the real one; tests use a fake.
public protocol CaptureOne {
    func document() throws -> LiveDocument
    /// Reads every target in one execution; per-target errors do not fail the call.
    func read(_ targets: [ReadTarget]) throws -> [VariantID: ReadResult]
    func selection() throws -> [VariantID]
}

public struct C1Failure: Error, Equatable, CustomStringConvertible {
    public enum Code: String {
        case invalidArguments = "invalid-arguments"
        case notRunning = "not-running"
        case noDocument = "no-document"
        case permissionDenied = "permission-denied"
        case timeout
        case busy
        case schemaMismatch = "schema-mismatch"
        case database
        case scriptError = "script-error"
        case `internal`
    }

    public let code: Code
    public let message: String
    public var hint: String?
    /// Set when a live call may or may not have finished in Capture One.
    public var outcomeUnknown = false

    public init(_ code: Code, _ message: String, hint: String? = nil, outcomeUnknown: Bool = false) {
        self.code = code; self.message = message; self.hint = hint; self.outcomeUnknown = outcomeUnknown
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public var json: JSONValue {
        var error: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let hint { error["hint"] = .string(hint) }
        if outcomeUnknown { error["outcome"] = .string("unknown") }
        return .object(["error": .object(error)])
    }

    public static let timeoutHint = "macOS may be showing an Automation consent dialog, possibly hidden behind other windows, or Capture One may be busy or showing a modal dialog. Call get again to see the current state; c1 does not retry."
}
