import Foundation

/// Every `action`, with whether it destroys mask pixels and the arguments it takes.
/// A destructive action runs only on a layer c1 created, because mask pixels cannot be read back,
/// so no snapshot can restore them (#53).
public enum Action: String, CaseIterable {
    case layerCreate = "layer.create"
    case layerDelete = "layer.delete"
    case styleApply = "style.apply"
    case maskClear = "mask.clear"
    case maskFill = "mask.fill"
    case maskInvert = "mask.invert"
    case maskRasterize = "mask.rasterize"
    case maskFeather = "mask.feather"
    case maskRefine = "mask.refine"
    case maskCopy = "mask.copy"
    case maskPeople = "mask.people"
    case lumaClear = "luma.clear"
    case colorCreate = "color.create"
    case colorDelete = "color.delete"
    case dehazePick = "dehaze.pick"
    case dehazeRecalculate = "dehaze.recalculate"
    case lensReset = "lens.reset"
    case variantReset = "variant.reset"

    /// `layer.delete` and the seven mask actions that overwrite pixels; `mask.copy` overwrites its destination.
    public var destructive: Bool {
        switch self {
        case .layerDelete, .maskClear, .maskFill, .maskInvert, .maskRasterize, .maskFeather, .maskRefine, .maskCopy: return true
        default: return false
        }
    }

    public var arguments: [String] {
        switch self {
        case .layerCreate: return ["kind", "name"]
        case .layerDelete, .maskClear, .maskFill, .maskInvert, .maskRasterize, .lumaClear: return ["layer"]
        case .maskFeather, .maskRefine: return ["layer", "amount"]
        case .maskCopy: return ["layer", "source"]
        case .maskPeople: return ["areas", "separateLayers"]
        case .styleApply: return ["layer", "name"]
        case .colorCreate, .dehazeRecalculate: return ["layer"]
        case .colorDelete: return ["layer", "color"]
        case .dehazePick: return ["layer", "point"]
        case .lensReset, .variantReset: return []
        }
    }

    /// Layer actions that default to the background when `layer` is omitted.
    var layerDefaultsToBackground: Bool {
        [.styleApply, .colorCreate, .colorDelete, .dehazePick, .dehazeRecalculate].contains(self)
    }

    public var summary: String {
        switch self {
        case .layerCreate: return "Create a layer (kind: adjustment, filled, clone, heal, subject mask, background mask) tagged as c1's; returns its tag."
        case .layerDelete: return "Delete a layer c1 created."
        case .styleApply: return "Apply an installed style to a layer (default: the background)."
        case .maskClear: return "Clear the mask of a layer c1 created."
        case .maskFill: return "Fill the mask of a layer c1 created."
        case .maskInvert: return "Invert the mask of a layer c1 created."
        case .maskRasterize: return "Rasterize the mask of a layer c1 created."
        case .maskFeather: return "Feather the mask of a layer c1 created by amount 0–100."
        case .maskRefine: return "Refine the mask of a layer c1 created by amount 0–300."
        case .maskCopy: return "Copy the mask of source onto layer, a layer c1 created."
        case .maskPeople: return "Create people masks for areas on new layers tagged as c1's."
        case .lumaClear: return "Clear a layer's luma range."
        case .colorCreate: return "Add an advanced color correction to a layer (default: the background)."
        case .colorDelete: return "Delete an advanced color correction by position from a layer (default: the background)."
        case .dehazePick: return "Pick the dehaze color at point [x, y] in image pixels."
        case .dehazeRecalculate: return "Recalculate the dehaze color."
        case .lensReset: return "Reset lens correction."
        case .variantReset: return "Reset every adjustment; Capture One also deletes every layer, so it is refused while a layer is not c1's."
        }
    }

    static let maskAmounts: [Action: ClosedRange<Double>] = [.maskFeather: 0...100, .maskRefine: 0...300]
    static let layerKinds = ["adjustment", "filled", "clone", "heal", "subject mask", "background mask"]
    static let peopleAreas = ["body skin", "face skin", "eyebrows", "lips", "hair", "iris and pupil", "sclera", "clothes"]

    /// Arguments checked without Capture One; layers stay references until a variant's layers are known.
    struct Request {
        let action: Action
        let layer: LayerRef?
        let source: LayerRef?
        let values: [String: JSONValue]
    }

