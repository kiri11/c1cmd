import Foundation
import CryptoKit
import CoreFoundation

/// JSON values accepted by the typed native editing surface. Curves are flat x,y pairs.
public enum NativeValue: Codable, Equatable {
    case unset, number(Double), text(String), boolean(Bool), numbers([Double]), texts([String])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .unset }
        else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else if let v = try? c.decode([Double].self) { self = .numbers(v) }
        else { self = .texts(try c.decode([String].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .unset: try c.encodeNil(); case .number(let v): try c.encode(v); case .text(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v); case .numbers(let v): try c.encode(v); case .texts(let v): try c.encode(v) }
    }
    var descriptor: NSAppleEventDescriptor {
        switch self { case .unset: return .missingValue(); case .number(let v): return .init(double: v); case .text(let v): return .init(string: v)
        case .boolean(let v): return .init(boolean: v); case .numbers(let v): return .init(list: v.map { .init(double: $0) }); case .texts(let v): return .init(list: v.map { .init(string:$0) }) }
    }
    func matches(_ other: NativeValue, tolerance: Double = 0.0001) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): return abs(a-b) <= tolerance
        case (.numbers(let a), .numbers(let b)): return a.count == b.count && zip(a,b).allSatisfy { abs($0-$1) <= tolerance }
        default: return self == other
        }
    }
}

public struct NativeTarget: Codable, Equatable {
    public let scope: String
    public let layer: Int
    public let element: Int
    public init(scope: String = "adjustments", layer: Int = 0, element: Int = 0) {
        self.scope = scope; self.layer = layer; self.element = element
    }
    func validate() throws {
        guard NativeEditing.fields[scope] != nil, (0...10000).contains(layer), (0...10000).contains(element),
              !["layer", "luma"].contains(scope) || layer > 0,
              !["lens", "variant"].contains(scope) || layer == 0,
              ["basicColor", "advancedColor"].contains(scope) ? element > 0 : element == 0 else {
            throw C1Error.invalidRequest("Invalid native target. Layers and color elements use 1-based indices; layer 0 means the image adjustments.")
        }
    }
    var descriptors: [NSAppleEventDescriptor] { [.init(string: scope), .init(int32: Int32(layer)), .init(int32: Int32(element))] }
}
public struct NativeField: Codable {
    public let name: String
    public let type: String
    public let writable: Bool
    public let values: [String]
    public let route: String
}
public struct NativeLayer: Codable, Equatable {
    public let nativeName: String
    public let nativeKind: String
    public let nativeOpacity: Int
    public let nativeEnabled: Bool
}
struct NativeWireRow: Decodable {
    let fieldName: String
    let numbersVal: [Double]?
    let textVal: String?
    let boolVal: Bool?
    let unavailable: String?
}
struct NativeWireSnapshot: Decodable {
    let nativeRows: [NativeWireRow]
    let nativeLayers: [NativeLayer]
    let basicColorCount: Int
    let advancedColorCount: Int
}
public struct NativeSnapshot: Codable, Equatable {
    public let ref: String
    public let target: NativeTarget
    public let values: [String: NativeValue]
    public let unavailable: [String: String]
    public let layers: [NativeLayer]
    public let basicColorCount: Int
    public let advancedColorCount: Int
    public let nativeStateHash: String
}
public struct NativeMutationResult: Codable {
    public let operationId: String
    public let before: NativeSnapshot
    public let after: NativeSnapshot
    public let dryRun: Bool
}

