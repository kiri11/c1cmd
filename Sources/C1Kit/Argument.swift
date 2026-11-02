import Foundation

/// One argument of a command: decoding rejects any other key, and `--help` and the reference print it.
public struct Argument: Equatable {
    public indirect enum Kind: Equatable {
        case integer(ClosedRange<Int>?)
        case number(ClosedRange<Double>?)
        case boolean
        case text
        case variantID
        case collectionID
        /// A layer by index (0 is the background), exact name, or the tag `layer.create` returned.
        case layer
        case list(Kind, count: ClosedRange<Int>?)
        case enumeration([String])
        /// An object with these keys.
        case object([Argument])
        /// An object of named fields, validated after decoding; the description says which.
        case fields
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let description: String

    public init(_ name: String, _ kind: Kind, required: Bool = false, _ description: String) {
        self.name = name; self.kind = kind; self.required = required; self.description = description
    }

    /// The type without its range or values, as `--help` prints it.
    public var type: String { kind.type }
    /// The accepted range of a number or the item count of a list; nil when unbounded.
    public var range: String? { kind.range }
    /// The accepted values of an enumeration.
    public var values: [String]? { if case .enumeration(let values) = kind { return values }; return nil }
}

extension Argument.Kind {
    var type: String {
        switch self {
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .text: return "text"
        case .variantID: return "variant id"
        case .collectionID: return "collection id"
        case .layer: return "layer"
        case .list(let item, _): return "list of \(item.type)"
        case .enumeration: return "text"
        case .object(let keys): return "object {\(keys.map(\.name).joined(separator: ", "))}"
        case .fields: return "object of fields"
        }
    }

    var range: String? {
        switch self {
        case .integer(let range?): return "\(range.lowerBound)–\(range.upperBound)"
        case .number(let range?): return "\(format(range.lowerBound))–\(format(range.upperBound))"
        case .list(_, let count?): return "\(count.lowerBound)–\(count.upperBound) items"
        default: return nil
        }
    }
}

/// Shared arguments and the concepts several commands explain.
enum Arguments {
    static let ids = Argument("ids", .list(.variantID, count: 1...Service.maxIDs), required: true,
                              "Variant ids as strings of digits, from list, selection or contact_sheet.")
    static let id = Argument("id", .variantID, required: true, "One variant id as a string of digits.")
    static let timeout = Argument("timeout", .number(Preview.timeouts),
                                  "Seconds to wait for the exported JPEG (default \(Int(Preview.defaultTimeout))). Past it the outcome is unknown and the result names where the file will land.")

    static let filters: [Argument] = [
        Argument("rating", .integer(0...5), "Only variants with exactly this rating."),
        Argument("minRating", .integer(0...5), "Only variants rated at least this."),
        Argument("colorTag", .integer(0...7), "Only variants with this color tag; 0 is none."),
        Argument("collection", .collectionID, "Only variants in this collection (from collections); a folder includes its subfolders."),
        Argument("ids", .list(.variantID, count: nil), "Only these variants."),
        Argument("edited", .boolean, "Only variants whose settings differ (true) or do not differ (false) from the defaults Capture One applied at import."),
        Argument("after", .variantID, "Paging cursor: the next value of the previous page."),
    ]

    static let canvasRect: [Argument] = ["centerX", "centerY", "width", "height"].map {
        Argument($0, .number(nil), required: true, "Crop pixels: centre and size, y up; sides at least 1 px, all within ±\(Int(Preview.candidateLimit)) px.")
    }

    static let region: [Argument] = [
        Argument("x", .number(0...1), required: true, "Left edge, as a fraction of the cropped preview's width from its left."),
        Argument("y", .number(0...1), required: true, "Top edge, as a fraction of the cropped preview's height from its top."),
        Argument("width", .number(0...1), required: true, "Width as a fraction; x + width ≤ 1."),
        Argument("height", .number(0...1), required: true, "Height as a fraction; y + height ≤ 1."),
    ]

    static let layerPatch: [Argument] = [
        Argument("layer", .layer, required: true, "The layer: its index in get's layers (0 is the background), its exact name, or its c1 tag."),
        Argument("enabled", .boolean, "Turn the layer on or off."),
        Argument("opacity", .integer(nil), "Layer opacity; the range is in the field table below."),
        Argument("adjustments", .fields, "The layer's own adjustments, named as for the variant, without geometry."),
    ]

    /// The crop convention, shared by get, set, preview and crop_preview.
    static let cropPixels = "Crops are [centre x, centre y, width, height] in whole pixels of the oriented, rotated canvas, with y up from the bottom edge. get reports cropBounds: the four corners of the area a crop may cover after rotation and keystone (source image is exact; source maximumCrop, used when keystone, lens geometry or flip are set, keeps the image's proportions, so it is narrower than the true area for other ratios)."

    static let queue = "Every Capture One call from every c1 process waits in one first-in, first-out queue: at most 8 callers wait, and others fail at once with busy, as does a caller that waits 10 minutes. A crashed caller's place is released automatically."

    static let writes = "Every write reads the variant first, so a set takes about 3 s, and about 1 s more for each layer other than the background. Before c1's first write to a variant it saves the variant's full settings as a snapshot, and revert restores it; each write call is appended to a log. Both live in ~/.c1/documents/<document uuid>/. Values are absolute: give the target, not a change. c1 checks names, types and measured ranges before dispatch, then reads each field back: a stored value that differs from the one sent is a warning {field, sent, stored}, not a failure. A timeout's outcome is unknown: call get again to see the current state; c1 does not retry."

    static let outputFolder = "A Catalog whose output folder is unset refuses every export, so c1 sets it to its preview folder and warns."

    static let previewFiles = "JPEGs land in ~/Library/Caches/c1/previews/<document uuid>/; c1 deletes its previews older than 7 days."
}
