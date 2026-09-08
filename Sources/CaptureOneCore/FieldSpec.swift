import Foundation

public enum FieldOperation: String, Codable, Hashable {
    case get
    case set
    case add
    case reset
}

public struct FieldSpec: Codable, Equatable {
    public let name: String
    public let aliases: [String]
    public let type: String
    public let unit: String?
    public let minValue: Double?
    public let maxValue: Double?
    public let tolerance: Double
    public let operations: [FieldOperation]
    public let isMetadata: Bool
    public let dependencies: [String]

    public init(
        name: String,
        aliases: [String] = [],
        type: String,
        unit: String? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        tolerance: Double = 1e-5,
        operations: [FieldOperation] = [.get, .set, .add],
        isMetadata: Bool = false,
        dependencies: [String] = []
    ) {
        self.name = name
        self.aliases = aliases
        self.type = type
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.tolerance = tolerance
        self.operations = operations
        self.isMetadata = isMetadata
        self.dependencies = dependencies
    }

    public func matches(nameOrAlias: String) -> Bool {
        let lower = nameOrAlias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased() == lower { return true }
        return aliases.contains { $0.lowercased() == lower }
    }
}

public struct Adjustments: Codable, Equatable {
    public var exposure: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var temperature: Double?
    public var tint: Double?

    public init(
        exposure: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        temperature: Double? = nil,
        tint: Double? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
    }

    public var isEmpty: Bool {
        exposure == nil && contrast == nil && saturation == nil && temperature == nil && tint == nil
    }

    public var hasAnyField: Bool {
        !isEmpty
    }

    public func value(for field: String) -> Double? {
        switch field.lowercased() {
        case "exposure", "exp": return exposure
        case "contrast": return contrast
        case "saturation", "sat": return saturation
        case "temperature", "kelvin", "temp": return temperature
        case "tint": return tint
        default: return nil
        }
    }

    public mutating func setValue(_ val: Double?, for field: String) {
        switch field.lowercased() {
        case "exposure", "exp": exposure = val
        case "contrast": contrast = val
        case "saturation", "sat": saturation = val
        case "temperature", "kelvin", "temp": temperature = val
        case "tint": tint = val
        default: break
        }
    }
}

public struct Metadata: Codable, Equatable {
    public var camera: String?
    public var lens: String?
    public var iso: String?
    public var shutterSpeed: String?
    public var asShotWB: String?
    public var captureDate: String?
    public var rating: Int?
    public var colorTag: Int?

    public init(
        camera: String? = nil,
        lens: String? = nil,
        iso: String? = nil,
        shutterSpeed: String? = nil,
        asShotWB: String? = nil,
        captureDate: String? = nil,
        rating: Int? = nil,
        colorTag: Int? = nil
    ) {
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.asShotWB = asShotWB
        self.captureDate = captureDate
        self.rating = rating
        self.colorTag = colorTag
    }
}

public final class FieldRegistry {
    public static let shared = FieldRegistry()

    public let supportedAdjustmentFields: [FieldSpec]
    public let supportedMetadataFields: [FieldSpec]

    private init() {
        self.supportedAdjustmentFields = [
            FieldSpec(
                name: "exposure",
                aliases: ["exp"],
                type: "number",
                unit: "EV",
                minValue: -4.0,
                maxValue: 4.0,
                tolerance: 1e-5,
                operations: [.get, .set, .add, .reset]
            ),
            FieldSpec(
                name: "contrast",
                aliases: [],
                type: "number",
                minValue: -50.0,
                maxValue: 50.0,
                tolerance: 1e-5,
                operations: [.get, .set, .add, .reset]
            ),
            FieldSpec(
                name: "saturation",
                aliases: ["sat"],
                type: "number",
                minValue: -100.0,
                maxValue: 100.0,
                tolerance: 1e-5,
                operations: [.get, .set, .add, .reset]
            ),
            FieldSpec(
                name: "temperature",
                aliases: ["kelvin", "temp"],
                type: "number",
                unit: "K",
                minValue: 800.0,
                maxValue: 14000.0,
                tolerance: 0.05,
                operations: [.get, .set, .add, .reset],
                dependencies: ["tint"]
            ),
            FieldSpec(
                name: "tint",
                aliases: [],
                type: "number",
                minValue: -50.0,
                maxValue: 50.0,
                tolerance: 0.001,
                operations: [.get, .set, .add, .reset],
                dependencies: ["temperature"]
            )
        ]

        self.supportedMetadataFields = [
            FieldSpec(name: "camera", type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "lens", type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "iso", type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "shutterSpeed", aliases: ["shutter"], type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "asShotWB", aliases: ["asShotWhiteBalance"], type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "captureDate", aliases: ["date"], type: "string", tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "rating", type: "integer", minValue: 0, maxValue: 5, tolerance: 0, operations: [.get], isMetadata: true),
            FieldSpec(name: "colorTag", type: "integer", tolerance: 0, operations: [.get], isMetadata: true)
        ]
    }

    public func findAdjustmentSpec(named nameOrAlias: String) -> FieldSpec? {
        supportedAdjustmentFields.first { $0.matches(nameOrAlias: nameOrAlias) }
    }