public enum NativeEditing {
    public static let fields: [String: [NativeField]] = {
        // Missing/corrupt package resources fail closed with an empty capability set.
        guard let url = Bundle.module.url(forResource: "NativeEditing", withExtension: "json"),
              let data = try? Data(contentsOf: url), let fields = try? JSONDecoder().decode([String: [NativeField]].self, from: data) else { return [:] }
        return fields
    }()
    public static func parseValues(_ data: Data) throws -> [String: NativeValue] {
        do { return try JSONDecoder().decode([String: NativeValue].self, from: data) }
        catch { throw C1Error.invalidRequest("Native values must be a JSON object containing typed scalar values or arrays.") }
    }
    public static func parsePatch(_ data: Data, target: NativeTarget) throws -> [String: NativeValue] {
        let patch = try parseValues(data)
        try validate(patch, target: target)
        return patch
    }
    /// Native color wheels quantize hue at the current saturation. Establish a
    /// requested saturation first; never synthesize writes to omitted controls.
    public static func orderedPatchKeys(_ patch: [String: NativeValue], target: NativeTarget) -> [String] {
        var keys = patch.keys.sorted()
        guard target.scope == "adjustments" else { return keys }
        for band in ["master", "shadow", "midtone", "highlight"] {
            let hue = "color balance \(band) hue", saturation = "color balance \(band) saturation"
            if let h = keys.firstIndex(of: hue), let s = keys.firstIndex(of: saturation), h < s {
                keys.remove(at: s)
                keys.insert(saturation, at: h)
            }
        }
        return keys
    }

    public static func matchesReadback(field: String, expected: NativeValue, actual: NativeValue) -> Bool {
        let tolerance = field == "temperature" ? 0.1 : field == "tint" ? 0.01 : 0.0001
        if ["master", "shadow", "midtone", "highlight"].contains(where: { field == "color balance \($0) hue" }),
           case .number(let wanted) = expected, case .number(let observed) = actual,
           (0...360).contains(wanted), (0...360).contains(observed) {
            let distance = abs(wanted - observed)
            return min(distance, 360 - distance) <= tolerance
        }
        return expected.matches(actual, tolerance: tolerance)
    }

    public static func validate(_ patch: [String: NativeValue], target: NativeTarget) throws {
        try target.validate()
        guard !patch.isEmpty else { throw C1Error.invalidRequest("Native patch must not be empty.") }
        for (name, value) in patch {
            guard let field = fields[target.scope]?.first(where: { $0.name == name }), field.writable else {
                throw C1Error.invalidRequest("Field '\(name)' is unknown or read-only here. Use geometry_set for guarded crop/rotation/keystone edits; orientation and flip remain blocked.")
            }
            var valid = false
            switch value {
            case .number(let n): valid = n.isFinite && (["real", "integer"].contains(field.type)) && (field.type != "integer" || n.rounded() == n)
            case .boolean: valid = field.type == "boolean"
            case .text(let t): valid = field.type == "text" || field.values.contains(t)
            case .unset, .texts: valid = false
            case .numbers(let ns):
                if field.type == "RGB color" { valid = ns.count == 3 && ns.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 65535 && $0.rounded() == $0 } }
                if field.type == "curve" {
                    valid = ns.count >= 4 && ns.count <= 128 && ns.count % 2 == 0 && ns.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 }
                    if valid {
                        let xs = stride(from: 0, to: ns.count, by: 2).map { ns[$0] }
                        valid = zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }
                    }
                }
            }
            guard valid else { throw C1Error.invalidRequest("Invalid value for native \(target.scope).\(name) (\(field.type)).") }
            // Use demonstrated bounds where retained. Unspecified native ranges are checked by readback.
            if case .number(let n) = value {
                let ranges: [String: ClosedRange<Double>] = ["exposure": -4...4, "contrast": -50...50, "saturation": -100...100,
                    "temperature": 800...14000, "tint": -50...50, "opacity": 1...100, "distortion": 0...100]
                if let range = ranges[name], !range.contains(n) { throw C1Error.invalidRequest("Native \(name) outside \(range).") }
            }
        }
    }
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try e.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public static var targetSchema: [String: Any] {
        ContractSchema.object(["scope": ["type":"string", "enum":fields.keys.sorted()], "layer":["type":"integer", "minimum":0, "maximum":10000], "element":["type":"integer", "minimum":0, "maximum":10000]], required:["scope"])
    }
    public static func target(_ value: Any?) throws -> NativeTarget {
        guard let d = value as? [String: Any], Set(d.keys).isSubset(of: ["scope", "layer", "element"]) else {
            throw C1Error.invalidRequest("Provide a native target object with scope and optional layer/element indices.")
        }
        for key in ["layer", "element"] where d[key] != nil {
            guard let n = d[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0,
                  n.doubleValue <= 10000, n.doubleValue.rounded() == n.doubleValue else { throw C1Error.invalidRequest("Invalid target index.") }
        }
        let result = NativeTarget(scope: d["scope"] as? String ?? "", layer: d["layer"] as? Int ?? 0, element: d["element"] as? Int ?? 0)
        try result.validate(); return result
    }
}

