import Foundation

/// A layer named by its position in `get`'s `layers` (0 is the background), its exact name, or the tag
/// `layer.create` returned (`c1:abc234`).
public enum LayerRef: Equatable, Decodable, CustomStringConvertible {
    case index(Int)
    case name(String)
    case tag(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let index = try? container.decode(Int.self) {
            guard index >= 0 else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "a layer index is 0 or more") }
            self = .index(index)
        } else {
            let text = try container.decode(String.self)
            self = LayerTag.isTag(text) ? .tag(text) : .name(text)
        }
    }

    public var description: String {
        switch self {
        case .index(let index): return "layer \(index)"
        case .name(let name): return "layer \"\(name)\""
        case .tag(let tag): return "layer \(tag)"
        }
    }

    /// The layer's position in `layers`, or why there is none.
    func resolve(in layers: [[String: JSONValue]]) -> Result<Int, Refusal> {
        func name(_ layer: [String: JSONValue]) -> String? { if case .string(let name)? = layer["name"] { return name }; return nil }
        let matches: [Int]
        switch self {
        case .index(let index):
            return index < layers.count ? .success(index) : .failure("The variant has no \(description); it has \(layers.count) layers.")
        case .name(let wanted):
            matches = layers.indices.filter { name(layers[$0]) == wanted }
        case .tag(let tag):
            matches = layers.indices.filter { name(layers[$0]).flatMap(LayerTag.of) == tag }
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure("The variant has no \(description).")
        default: return .failure("\(matches.count) layers match \(description); name it by index.")
        }
    }
}

/// `set`'s arguments: absolute values for each section, named as `get` reports them.
public struct SetArguments: Decodable {
    public let ids: [VariantID]
    public let variant: [String: JSONValue]?
    public let adjustments: [String: JSONValue]?
    public let lensCorrection: [String: JSONValue]?
    public let layers: [LayerPatch]?

    public struct LayerPatch: Decodable {
        public let layer: LayerRef
        public let enabled: Bool?
        public let opacity: Int?
        public let adjustments: [String: JSONValue]?

        enum Keys: String, CodingKey, CaseIterable { case layer, enabled, opacity, adjustments }

        public init(from decoder: Decoder) throws {
            let unknown = try decoder.singleValueContainer().decode([String: JSONValue].self).keys
                .filter { Keys(rawValue: $0) == nil }.sorted()
            guard unknown.isEmpty else {
                throw C1Failure(.invalidArguments, "A layer patch does not take \(unknown.joined(separator: ", ")); it takes layer, enabled, opacity and adjustments. c1 never renames layers.")
            }
            let container = try decoder.container(keyedBy: Keys.self)
            layer = try container.decode(LayerRef.self, forKey: .layer)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            opacity = try container.decodeIfPresent(Int.self, forKey: .opacity)
            adjustments = try container.decodeIfPresent([String: JSONValue].self, forKey: .adjustments)
        }
    }
}

/// A `set` validated against the schema; layers and color corrections are resolved per variant.
struct Patch {
    /// Variant and lens correction fields.
    var fields: [(FieldOwner, FieldValue)] = []
    var adjustments = AdjustmentsPatch()
    var layers: [(ref: LayerRef, fields: [FieldValue], adjustments: AdjustmentsPatch)] = []

    init(_ arguments: SetArguments, schema: WriteSchema) throws {
        let sections: [(Section, FieldOwner, [String: JSONValue]?)] = [
            (.variant, .variant, arguments.variant), (.lensCorrection, .lensCorrection, arguments.lensCorrection),
        ]
        for (section, owner, values) in sections {
            for (name, value) in (values ?? [:]).sorted(by: { $0.key < $1.key }) {
                fields.append((owner, try schema.validate(section, name, value)))
            }
        }
        adjustments = try AdjustmentsPatch(arguments.adjustments ?? [:], schema: schema, layer: false)
        for patch in arguments.layers ?? [] {
            var layerFields: [FieldValue] = []
            for (name, value) in [("enabled", patch.enabled.map(JSONValue.bool)), ("opacity", patch.opacity.map { .int(Int64($0)) })] {
                if let value { layerFields.append(try schema.validate(.layer, name, value)) }
            }
            let adjustments = try AdjustmentsPatch(patch.adjustments ?? [:], schema: schema, layer: true)
            guard !layerFields.isEmpty || !adjustments.isEmpty else {
                throw C1Failure(.invalidArguments, "The patch for \(patch.layer) sets nothing; give enabled, opacity or adjustments.")
            }
            layers.append((patch.layer, layerFields, adjustments))
        }
        guard !fields.isEmpty || !adjustments.isEmpty || !layers.isEmpty else {
            throw C1Failure(.invalidArguments, "set needs at least one value in variant, adjustments, lensCorrection or layers.")
        }
        let movesBounds = adjustments.fields.contains { WriteSchema.boundsFields[.adjustments]!.contains($0.spec.name) }
            || fields.contains { $0.0 == .lensCorrection && WriteSchema.boundsFields[.lensCorrection]!.contains($0.1.spec.name) }
        if movesBounds, crop != nil {
            throw C1Failure(.invalidArguments, "A crop cannot be set with rotation, keystone, orientation, flip or lens geometry, which move its bounds.",
                            hint: "Set those first, read cropBounds again with get, then set the crop.")
        }
    }

