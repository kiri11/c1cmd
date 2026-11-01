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

public struct LiveDocument: Codable, Equatable {
    /// Capture One's `id of document`, its path; a write script refuses to run on any other document.
    public let id: String
    public let kind: DocumentKind
    public let name: String
    /// The document's own folder item: the `.cocatalog` package, an unpackaged `.cocatalogdb`, or the Session folder.
    public let folder: String
    public let appVersion: String

    public init(id: String, kind: DocumentKind, name: String, folder: String, appVersion: String) {
        self.id = id; self.kind = kind; self.name = name; self.folder = folder; self.appVersion = appVersion
    }

    public var databasePath: String {
        let url = URL(fileURLWithPath: folder)
        let file = kind == .catalog ? "cocatalogdb" : "cosessiondb"
        if url.pathExtension == file { return url.path }
        // A Session's name carries the extension; a Catalog's does not.
        let base = name.hasSuffix(".\(file)") ? String(name.dropLast(file.count + 1)) : name
        return url.appendingPathComponent("\(base).\(file)").path
    }
}

/// A variant's live editing state; keys are Capture One's AppleScript property names.
public struct VariantState: Equatable {
    public var id: VariantID
    public var variant: [String: JSONValue]
    /// The Image (background) layer's adjustments, which are the variant's adjustments.
    public var adjustments: [String: JSONValue]
    public var lensCorrection: [String: JSONValue]
    /// Every layer, the background first; non-background layers carry their own `adjustments`.
    public var layers: [[String: JSONValue]]
    /// `dimensions of parent image`: the canvas after orientation and rotation, which grows as the image turns.
    public var canvasSize: [Double]?
    /// `maximum crop`: the largest centred crop of the image's proportions, as {centre x, centre y, width, height}.
    public var maximumCrop: [Double]?

    public init(id: VariantID, variant: [String: JSONValue], adjustments: [String: JSONValue],
                lensCorrection: [String: JSONValue], layers: [[String: JSONValue]],
                canvasSize: [Double]? = nil, maximumCrop: [Double]? = nil) {
        self.id = id; self.variant = variant; self.adjustments = adjustments
        self.lensCorrection = lensCorrection; self.layers = layers
        self.canvasSize = canvasSize; self.maximumCrop = maximumCrop
    }

    /// Reads back a state written by `json`, as stored in a snapshot.
    public init?(json: JSONValue) {
        guard case .string(let text)? = json["id"], let id = VariantID(text),
              case .object(let variant)? = json["variant"], case .object(let adjustments)? = json["adjustments"],
              case .object(let lens)? = json["lensCorrection"], case .array(let layerItems)? = json["layers"] else { return nil }
        var layers: [[String: JSONValue]] = []
        for item in layerItems {
            guard case .object(let layer) = item else { return nil }
            layers.append(layer)
        }
        self.init(id: id, variant: variant, adjustments: adjustments, lensCorrection: lens, layers: layers)
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id.description), "variant": .object(variant), "adjustments": .object(adjustments),
            "lensCorrection": .object(lensCorrection), "layers": .array(layers.map(JSONValue.object)),
        ]
        if let bounds = cropBounds { fields["cropBounds"] = bounds.json }
        return .object(fields)
    }
}

public enum ReadResult: Equatable {
    case state(VariantState)
    case notFound
    case failed(String)
}

public struct ReadBatch: Equatable {
    /// The document that was open during the read.
    public let document: LiveDocument
    public let results: [VariantID: ReadResult]
    public init(document: LiveDocument, results: [VariantID: ReadResult]) { self.document = document; self.results = results }
}

/// The seam between c1 and Capture One. `AppleScriptCaptureOne` is the real one; tests use a fake.
public protocol CaptureOne {
    func document() throws -> LiveDocument
    /// Reads every target and the open document in one execution; per-target errors do not fail the call.
    func read(_ targets: [ReadTarget]) throws -> ReadBatch
    /// Runs every variant's steps in one execution, only if `document` is still the open one.
    /// Per-step and per-variant errors do not fail the call.
    func write(_ writes: [VariantWrite], in document: LiveDocument) throws -> [VariantID: WriteResult]
    func selection() throws -> [VariantID]
    /// Configures c1's recipe and queues one export, only if `document` is still the open one. Returns once
    /// Capture One has queued it, before the file lands; throws `notFound` when the variant is gone. Returns
    /// true when it had to set a Catalog's unusable output folder to the export's folder first.
    func export(_ request: ExportRequest, in document: LiveDocument) throws -> Bool
}

/// One JPEG export through c1's recipe.
public struct ExportRequest: Equatable {
    public static let recipe = "c1-preview"

    public let target: ReadTarget
    public let longEdge: Int
    /// Renders the default crop in place of the variant's, through the recipe's `export crop method`; the variant is not written.
    public let fullFrame: Bool
    /// Where the JPEG lands: Capture One adds `.jpg` to the name.
    public let file: URL

    public init(target: ReadTarget, longEdge: Int, fullFrame: Bool, file: URL) {
        self.target = target; self.longEdge = longEdge; self.fullFrame = fullFrame; self.file = file
    }
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
        case documentChanged = "document-changed"
        case database
        case scriptError = "script-error"
        case notFound = "not-found"
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