extension NativeEditing {
    public static let actions: [String: String] = [
        "mask.people":"adjustments", "layer.create":"adjustments", "layer.delete":"layer", "mask.clear":"layer", "mask.invert":"layer", "mask.fill":"layer",
        "mask.rasterize":"layer", "mask.feather":"layer", "mask.refine":"layer", "mask.copy":"layer", "luma.clear":"layer",
        "style.apply":"layer", "color.create":"adjustments", "color.delete":"advancedColor", "dehaze.pick":"adjustments",
        "dehaze.recalculate":"adjustments", "lens.reset":"lens"
    ]
    public static func validateAction(_ action: String, target: NativeTarget, arguments: [String: NativeValue]) throws {
        try target.validate()
        guard actions[action] == target.scope else { throw C1Error.invalidRequest("Action \(action) is unavailable for \(target.scope).") }
        let required: Set<String>
        switch action {
        case "mask.people": required = ["areas", "separateLayers"]
        case "layer.create": required = ["name", "kind"]
        case "mask.feather", "mask.refine": required = ["amount"]
        case "mask.copy": required = ["sourceLayer"]
        case "style.apply": required = ["name"]
        case "dehaze.pick": required = ["point"]
        default: required = []
        }
        guard Set(arguments.keys) == required else { throw C1Error.invalidRequest("\(action) requires exactly: \(required.sorted().joined(separator: ", ")).") }
        for (key,value) in arguments {
            var valid = false
            switch (key,value) {
            case ("areas", .texts(let areas)): valid = !areas.isEmpty && Set(areas).count == areas.count && Set(areas).isSubset(of:["body skin","face skin","eyebrows","lips","hair","iris and pupil","sclera","clothes"])
            case ("separateLayers", .boolean): valid = true
            case ("name", .text(let s)): valid = !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case ("kind", .text(let s)): valid = ["adjustment","filled","clone","heal","subject mask","background mask"].contains(s)
            case ("amount", .number(let n)): valid = n.isFinite && n >= 0 && n <= (action == "mask.refine" ? 300 : 100)
            case ("sourceLayer", .number(let n)): valid = n.isFinite && n >= 1 && n <= 10000 && n.rounded() == n && Int(n) != target.layer
            case ("point", .numbers(let n)): valid = n.count == 2 && n.allSatisfy { $0.isFinite && $0 >= 0 }
            default: break
            }
            guard valid else { throw C1Error.invalidRequest("Invalid \(action) argument \(key).") }
        }
    }
}

