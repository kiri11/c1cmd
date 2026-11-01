import Foundation

/// A validated value for one field.
public struct FieldValue: Equatable {
    public let spec: FieldSpec
    public let value: JSONValue
    public init(_ spec: FieldSpec, _ value: JSONValue) { self.spec = spec; self.value = value }
}

/// The object a field belongs to. Layers are positions in `get`'s `layers`, 0 being the background.
public enum FieldOwner: Hashable {
    case variant, adjustments, lensCorrection
    case layer(Int)
    case layerAdjustments(Int)
    /// A basic color correction, by name, in a layer's color editor.
    case basicColor(layer: Int, name: String)
    /// An advanced color correction, by position, in a layer's color editor.
    case advancedColor(layer: Int, index: Int)

    var classCode: String {
        switch self {
        case .variant: return Section.variant.classCode
        case .adjustments, .layerAdjustments: return Section.adjustments.classCode
        case .lensCorrection: return Section.lensCorrection.classCode
        case .layer: return Section.layer.classCode
        case .basicColor: return Section.basicColor.classCode
        case .advancedColor: return Section.advancedColor.classCode
        }
    }

    /// The layer whose adjustments hold the field, 0 being the background; nil for variant, lens and layer fields.
    var adjustmentsLayer: Int? {
        switch self {
        case .adjustments: return 0
        case .layerAdjustments(let index), .basicColor(let index, _), .advancedColor(let index, _): return index
        case .variant, .lensCorrection, .layer: return nil
        }
    }
}

public struct FieldRead: Hashable {
    public let owner: FieldOwner
    public let name: String
    public let code: String
    public let kind: FieldSpec.Kind
    public init(_ owner: FieldOwner, _ spec: FieldSpec) { self.owner = owner; self.name = spec.name; self.code = spec.code; self.kind = spec.kind }

    /// Where `get` reports the field: `curves.rgb` for the rgb curve, `colorEditor.basic.<name>.<field>` and
    /// `colorEditor.advanced.<position>.<field>` for color corrections, keyed so partial results nest unambiguously.
    var components: [String] {
        func adjustments(_ layer: Int) -> [String] { layer == 0 ? ["adjustments"] : ["layers", String(layer), "adjustments"] }
        switch owner {
        case .variant: return ["variant", name]
        case .lensCorrection: return ["lensCorrection", name]
        case .layer(let index): return ["layers", String(index), name]
        case .adjustments, .layerAdjustments:
            let field = kind == .curve ? ["curves", WriteSchema.curveChannel(name)] : [name]
            return adjustments(owner.adjustmentsLayer!) + field
        case .basicColor(let layer, let color): return adjustments(layer) + ["colorEditor", "basic", color, name]
        case .advancedColor(let layer, let index): return adjustments(layer) + ["colorEditor", "advanced", String(index), name]
        }
    }
}

public struct FieldWrite: Equatable {
    public let owner: FieldOwner
    public let field: FieldValue
    public init(_ owner: FieldOwner, _ field: FieldValue) { self.owner = owner; self.field = field }
    public var read: FieldRead { FieldRead(owner, field.spec) }
}

/// A Capture One command on one variant. Layer numbers are positions in `layers`, 0 being the background.
public enum ActionStep: Equatable {
    case createLayer(kind: String, name: String)
    case deleteLayer(Int)
    /// A mask or luma command without arguments, named as in the sdef: `clear mask`, `invert mask`,
    /// `fill mask`, `rasterize mask`, `clear luma range`.
    case layerCommand(String, layer: Int)
    /// `feather mask` or `refine mask` with an amount.
    case maskAmount(String, layer: Int, amount: Double)
    case copyMask(from: Int, to: Int)
    /// New layers are renamed with one tag each, in order.
    case peopleMask(areas: [String], separateLayers: Bool, tags: [String])
    case applyStyle(layer: Int, name: String)
    case createColor(layer: Int)
    case deleteColor(layer: Int, index: Int)
    case pickDehaze(layer: Int, point: [Double])
    case recalculateDehaze(layer: Int)
    case resetLens
    case resetVariant
}

public enum Step: Equatable {
    case write(FieldWrite)
    case action(ActionStep)
}

public struct VariantWrite: Equatable {
    public let target: ReadTarget
    public let steps: [Step]
    /// Read after every step, in this order.
    public let readBack: [FieldRead]
    public init(target: ReadTarget, steps: [Step], readBack: [FieldRead]) {
        self.target = target; self.steps = steps; self.readBack = readBack
    }
}

public struct StepError: Equatable {
    public let step: Int
    public let message: String
    public init(step: Int, message: String) { self.step = step; self.message = message }
}

public enum WriteResult: Equatable {
    /// Every step ran; `readBack` follows the request, nil where Capture One gave no value.
    case done(stepErrors: [StepError], readBack: [JSONValue?], layerNames: [String])
    case notFound
    case failed(String)
}

/// The tag c1 appends to the names of layers it creates: ` [c1:<token>]`. A layer whose name lost
/// the tag, as after a rename in Capture One, is the photographer's.
public enum LayerTag {
    static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    public static func make() -> String {
        "c1:" + String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The tag a layer name ends with, as `c1:abc234`.
    public static func of(_ name: String) -> String? {
        guard name.hasSuffix("]"), let open = name.range(of: " [c1:", options: .backwards) else { return nil }
        let token = name[open.upperBound..<name.index(before: name.endIndex)]
        guard token.count == 6, token.allSatisfy(alphabet.contains) else { return nil }
        return "c1:" + token
    }

    public static func isTag(_ text: String) -> Bool { of(" [\(text)]") == text }

    public static func name(_ name: String, tag: String) -> String { "\(name) [\(tag)]" }
}

/// Why c1 will not write to one variant; the call goes on for the others.
public struct Refusal: Error, Equatable, ExpressibleByStringInterpolation {
    public let message: String
    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { message = value }
}
