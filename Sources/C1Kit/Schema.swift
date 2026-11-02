import Foundation

/// One writable Capture One property: its sdef name and code, its type, and its measured bounds.
public struct FieldSpec: Equatable {
    public enum Kind: Hashable {
        case real, integer, boolean, text
        /// Enumerator names mapped to their codes.
        case enumeration([String: String])
        /// Three 16-bit components.
        case rgb
        /// The crop: centre x, centre y, width and height in whole pixels.
        case rectangle
        /// A curve's points as [x, y] pairs ordered by x, each within 0–100.
        case curve
    }

    public let name: String
    public let code: String
    public let kind: Kind
    public let bound: Bound?

    public init(name: String, code: String, kind: Kind, bound: Bound? = nil) {
        self.name = name; self.code = code; self.kind = kind; self.bound = bound
    }
}

/// A numeric field's accepted values, measured live by `scripts/measure-bounds.py`.
public struct Bound: Codable, Equatable {
    /// nil: the measurement found no limit on that side.
    public let min: Double?
    public let max: Double?
    /// When set, the only accepted values.
    public let values: [Double]?

    public init(min: Double? = nil, max: Double? = nil, values: [Double]? = nil) {
        self.min = min; self.max = max; self.values = values
    }

    func accepts(_ value: Double) -> Bool {
        if let values { return values.contains(value) }
        return (min.map { value >= $0 } ?? true) && (max.map { value <= $0 } ?? true)
    }

    var description: String {
        if let values { return "one of \(values.map(format).joined(separator: ", "))" }
        switch (min, max) {
        case let (low?, high?): return "within \(format(low))…\(format(high))"
        case let (low?, nil): return "at least \(format(low))"
        case let (nil, high?): return "at most \(format(high))"
        case (nil, nil): return "finite"
        }
    }
}

func format(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
}

/// The bounds table, `Resources/Bounds.json`, keyed by section then field name.
public struct BoundsTable: Codable, Equatable {
    public let build: String
    public let fields: [String: [String: Bound]]

    public init(build: String, fields: [String: [String: Bound]]) { self.build = build; self.fields = fields }

    public static func bundled() throws -> BoundsTable {
        try JSONDecoder().decode(BoundsTable.self, from: Data(Embedded.bounds.utf8))
    }
}

/// The parts of a variant `set` writes, named as `get` reports them.
public enum Section: String, CaseIterable {
    case variant, adjustments, lensCorrection, layer, basicColor, advancedColor

    var classCode: String {
        switch self {
        case .variant: return "cvar"
        case .adjustments: return "CVas"
        case .lensCorrection: return "Clco"
        case .layer: return "clyr"
        case .basicColor: return "CCba"
        case .advancedColor: return "CCad"
        }
    }
}

/// What `set` and `revert` may write, from the sdef's names and types and the measured bounds.
public struct WriteSchema {
    public private(set) var fields: [Section: [String: FieldSpec]] = [:]
    /// Writable numeric fields the bounds table lacks; c1 refuses them rather than guess.
    public private(set) var unmeasured: [Section: Set<String>] = [:]
    /// Everything the sdef lets a script write, including what c1 does not, for revert's report.
    public private(set) var sdefWritable: [Section: Set<String>] = [:]

    /// Variant and layer fields are an explicit list: the rest are browser state, metadata c1 does not
    /// write (#50), or derived from the crop.
    static let allowed: [Section: Set<String>] = [.variant: ["rating", "color tag", "crop"], .layer: ["enabled", "opacity"]]
    /// Fields that move the crop's usable area. A patch cannot set them with the crop, whose bounds they change.
    public static let boundsFields: [Section: Set<String>] = [
        .adjustments: ["orientation", "flip", "rotation", "keystone amount", "keystone vertical", "keystone horizontal", "keystone skew", "keystone aspect"],
        .lensCorrection: ["distortion", "tilt", "tilt direction", "shift", "shift direction", "shift x", "shift y", "hide distorted areas", "lens profile"],
    ]
    /// Geometry is the background's alone; a layer's adjustments never carry it.
    static let geometryFields: Set<String> = boundsFields[.adjustments]!
    /// Measured on 16.8.5.30: a layer reports these as missing value until they are written, so `get` and the
    /// snapshot omit them, and writing 0 renders exactly like the untouched layer.
    static let unsetLayerFields: Set<String> = [
        "black recovery", "brightness", "clarity amount", "clarity structure", "contrast", "dehaze amount", "exposure",
        "highlight recovery", "moire amount", "noise reduction details", "noise reduction luminance",
        "saturation", "shadow recovery", "sharpening amount", "white recovery",
    ]
    /// Measured on 16.8.5.30: each adjustments name on the left is the one on the right negated, one value under two
    /// names, so writing either moves the other. c1 reads and writes only the name on the right.
    static let aliases: [String: String] = ["highlight adjustment": "highlight recovery"]
    /// `get` and `set` name curves by channel under `curves`; the sdef names them "<channel> curve".
    public static let curveChannels = ["rgb", "luma", "red", "green", "blue"]
    static func curveField(_ channel: String) -> String { "\(channel) curve" }
    static func curveChannel(_ field: String) -> String { String(field.dropLast(" curve".count)) }
    /// Capture One 16.8.5.30 refuses a 19th point ("Too many curve points") and a point within 1.5 of
    /// another's x ("very close to an existing point"); 1.55 apart is accepted.
    public static let curvePoints = 2...18
    public static let curveGap = 1.5
    /// Setting a color moves the ranges around it, so an advanced correction is written in this order.
    public static let advancedColorOrder = ["enabled", "red", "green", "blue", "hue start", "hue end", "saturation start", "saturation end",
                                            "smoothness", "hue change", "saturation change", "lightness change"]