    public func findMetadataSpec(named nameOrAlias: String) -> FieldSpec? {
        supportedMetadataFields.first { $0.matches(nameOrAlias: nameOrAlias) }
    }

    public func canonicalName(for field: String) -> String? {
        if let s = findAdjustmentSpec(named: field) { return s.name }
        if let s = findMetadataSpec(named: field) { return s.name }
        return nil
    }

    public func validateValue(_ val: Double, for spec: FieldSpec) throws {
        guard val.isFinite else { throw C1Error.invalidRequest("Adjustment values must be finite.") }
        if let min = spec.minValue, val < min {
            throw C1Error.invalidRequest("Value \(val) for field '\(spec.name)' is below minimum \(min)")
        }
        if let max = spec.maxValue, val > max {
            throw C1Error.invalidRequest("Value \(val) for field '\(spec.name)' is above maximum \(max)")
        }
    }

    public func parseKeyValueArguments(_ args: [String]) throws -> Adjustments {
        var adj = Adjustments()
        var seen = Set<String>()
        for arg in args {
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw C1Error.invalidRequest("Invalid key=value argument '\(arg)'. Expected format: <field>=<value>")
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let valStr = parts[1].trimmingCharacters(in: .whitespaces)

            guard let spec = findAdjustmentSpec(named: key) else {
                throw C1Error.unsupportedField("Field '\(key)' is not a recognized or supported adjustment field.")
            }
            guard seen.insert(spec.name).inserted else { throw C1Error.invalidRequest("Duplicate adjustment field or alias: \(key)") }
            guard let doubleVal = Double(valStr), doubleVal.isFinite else {
                throw C1Error.invalidRequest("Cannot parse numeric value for field '\(spec.name)': '\(valStr)'")
            }
            adj.setValue(doubleVal, for: spec.name)
        }
        return adj
    }

    public func validateAdjustments(_ adj: Adjustments) throws {
        if let v = adj.exposure, let s = findAdjustmentSpec(named: "exposure") {
            try validateValue(v, for: s)
        }
        if let v = adj.contrast, let s = findAdjustmentSpec(named: "contrast") {
            try validateValue(v, for: s)
        }
        if let v = adj.saturation, let s = findAdjustmentSpec(named: "saturation") {
            try validateValue(v, for: s)
        }
        if let v = adj.temperature, let s = findAdjustmentSpec(named: "temperature") {
            try validateValue(v, for: s)
        }
        if let v = adj.tint, let s = findAdjustmentSpec(named: "tint") {
            try validateValue(v, for: s)
        }
    }

    public func applyDelta(base: Adjustments, delta: Adjustments) throws -> Adjustments {
        var res = base
        if let d = delta.exposure {
            let current = base.exposure ?? 0.0
            res.exposure = current + d
        }
        if let d = delta.contrast {
            let current = base.contrast ?? 0.0
            res.contrast = current + d
        }
        if let d = delta.saturation {
            let current = base.saturation ?? 0.0
            res.saturation = current + d
        }
        if let d = delta.temperature {
            let current = base.temperature ?? 5500.0
            res.temperature = current + d
        }
        if let d = delta.tint {
            let current = base.tint ?? 0.0
            res.tint = current + d
        }
        try validateAdjustments(res)
        return res
    }

    public func valuesMatchWithinTolerance(field: String, expected: Double, actual: Double) -> Bool {
        guard let spec = findAdjustmentSpec(named: field) else { return false }
        return abs(expected - actual) <= spec.tolerance
    }

    public func computeResetValues(fields: [String], baseline: Adjustments) throws -> Adjustments {
        var targets = Adjustments()
        let fieldsToReset: Set<String>
        if fields.isEmpty || fields.contains(where: { $0.lowercased() == "all" }) {
            fieldsToReset = Set(["exposure", "contrast", "saturation", "temperature", "tint"])
        } else {
            var set = Set<String>()
            for f in fields {
                let lower = f.lowercased().trimmingCharacters(in: .whitespaces)
                if lower == "wb" || lower == "whitebalance" {
                    set.insert("temperature")
                    set.insert("tint")
                } else if let spec = findAdjustmentSpec(named: lower) {
                    guard spec.operations.contains(.reset) else {
                        throw C1Error.invalidRequest("Field '\(spec.name)' does not support reset.")
                    }
                    set.insert(spec.name)
                } else {
                    throw C1Error.unsupportedField("Field '\(f)' is not a recognized adjustment field.")
                }
            }
            fieldsToReset = set
        }

        if fieldsToReset.contains("exposure") {
            targets.exposure = 0.0
        }
        if fieldsToReset.contains("contrast") {
            targets.contrast = 0.0
        }
        if fieldsToReset.contains("saturation") {
            targets.saturation = 0.0
        }
        if fieldsToReset.contains("temperature") {
            targets.temperature = baseline.temperature ?? 5500.0
        }
        if fieldsToReset.contains("tint") {
            targets.tint = baseline.tint ?? 0.0
        }

        return targets
    }
}