    func request(_ values: [String: JSONValue]) throws -> Request {
        let unknown = values.keys.filter { !arguments.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw C1Failure(.invalidArguments, "\(rawValue) does not take \(unknown.joined(separator: ", ")); it takes \(arguments.isEmpty ? "no arguments" : arguments.joined(separator: ", ")).")
        }
        func fail(_ message: String) -> C1Failure { C1Failure(.invalidArguments, "\(rawValue): \(message)") }
        func layerRef(_ key: String) throws -> LayerRef? {
            guard let value = values[key] else { return nil }
            guard let ref = try? JSONDecoder().decode(LayerRef.self, from: Data(value.encoded().utf8)) else {
                throw fail("\(key) is a layer index, exact name or c1 tag, got \(value.encoded()).")
            }
            return ref
        }
        let layer = try layerRef("layer"), source = try layerRef("source")
        if arguments.contains("layer"), !layerDefaultsToBackground, layer == nil { throw fail("needs layer.") }
        switch self {
        case .layerCreate:
            if let kind = values["kind"], !(kind.string.map(Self.layerKinds.contains) ?? false) {
                throw fail("kind must be one of \(Self.layerKinds.joined(separator: ", ")).")
            }
            if let name = values["name"], name.string?.isEmpty != false { throw fail("name must be non-empty text.") }
        case .maskFeather, .maskRefine:
            let range = Self.maskAmounts[self]!
            guard let amount = values["amount"]?.number, amount.isFinite, range.contains(amount) else {
                throw fail("amount must be a number within \(format(range.lowerBound))…\(format(range.upperBound)).")
            }
        case .maskCopy:
            guard source != nil else { throw fail("needs source, the layer whose mask is copied.") }
        case .maskPeople:
            guard case .array(let areas)? = values["areas"], !areas.isEmpty,
                  areas.allSatisfy({ $0.string.map(Self.peopleAreas.contains) ?? false }) else {
                throw fail("areas must be a non-empty list from \(Self.peopleAreas.joined(separator: ", ")).")
            }
            if let separate = values["separateLayers"], case .bool = separate {} else if values["separateLayers"] != nil {
                throw fail("separateLayers must be true or false.")
            }
        case .styleApply:
            guard values["name"]?.string?.isEmpty == false else { throw fail("needs name, an installed style.") }
        case .colorDelete:
            guard let color = values["color"]?.number, color >= 0, color.rounded() == color else {
                throw fail("color must be the correction's position, 0 or more.")
            }
        case .dehazePick:
            guard case .array(let point)? = values["point"], point.count == 2, point.allSatisfy({ $0.number?.isFinite == true }) else {
                throw fail("point must be [x, y] in image pixels.")
            }
        default:
            break
        }
        return Request(action: self, layer: layer, source: source, values: values)
    }
}

extension Action.Request {
    /// The step for one variant, or why it is refused. `tags` supplies new layers' tags.
    func step(for state: VariantState, tags: [String]) -> Result<ActionStep, Refusal> {
        func resolve(_ ref: LayerRef?) -> Result<Int, Refusal> { (ref ?? .index(0)).resolve(in: state.layers) }
        func name(_ index: Int) -> String { state.layers[index]["name"]?.string ?? "layer \(index)" }
        func editable(_ index: Int) -> Refusal? {
            if index == 0 { return "\(action.rawValue) cannot act on the background layer." }
            if LayerTag.of(name(index)) == nil {
                return "\(action.rawValue) destroys mask pixels, which c1 cannot restore, so it runs only on layers c1 created; \"\(name(index))\" is the photographer's."
            }
            return nil
        }
        func layerStep(_ make: (Int) -> ActionStep) -> Result<ActionStep, Refusal> {
            resolve(layer).flatMap { index in
                if action.destructive, let refusal = editable(index) { return .failure(refusal) }
                if !action.layerDefaultsToBackground, index == 0 { return .failure("\(action.rawValue) needs a layer other than the background.") }
                return .success(make(index))
            }
        }
        switch action {
        case .layerCreate:
            let base = values["name"]?.string ?? "c1"
            return .success(.createLayer(kind: values["kind"]?.string ?? "adjustment", name: LayerTag.name(base, tag: tags[0])))
        case .layerDelete: return layerStep { .deleteLayer($0) }
        case .maskClear: return layerStep { .layerCommand("clear mask", layer: $0) }
        case .maskFill: return layerStep { .layerCommand("fill mask", layer: $0) }
        case .maskInvert: return layerStep { .layerCommand("invert mask", layer: $0) }
        case .maskRasterize: return layerStep { .layerCommand("rasterize mask", layer: $0) }
        case .lumaClear: return layerStep { .layerCommand("clear luma range", layer: $0) }
        case .maskFeather: return layerStep { .maskAmount("feather mask", layer: $0, amount: values["amount"]!.number!) }
        case .maskRefine: return layerStep { .maskAmount("refine mask", layer: $0, amount: values["amount"]!.number!) }
        case .maskCopy:
            return resolve(source).flatMap { from in layerStep { .copyMask(from: from, to: $0) } }
        case .maskPeople:
            guard case .array(let areas)? = values["areas"] else { return .failure("areas missing") }
            return .success(.peopleMask(areas: areas.compactMap(\.string), separateLayers: values["separateLayers"] == .bool(true), tags: tags))
        case .styleApply: return layerStep { .applyStyle(layer: $0, name: values["name"]!.string!) }
        case .colorCreate: return layerStep { .createColor(layer: $0) }
        case .colorDelete: return layerStep { .deleteColor(layer: $0, index: Int(values["color"]!.number!)) }
        case .dehazePick: return layerStep { .pickDehaze(layer: $0, point: values["point"]!.array!.compactMap(\.number)) }
        case .dehazeRecalculate: return layerStep { .recalculateDehaze(layer: $0) }
        case .lensReset: return .success(.resetLens)
        case .variantReset:
            let untagged = state.layers.indices.dropFirst().filter { LayerTag.of(name($0)) == nil }.map(name)
            guard untagged.isEmpty else {
                return .failure("variant.reset makes Capture One delete every layer, and \(untagged.map { "\"\($0)\"" }.joined(separator: ", ")) \(untagged.count == 1 ? "is" : "are") the photographer's.")
            }
            return .success(.resetVariant)
        }
    }
}

extension JSONValue {
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}