    /// The read without the alias names, so `get`, snapshots and revert see each Capture One value once.
    static func droppingAliases(_ result: ReadResult) -> ReadResult {
        guard case .state(var state) = result else { return result }
        for alias in aliases.keys {
            state.adjustments[alias] = nil
            for index in state.layers.indices {
                guard case .object(var adjustments)? = state.layers[index]["adjustments"] else { continue }
                adjustments[alias] = nil
                state.layers[index]["adjustments"] = .object(adjustments)
            }
        }
        return .state(state)
    }

    public init(terminology: Terminology, bounds: BoundsTable) {
        for section in Section.allCases {
            for property in terminology.properties(ofClass: section.classCode) where property.writable {
                sdefWritable[section, default: []].insert(property.name)
                if let allowed = Self.allowed[section], !allowed.contains(property.name) { continue }
                if section == .adjustments, Self.aliases[property.name] != nil { continue }
                let kind: FieldSpec.Kind
                switch property.type {
                case "real": kind = .real
                case "integer": kind = .integer
                case "boolean": kind = .boolean
                case "text": kind = .text
                case "RGB color": kind = .rgb
                case "rectangle": kind = .rectangle
                case "curve": kind = .curve
                case let type?:
                    guard let enumerators = terminology.enumerators(type) else { continue }
                    kind = .enumeration(enumerators)
                case nil:
                    continue
                }
                let bound = bounds.fields[section.rawValue]?[property.name]
                if bound == nil, [.real, .integer, .rgb].contains(kind) {
                    unmeasured[section, default: []].insert(property.name)
                    continue
                }
                fields[section, default: [:]][property.name] = FieldSpec(name: property.name, code: property.code, kind: kind, bound: bound)
            }
        }
    }

    /// The field's spec and the value to send; throws `invalid-arguments` naming what is wrong.
    /// `label` names the value in errors when its place in `set` is not `<section>.<name>`.
    public func validate(_ section: Section, _ name: String, _ value: JSONValue, layerAdjustments: Bool = false, label: String? = nil) throws -> FieldValue {
        let place = layerAdjustments ? "a layer's adjustments" : section.rawValue
        if layerAdjustments, Self.geometryFields.contains(name) {
            throw C1Failure(.invalidArguments, "\(name) is geometry, which belongs to the variant's adjustments, not a layer's.")
        }
        guard let spec = fields[section]?[name] else {
            if section == .adjustments, let kept = Self.aliases[name] {
                throw C1Failure(.invalidArguments, "\(place).\(name) is \(kept) negated, one Capture One value under two names; set \(kept) instead.")
            }
            if unmeasured[section]?.contains(name) == true {
                throw C1Failure(.invalidArguments, "\(place).\(name) has no measured bounds on this build, so c1 does not write it.")
            }
            let known = (fields[section] ?? [:]).keys.sorted()
            throw C1Failure(.invalidArguments, "\(place) has no writable field \"\(name)\"; writable: \(known.joined(separator: ", ")).")
        }
        func fail(_ expected: String) -> C1Failure {
            C1Failure(.invalidArguments, "\(label ?? "\(place).\(name)") must be \(expected), got \(value.encoded()).")
        }
        func number(_ item: JSONValue, integral: Bool) throws -> Double {
            guard let number = item.number, number.isFinite, !integral || item.wholeNumber != nil else {
                throw fail(integral ? "an integer" : "a number")
            }
            if let bound = spec.bound, !bound.accepts(number) { throw fail(bound.description) }
            return number
        }
        switch spec.kind {
        case .real:
            return FieldValue(spec, .double(try number(value, integral: false)))
        case .integer:
            return FieldValue(spec, .int(Int64(try number(value, integral: true))))
        case .boolean:
            guard case .bool = value else { throw fail("true or false") }
            return FieldValue(spec, value)
        case .text:
            guard case .string = value else { throw fail("text") }
            return FieldValue(spec, value)
        case .enumeration(let enumerators):
            guard case .string(let text) = value, enumerators[text] != nil else {
                throw fail("one of \(enumerators.keys.sorted().joined(separator: ", "))")
            }
            return FieldValue(spec, value)
        case .rgb:
            guard case .array(let items) = value, items.count == 3 else { throw fail("three integers") }
            return FieldValue(spec, .array(try items.map { .int(Int64(try number($0, integral: true))) }))
        case .rectangle:
            guard case .array(let items) = value, items.count == 4 else {
                throw fail("[centre x, centre y, width, height] in whole pixels")
            }
            let numbers = try items.map { item -> Int64 in
                guard let number = item.wholeNumber else { throw fail("[centre x, centre y, width, height] in whole pixels") }
                return number
            }
            guard numbers[2] >= 1, numbers[3] >= 1 else { throw fail("a rectangle at least 1 pixel wide and high") }
            return FieldValue(spec, .array(numbers.map(JSONValue.int)))
        case .curve:
            let expected = "\(Self.curvePoints.lowerBound)–\(Self.curvePoints.upperBound) [x, y] points within 0–100, x increasing by more than \(format(Self.curveGap))"
            guard case .array(let items) = value, Self.curvePoints.contains(items.count) else { throw fail(expected) }
            let points = try items.map { item -> [Double] in
                guard case .array(let pair) = item, pair.count == 2,
                      let x = pair[0].number, let y = pair[1].number, (0...100).contains(x), (0...100).contains(y) else { throw fail(expected) }
                return [x, y]
            }
            guard zip(points, points.dropFirst()).allSatisfy({ $1[0] - $0[0] > Self.curveGap }) else { throw fail(expected) }
            return FieldValue(spec, .array(points.map { .array($0.map(JSONValue.double)) }))
        }
    }
}