    var crop: [Double]? {
        guard let field = fields.first(where: { $0.0 == .variant && $0.1.spec.kind == .rectangle })?.1,
              case .array(let items) = field.value else { return nil }
        return items.compactMap(\.number)
    }

    /// The writes for one variant, its layers and color corrections resolved against its current state.
    func writes(for state: VariantState) -> Result<[FieldWrite], Refusal> {
        var output = fields.map { FieldWrite($0.0, $0.1) }
        switch adjustments.writes(layer: 0, in: state.adjustments) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let writes): output += writes
        }
        for layer in layers {
            switch layer.ref.resolve(in: state.layers) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let index):
                if index == 0, !layer.adjustments.isEmpty {
                    return .failure("The background's adjustments are the variant's; set them under adjustments.")
                }
                output += layer.fields.map { FieldWrite(.layer(index), $0) }
                switch layer.adjustments.writes(layer: index, in: state.layers[index]["adjustments"]?.object ?? [:]) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let writes): output += writes
                }
            }
        }
        return .success(Self.ordered(output))
    }

    /// Capture One's order: orientation, flip and keystone before rotation, which re-crops; each colour
    /// balance saturation before its hue; the crop last, after everything that moves its bounds.
    static func ordered(_ writes: [FieldWrite]) -> [FieldWrite] {
        func rank(_ write: FieldWrite) -> Int {
            let name = write.field.spec.name
            switch write.owner {
            case .variant: return name == "crop" ? 9 : 5
            case .adjustments:
                if name == "orientation" { return 0 }
                if name == "flip" { return 1 }
                if name == "keystone amount" { return 3 }
                if name.hasPrefix("keystone ") { return 2 }
                if name == "rotation" { return 4 }
                return name.hasPrefix("color balance") && name.hasSuffix(" hue") ? 6 : 5
            case .lensCorrection: return 4
            case .layer, .layerAdjustments:
                return name.hasPrefix("color balance") && name.hasSuffix(" hue") ? 8 : 7
            case .basicColor(let layer, _), .advancedColor(let layer, _):
                return layer == 0 ? 5 : 7
            }
        }
        return writes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// An `adjustments` patch: fields, curves under `curves`, and color corrections under `colorEditor`,
/// basic ones named and advanced ones by position.
struct AdjustmentsPatch {
    /// Plain fields and whole curves.
    var fields: [FieldValue] = []
    var basic: [(name: String, fields: [FieldValue])] = []
    var advanced: [(index: Int, fields: [FieldValue])] = []

    var isEmpty: Bool { fields.isEmpty && basic.isEmpty && advanced.isEmpty }

    init() {}

    init(_ values: [String: JSONValue], schema: WriteSchema, layer: Bool) throws {
        let place = layer ? "a layer's adjustments" : "adjustments"
        func fail(_ message: String) -> C1Failure { C1Failure(.invalidArguments, "\(place).\(message)") }
        func object(_ value: JSONValue, _ path: String, _ expected: String) throws -> [String: JSONValue] {
            guard let object = value.object else { throw fail("\(path) must be \(expected), got \(value.encoded()).") }
            return object
        }
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            switch name {
            case "curves":
                for (channel, points) in try object(value, "curves", "an object of curves by channel").sorted(by: { $0.key < $1.key }) {
                    guard WriteSchema.curveChannels.contains(channel), schema.fields[.adjustments]?[WriteSchema.curveField(channel)] != nil else {
                        throw fail("curves has no channel \"\(channel)\"; channels: \(WriteSchema.curveChannels.joined(separator: ", ")).")
                    }
                    fields.append(try schema.validate(.adjustments, WriteSchema.curveField(channel), points, layerAdjustments: layer, label: "\(place).curves.\(channel)"))
                }
            case "colorEditor":
                let editor = try object(value, "colorEditor", "an object with basic and advanced")
                if let unknown = editor.keys.first(where: { $0 != "basic" && $0 != "advanced" }) {
                    throw fail("colorEditor has no \"\(unknown)\"; it takes basic and advanced.")
                }
                basic = try entries(editor["basic"], .basicColor, schema: schema, place: place) { $0.string }
                advanced = try entries(editor["advanced"], .advancedColor, schema: schema, place: place) { value in
                    value.wholeNumber.flatMap { $0 >= 0 ? Int($0) : nil }
                }
            default:
                if schema.fields[.adjustments]?[name]?.kind == .curve {
                    throw fail("\(name) is set under curves, as curves.\(WriteSchema.curveChannel(name)).")
                }
                fields.append(try schema.validate(.adjustments, name, value, layerAdjustments: layer))
            }
        }
    }

    /// Color corrections addressed by `key`: a basic one's name or an advanced one's position.
    private func entries<Key: Hashable & CustomStringConvertible>(_ value: JSONValue?, _ section: Section, schema: WriteSchema, place: String,
                                                                   address: (JSONValue) -> Key?) throws -> [(Key, [FieldValue])] {
        guard let value else { return [] }
        let basic = section == .basicColor
        let key = basic ? "name" : "index"
        let path = "\(place).colorEditor.\(basic ? "basic" : "advanced")"
        let keyHelp = basic ? "name, as get reports it" : "index, its position in get's list"
        guard let items = value.array else { throw C1Failure(.invalidArguments, "\(path) must be a list of corrections, each with its \(keyHelp).") }
        var seen = Set<Key>()
        return try items.map { item in
            guard let fields = item.object, let address = fields[key].flatMap(address) else {
                throw C1Failure(.invalidArguments, "Each of \(path) needs its \(keyHelp), got \(item.encoded()).")
            }
            guard seen.insert(address).inserted else { throw C1Failure(.invalidArguments, "\(path) names \(key) \(address) twice.") }
            let values = fields.filter { $0.key != key }
            guard !values.isEmpty else { throw C1Failure(.invalidArguments, "\(path) \(address) sets nothing.") }
            if basic, "\(address)" == "all", let lightness = values["lightness change"], lightness.number != 0 {
                throw C1Failure(.invalidArguments, "\(path).all.lightness change must be 0; Capture One has no lightness for all colors.")
            }
            let order = WriteSchema.advancedColorOrder
            let sorted = values.sorted { (order.firstIndex(of: $0.key) ?? order.count, $0.key) < (order.firstIndex(of: $1.key) ?? order.count, $1.key) }
            return (address, try sorted.map { try schema.validate(section, $0.key, $0.value, label: "\(path).\(address).\($0.key)") })
        }
    }

    /// The writes for the adjustments of one layer, 0 being the background, as they now are.
    func writes(layer: Int, in adjustments: [String: JSONValue]) -> Result<[FieldWrite], Refusal> {
        let place = layer == 0 ? "The background" : "Layer \(layer)"
        var output = fields.map { FieldWrite(layer == 0 ? .adjustments : .layerAdjustments(layer), $0) }
        let editor = adjustments["colorEditor"]
        let names = editor?["basic"]?.array?.compactMap { $0["name"]?.string } ?? []
        for (name, fields) in basic {
            guard names.contains(name) else {
                return .failure("\(place) has no basic color correction \"\(name)\"; it has \(names.joined(separator: ", ")).")
            }
            output += fields.map { FieldWrite(.basicColor(layer: layer, name: name), $0) }
        }
        let count = editor?["advanced"]?.array?.count ?? 0
        for (index, fields) in advanced {
            guard index < count else {
                return .failure("\(place) has \(count) advanced color correction\(count == 1 ? "" : "s"), so none at index \(index); add one with color.create.")
            }
            output += fields.map { FieldWrite(.advancedColor(layer: layer, index: index), $0) }
        }
        return .success(output)
    }
}

