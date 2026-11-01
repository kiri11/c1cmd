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
        public let enabled: JSONValue?
        public let opacity: JSONValue?
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
            enabled = try container.decodeIfPresent(JSONValue.self, forKey: .enabled)
            opacity = try container.decodeIfPresent(JSONValue.self, forKey: .opacity)
            adjustments = try container.decodeIfPresent([String: JSONValue].self, forKey: .adjustments)
        }
    }
}

/// A `set` validated against the schema; layers are resolved per variant.
struct Patch {
    var fields: [(FieldOwner, FieldValue)] = []
    var layers: [(ref: LayerRef, fields: [FieldValue], adjustments: [FieldValue])] = []

    init(_ arguments: SetArguments, schema: WriteSchema) throws {
        let sections: [(Section, FieldOwner, [String: JSONValue]?)] = [
            (.variant, .variant, arguments.variant), (.adjustments, .adjustments, arguments.adjustments),
            (.lensCorrection, .lensCorrection, arguments.lensCorrection),
        ]
        for (section, owner, values) in sections {
            for (name, value) in (values ?? [:]).sorted(by: { $0.key < $1.key }) {
                fields.append((owner, try schema.validate(section, name, value)))
            }
        }
        for patch in arguments.layers ?? [] {
            var layerFields: [FieldValue] = []
            for (name, value) in [("enabled", patch.enabled), ("opacity", patch.opacity)] {
                if let value { layerFields.append(try schema.validate(.layer, name, value)) }
            }
            let adjustments = try (patch.adjustments ?? [:]).sorted(by: { $0.key < $1.key }).map {
                try schema.validate(.adjustments, $0.key, $0.value, layerAdjustments: true)
            }
            guard !layerFields.isEmpty || !adjustments.isEmpty else {
                throw C1Failure(.invalidArguments, "The patch for \(patch.layer) sets nothing; give enabled, opacity or adjustments.")
            }
            layers.append((patch.layer, layerFields, adjustments))
        }
        guard !fields.isEmpty || !layers.isEmpty else {
            throw C1Failure(.invalidArguments, "set needs at least one value in variant, adjustments, lensCorrection or layers.")
        }
        let movesBounds = fields.contains { owner, field in
            (owner == .adjustments && WriteSchema.boundsFields[.adjustments]!.contains(field.spec.name))
                || (owner == .lensCorrection && WriteSchema.boundsFields[.lensCorrection]!.contains(field.spec.name))
        }
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

    /// The writes for one variant, its layers resolved against its current state.
    func writes(for state: VariantState) -> Result<[FieldWrite], Refusal> {
        var output = fields.map { FieldWrite($0.0, $0.1) }
        for layer in layers {
            switch layer.ref.resolve(in: state.layers) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let index):
                if index == 0, !layer.adjustments.isEmpty {
                    return .failure("The background's adjustments are the variant's; set them under adjustments.")
                }
                output += layer.fields.map { FieldWrite(.layer(index), $0) }
                output += layer.adjustments.map { FieldWrite(.layerAdjustments(index), $0) }
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
            }
        }
        return writes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

extension VariantState {
    /// A field's current value; a background layer's adjustments are the variant's.
    func value(_ read: FieldRead) -> JSONValue? {
        switch read.owner {
        case .variant: return variant[read.name]
        case .adjustments: return adjustments[read.name]
        case .lensCorrection: return lensCorrection[read.name]
        case .layer(let index): return index < layers.count ? layers[index][read.name] : nil
        case .layerAdjustments(let index):
            if index == 0 { return adjustments[read.name] }
            return index < layers.count ? layers[index]["adjustments"]?[read.name] : nil
        }
    }
}

extension FieldRead {
    var path: String {
        switch owner {
        case .variant: return "variant.\(name)"
        case .adjustments: return "adjustments.\(name)"
        case .lensCorrection: return "lensCorrection.\(name)"
        case .layer(let index): return "layers.\(index).\(name)"
        case .layerAdjustments(let index): return "layers.\(index).adjustments.\(name)"
        }
    }
}

/// Values as `get` nests them, with layers keyed by position.
func nest(_ values: [(FieldRead, JSONValue?)]) -> JSONValue {
    var sections: [String: [String: JSONValue]] = [:]
    var layers: [String: [String: JSONValue]] = [:]
    var layerAdjustments: [String: [String: JSONValue]] = [:]
    for (read, value) in values {
        let value = value ?? .null
        switch read.owner {
        case .variant: sections["variant", default: [:]][read.name] = value
        case .adjustments: sections["adjustments", default: [:]][read.name] = value
        case .lensCorrection: sections["lensCorrection", default: [:]][read.name] = value
        case .layer(let index): layers[String(index), default: [:]][read.name] = value
        case .layerAdjustments(let index): layerAdjustments[String(index), default: [:]][read.name] = value
        }
    }
    for (index, adjustments) in layerAdjustments { layers[index, default: [:]]["adjustments"] = .object(adjustments) }
    var output = sections.mapValues(JSONValue.object)
    if !layers.isEmpty { output["layers"] = .object(layers.mapValues(JSONValue.object)) }
    return .object(output)
}