extension NativeEditing {
    public static var valueSchema: [String: Any] { ["anyOf":[["type":"null"], ["type":"number"], ["type":"boolean"], ["type":"string"], ["type":"array", "items":["type":"number"]], ["type":"array", "items":["type":"string"]]]] }
    public static func input(_ tool: String) -> [String: Any] {
        let string: [String:Any] = ["type":"string"]
        var props: [String:Any] = ["target":targetSchema]
        props["workingRef"] = string; props["ifNativeState"] = string; props["dryRun"] = ["type":"boolean"]
        var required = ["workingRef","ifNativeState","target"]
        if tool == "native_set" {
            props["patch"] = patchSchema; required.append("patch")
        } else {
            props["action"] = ["type":"string", "enum":actions.keys.sorted()]
            props["arguments"] = ["type":"object", "additionalProperties":valueSchema]; required.append("action")
        }
        return ContractSchema.object(props, required:required)
    }
    public static func parseTargets(_ value: Any, ref: String) throws -> [NativeTarget] {
        guard let targets = value as? [[String: Any]], (1...16).contains(targets.count) else {
            throw C1Error.invalidRequest("Provide 1...16 native targets.")
        }
        guard !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw C1Error.invalidRequest("Invalid ref") }
        return try targets.map { try target($0) }
    }
    public static func validateRequest(_ tool: String, _ args: [String:Any]) throws {
        let schema = input(tool), properties = schema["properties"] as! [String:Any]
        guard Set(args.keys).isSubset(of: Set(properties.keys)), (schema["required"] as! [String]).allSatisfy({ args[$0] != nil }) else {
            throw C1Error.invalidRequest("Missing or unknown native editing arguments.")
        }
        for key in ["ref","workingRef","ifNativeState","action"] where args[key] != nil {
            guard let s = args[key] as? String, !s.isEmpty else { throw C1Error.invalidRequest("Invalid " + key) }
        }
        let t = try target(args["target"])
        if let dry = args["dryRun"] { guard let n = dry as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw C1Error.invalidRequest("dryRun must be boolean.") } }
        if tool == "native_set" {
            guard let patch = args["patch"] as? [String:Any] else { throw C1Error.invalidRequest("patch must be a JSON object.") }
            _ = try parsePatch(JSONSerialization.data(withJSONObject:patch), target:t)
        }
        if tool == "native_action" {
            guard args["arguments"] == nil || args["arguments"] is [String:Any] else { throw C1Error.invalidRequest("arguments must be a JSON object.") }
            let data = try JSONSerialization.data(withJSONObject: args["arguments"] ?? [String:Any]())
            let values = try parseValues(data)
            try validateAction(args["action"] as! String, target:t, arguments:values)
        }
    }
}

extension NativeEditing {
    public static var snapshotSchema: [String:Any] {
        let number: [String:Any] = ["type":"integer"]
        let layer = ContractSchema.object(["nativeName":["type":"string"], "nativeKind":["type":"string"], "nativeOpacity":number, "nativeEnabled":["type":"boolean"]], required:["nativeName","nativeKind","nativeOpacity","nativeEnabled"])
        return ContractSchema.object(["ref":["type":"string"], "target":targetSchema,
            "values":["type":"object", "additionalProperties":valueSchema],
            "unavailable":["type":"object", "additionalProperties":["type":"string"]],
            "layers":["type":"array", "items":layer], "basicColorCount":number, "advancedColorCount":number,
            "nativeStateHash":["type":"string"]], required:["ref","target","values","unavailable","layers","basicColorCount","advancedColorCount","nativeStateHash"])
    }
    public static var mutationSchema: [String:Any] {
        ContractSchema.object(["operationId":["type":"string"], "before":snapshotSchema, "after":snapshotSchema, "dryRun":["type":"boolean"]], required:["operationId","before","after","dryRun"])
    }
}


extension NativeEditing {
    public static var patchSchema: [String:Any] {
        var properties: [String:Any] = [:]
        for field in fields.values.flatMap({ $0 }) where field.writable {
            var schema: [String:Any]
            switch field.type {
            case "real": schema = ["type":"number"]
            case "integer": schema = ["type":"integer"]
            case "boolean": schema = ["type":"boolean"]
            case "curve": schema = ["type":"array", "items":["type":"number", "minimum":0, "maximum":100], "minItems":4, "maxItems":128, "description":"Flat x,y point pairs, ordered by strictly increasing x, in 0...100."]
            case "RGB color": schema = ["type":"array", "items":["type":"integer", "minimum":0, "maximum":65535], "minItems":3, "maxItems":3]
            default: schema = ["type":"string"]; if !field.values.isEmpty { schema["enum"] = field.values }
            }
            properties[field.name] = schema
        }
        var schema = ContractSchema.object(properties)
        schema["minProperties"] = 1
        return schema
    }
}