extension VariantState {
    /// The adjustments of a layer, 0 being the background, whose adjustments are the variant's.
    func adjustments(ofLayer index: Int) -> [String: JSONValue]? {
        index == 0 ? adjustments : index < layers.count ? layers[index]["adjustments"]?.object : nil
    }

    /// A field's current value.
    func value(_ read: FieldRead) -> JSONValue? {
        switch read.owner {
        case .variant: return variant[read.name]
        case .lensCorrection: return lensCorrection[read.name]
        case .layer(let index): return index < layers.count ? layers[index][read.name] : nil
        case .adjustments, .layerAdjustments:
            let adjustments = adjustments(ofLayer: read.owner.adjustmentsLayer!)
            return read.kind == .curve ? adjustments?["curves"]?[WriteSchema.curveChannel(read.name)] : adjustments?[read.name]
        case .basicColor(let layer, let name):
            let corrections = adjustments(ofLayer: layer)?["colorEditor"]?["basic"]?.array ?? []
            return corrections.first { $0["name"]?.string == name }?[read.name]
        case .advancedColor(let layer, let index):
            let corrections = adjustments(ofLayer: layer)?["colorEditor"]?["advanced"]?.array ?? []
            return index < corrections.count ? corrections[index][read.name] : nil
        }
    }
}

extension FieldRead {
    var path: String { components.joined(separator: ".") }
}

/// Values as `get` nests them, with layers and advanced color corrections keyed by position and basic
/// color corrections by name.
func nest(_ values: [(FieldRead, JSONValue?)]) -> JSONValue {
    func insert(_ value: JSONValue, at path: ArraySlice<String>, into object: inout [String: JSONValue]) {
        guard let key = path.first else { return }
        if path.count == 1 { object[key] = value; return }
        var child = object[key]?.object ?? [:]
        insert(value, at: path.dropFirst(), into: &child)
        object[key] = .object(child)
    }
    var output: [String: JSONValue] = [:]
    for (read, value) in values { insert(value ?? .null, at: read.components[...], into: &output) }
    return .object(output)
}
