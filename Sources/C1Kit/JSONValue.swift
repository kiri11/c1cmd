import Foundation

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// Equality that treats integers and reals as numbers and allows a small difference,
    /// because Capture One reports 32-bit floats as 64-bit reals.
    public func approximatelyEquals(_ other: JSONValue, tolerance: Double = 1e-5) -> Bool {
        if let a = number, let b = other.number { return abs(a - b) <= tolerance * max(1, abs(a), abs(b)) }
        switch (self, other) {
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.approximatelyEquals($1, tolerance: tolerance) }
        case (.object(let a), .object(let b)):
            return a.keys == b.keys && a.allSatisfy { key, value in value.approximatelyEquals(b[key]!, tolerance: tolerance) }
        default:
            return self == other
        }
    }

    /// The value with every object member whose value is null left out, at any depth; nulls in lists stay.
    public func droppingNulls() -> JSONValue {
        switch self {
        case .object(let members): return .object(members.filter { $0.value != .null }.mapValues { $0.droppingNulls() })
        case .array(let items): return .array(items.map { $0.droppingNulls() })
        default: return self
        }
    }

    public func encoded(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
