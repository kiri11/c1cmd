import C1Kit
import Foundation

/// Each command's argument spec against the Codable struct that decodes it, both ways: the struct's stored
/// properties are exactly the spec's keys with matching types and optionality, and JSON built from the spec
/// decodes while a missing required key or a wrongly typed value fails.
enum SpecTests {
    static func run() {
        for command in Command.allCases { check(command) }
        checkEqual(Command.allCases.filter { !$0.readOnly }, [.set, .action, .revert], "only set, action and revert change variants")
        help()
    }

    /// Help comes from the table alone: FakeCaptureOne is never asked, as with Capture One absent.
    static func help() {
        for command in Command.allCases {
            let help = command.help
            let flat = help.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            C1KitTests.check(flat.contains(command.summary) && command.arguments.allSatisfy { help.contains("  \($0.name)  (") },
                             "\(command.rawValue) --help names its summary and every argument")
            C1KitTests.check(Command.overview.contains("  \(command.rawValue) "), "c1 --help lists \(command.rawValue)")
            C1KitTests.check((try? command.decodeArguments(Data(command.example.utf8))) != nil, "\(command.rawValue)'s example decodes")
        }
        let set = Command.set.help
        C1KitTests.check(set.contains("adjustments.exposure") && set.contains("number within -4…4"), "set --help gives exposure's measured range")
        C1KitTests.check(set.contains("adjustments.curves.luma") && set.contains("layers[].opacity"), "set --help lists curves and layer fields")
        C1KitTests.check(!set.contains("variant.pick"), "set --help leaves out fields c1 does not write")
        C1KitTests.check(Command.action.help.contains("variant.reset"), "action --help lists the actions")
    }

    static func sample(_ kind: Argument.Kind) -> JSONValue {
        switch kind {
        case .integer(let range): return .int(Int64(range?.lowerBound ?? 1))
        case .number(let range): return .double(range?.upperBound ?? 1)
        case .boolean: return .bool(true)
        case .text: return .string("x")
        case .variantID, .collectionID: return .string("1")
        case .layer: return .int(1)
        case .list(let item, let count): return .array(Array(repeating: sample(item), count: count?.lowerBound ?? 1))
        case .enumeration(let values): return .string(values[0])
        case .object(let keys): return sample(keys)
        case .fields: return .object([:])
        }
    }

    static func sample(_ spec: [Argument]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: spec.map { ($0.name, sample($0.kind)) }))
    }

    /// A value of the wrong JSON type for the kind.
    static func wrong(_ kind: Argument.Kind) -> JSONValue {
        switch kind {
        case .integer, .number, .boolean: return .string("x")
        case .text, .enumeration, .variantID, .collectionID, .list, .object, .fields: return .int(1)
        case .layer: return .bool(true)
        }
    }

    /// Swift type names that may decode the kind; nil accepts any struct, whose keys are checked by recursion.
    static func swiftTypes(_ kind: Argument.Kind) -> [String]? {
        switch kind {
        case .integer: return ["Int"]
        case .number: return ["Double"]
        case .boolean: return ["Bool"]
        case .text: return ["String"]
        case .variantID: return ["NumericID<VariantTag>"]
        case .collectionID: return ["NumericID<CollectionTag>"]
        case .layer: return ["LayerRef"]
        case .enumeration: return ["String", "RevertScope"]
        case .fields: return ["Dictionary<String, JSONValue>"]
        case .object: return nil
        case .list(let item, _): return swiftTypes(item).map { $0.map { "Array<\($0)>" } }
        }
    }

    static func check(_ command: Command) {
        let name = command.rawValue
        let spec = command.arguments
        func decodes(_ value: JSONValue) -> Bool { (try? command.decodeArguments(Data(value.encoded().utf8))) != nil }
        let full = sample(spec)
        guard let decoded = try? command.decodeArguments(Data(full.encoded().utf8)) else {
            return C1KitTests.check(false, "\(name): the spec's sample \(full.encoded()) does not decode")
        }
        checkMirror(decoded, spec, path: name)

        // Each key at each depth: dropping it fails exactly when required, and a wrong type always fails.
        func trials(_ spec: [Argument], _ object: [String: JSONValue], path: String, wrap: @escaping ([String: JSONValue]) -> JSONValue) {
            for argument in spec {
                var without = object; without[argument.name] = nil
                checkEqual(decodes(wrap(without)), !argument.required, "\(path).\(argument.name) dropped")
                var bad = object; bad[argument.name] = wrong(argument.kind)
                C1KitTests.check(!decodes(wrap(bad)), "\(path).\(argument.name) as \(wrong(argument.kind).encoded()) should not decode")
                switch argument.kind {
                case .object(let keys):
                    trials(keys, sample(keys).objectValue!, path: "\(path).\(argument.name)") { inner in
                        var outer = object; outer[argument.name] = .object(inner); return wrap(outer)
                    }
                case .list(.object(let keys), _):
                    trials(keys, sample(keys).objectValue!, path: "\(path).\(argument.name).0") { inner in
                        var outer = object; outer[argument.name] = .array([.object(inner)]); return wrap(outer)
                    }
                default:
                    break
                }
            }
        }
        trials(spec, full.objectValue!, path: name) { .object($0) }
        C1KitTests.check(!decodes(.object(full.objectValue!.merging(["bogus": .int(1)]) { $1 })), "\(name) rejects a key outside the spec")
    }

    /// The decoded struct's stored properties against the spec: same keys, types and optionality.
    static func checkMirror(_ value: Any, _ spec: [Argument], path: String) {
        let children = Mirror(reflecting: value).children.compactMap { child in child.label.map { ($0, child.value) } }
        checkEqual(Set(children.map(\.0)), Set(spec.map(\.name)), "\(path): the struct's keys against the spec's")
        for (label, child) in children {
            guard let argument = spec.first(where: { $0.name == label }) else { continue }
            var typeName = String(describing: type(of: child))
            let optional = typeName.hasPrefix("Optional<")
            checkEqual(optional, !argument.required, "\(path).\(label) is optional exactly when the spec says so")
            if optional { typeName = String(typeName.dropFirst("Optional<".count).dropLast()) }
            if let accepted = swiftTypes(argument.kind) {
                C1KitTests.check(accepted.contains(typeName), "\(path).\(label): spec \(argument.type) but Swift \(typeName)")
            }
            let unwrapped: Any? = optional ? Mirror(reflecting: child).children.first?.value : child
            switch argument.kind {
            case .object(let keys):
                if let unwrapped { checkMirror(unwrapped, keys, path: "\(path).\(label)") }
            case .list(.object(let keys), _):
                if let first = unwrapped.flatMap({ Mirror(reflecting: $0).children.first?.value }) { checkMirror(first, keys, path: "\(path).\(label).0") }
            default:
                break
            }
        }
    }
}

