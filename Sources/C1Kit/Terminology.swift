import Foundation

/// Capture One's scripting terminology, parsed from its sdef at runtime. In-process NSAppleScript
/// returns records keyed by four-char codes; this turns them back into property names.
/// Codes are not unique across the sdef, so properties resolve per class and enumerators per enumeration.
public struct Terminology {
    struct Property { let name: String; let type: String? }

    var classes: [String: [String: Property]] = [:]
    var enumerations: [String: [String: String]] = [:]

    public static let defaultSdefPath = "/Applications/Capture One.app/Contents/Resources/CaptureOne.sdef"

    public static func load(path: String = defaultSdefPath) throws -> Terminology {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw C1Failure(.scriptError, "Cannot read Capture One's scripting terminology at \(path).")
        }
        return try Terminology(sdef: data)
    }

    public init(sdef: Data) throws {
        let parser = SdefParser()
        let xml = XMLParser(data: sdef)
        xml.delegate = parser
        guard xml.parse() else {
            throw C1Failure(.scriptError, "Cannot parse Capture One's sdef: \(xml.parserError?.localizedDescription ?? "unknown error").")
        }
        enumerations = parser.enumerations
        // A class can be declared in several suites under one code (application), so merge by code.
        for parsed in parser.classes {
            classes[parsed.code, default: [:]].merge(parsed.properties) { old, _ in old }
        }
    }

    /// Decodes a descriptor; nil means drop it (an object reference, or a type with no JSON form).
    public func decode(_ descriptor: NSAppleEventDescriptor, type: String? = nil) -> JSONValue? {
        switch fourCC(descriptor.descriptorType) {
        case "list":
            guard descriptor.numberOfItems > 0 else { return .array([]) }
            return .array((1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0).flatMap { decode($0, type: type) } })
        case "reco":
            return .object(record(descriptor))
        case "utxt", "TEXT", "utf8", "itxt", "styl":
            return descriptor.stringValue.map(JSONValue.string)
        case "bool", "true", "fals":
            return .bool(descriptor.booleanValue)
        case "shor", "long", "comp", "magn", "ushr":
            return integer(descriptor).map(JSONValue.int)
        case "doub", "sing", "exte", "ldbl":
            return .double(descriptor.doubleValue)
        case "enum":
            let code = fourCC(descriptor.enumCodeValue)
            if let type, let name = enumerations[type]?[code] { return .string(name) }
            return enumerations.values.lazy.compactMap { $0[code] }.first.map(JSONValue.string) ?? .string(code)
        case "type":
            return fourCC(descriptor.typeCodeValue) == "msng" ? .null : nil
        case "msng", "null":
            return .null
        case "furl", "alis", "fsrf", "bmrk", "fss ":
            return descriptor.fileURLValue.map { .string($0.path) }
        case "ldt ":
            return descriptor.dateValue.map { .string(ISO8601DateFormatter().string(from: $0)) }
        case "qdrt":
            return shorts(descriptor, count: 4)
        case "QDpt":
            return shorts(descriptor, count: 2)
        default:
            return nil
        }
    }

    /// A record's properties by name; the class key is consumed to pick the class's terminology.
    public func record(_ descriptor: NSAppleEventDescriptor) -> [String: JSONValue] {
        guard descriptor.numberOfItems > 0 else { return [:] }
        let classCode = descriptor.forKeyword(fourCharCode("pcls")).map { fourCC($0.typeCodeValue) }
        let properties = classCode.flatMap { classes[$0] } ?? [:]
        var output: [String: JSONValue] = [:]
        for index in 1...descriptor.numberOfItems {
            let code = fourCC(descriptor.keywordForDescriptor(at: index))
            guard code != "pcls", let item = descriptor.atIndex(index) else { continue }
            let property = properties[code] ?? classes.values.lazy.compactMap { $0[code] }.first
            if let value = decode(item, type: property?.type) { output[property?.name ?? code] = value }
        }
        return output
    }

    private func integer(_ descriptor: NSAppleEventDescriptor) -> Int64? {
        guard let data = descriptor.coerce(toDescriptorType: fourCharCode("comp"))?.data, data.count == 8 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    }

    private func shorts(_ descriptor: NSAppleEventDescriptor, count: Int) -> JSONValue? {
        let data = descriptor.data
        guard data.count == count * 2 else { return nil }
        return .array((0..<count).map { index in .int(Int64(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) })) })
    }
}

func fourCC(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .macOSRoman) ?? "????"
}

func fourCharCode(_ text: String) -> FourCharCode {
    text.data(using: .macOSRoman)!.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
}

private final class SdefParser: NSObject, XMLParserDelegate {
    struct ParsedClass { let name: String; let code: String; var properties: [String: Terminology.Property] }

    var classes: [ParsedClass] = []
    var enumerations: [String: [String: String]] = [:]
    private var currentClass: ParsedClass?
    private var currentEnumeration: String?
    private var pendingProperty: (code: String, name: String, type: String?)?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "class", "record-type":
            if let name = attributes["name"], let code = attributes["code"] {
                currentClass = ParsedClass(name: name, code: code, properties: [:])
            }
        case "class-extension":
            if let extends = attributes["extends"], let base = classes.first(where: { $0.name == extends }) {
                currentClass = ParsedClass(name: base.name, code: base.code, properties: [:])
            }
        case "property":
            if currentClass != nil, let name = attributes["name"], let code = attributes["code"] {
                pendingProperty = (code, name, attributes["type"])
            }
        case "type":
            if pendingProperty?.type == nil { pendingProperty?.type = attributes["type"] }
        case "enumeration":
            currentEnumeration = attributes["name"]
            if let name = currentEnumeration { enumerations[name] = [:] }
        case "enumerator":
            if let enumeration = currentEnumeration, let name = attributes["name"], let code = attributes["code"] {
                enumerations[enumeration]?[code] = name
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "property":
            if let property = pendingProperty, currentClass?.properties[property.code] == nil {
                currentClass?.properties[property.code] = .init(name: property.name, type: property.type)
            }
            pendingProperty = nil
        case "class", "record-type", "class-extension":
            if let parsed = currentClass { classes.append(parsed) }
            currentClass = nil
        case "enumeration":
            currentEnumeration = nil
        default:
            break
        }
    }
}
