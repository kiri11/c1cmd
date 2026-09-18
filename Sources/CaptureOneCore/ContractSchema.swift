import Foundation
import CoreFoundation

/// One contract for CLI discovery, MCP tools/list, and pre-dispatch request validation.
public enum ContractSchema {
    public static let version = "1.9.0"
    static let string: [String: Any] = ["type": "string", "minLength": 1]
    static let boolean: [String: Any] = ["type": "boolean"]
    static let number: [String: Any] = ["type": "number"]
    public static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    static func array(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
    static func adjustments(delta: Bool = false, aliases: Bool = false) -> [String: Any] {
        var props: [String: Any] = [:]
        for field in FieldRegistry.shared.supportedAdjustmentFields {
            var schema = number
            if !delta { schema["minimum"] = field.minValue; schema["maximum"] = field.maxValue }
            props[field.name] = schema
            if aliases { for alias in field.aliases { props[alias] = schema } }
        }
        var result = object(props)
        result["minProperties"] = 1
        return result
    }
    public static let names = ["doctor", "doc_info", "capabilities", "schema", "variants_list", "variant_edit", "variant_clone", "variant_delete", "variant_baseline", "get", "metadata_set", "set", "add", "geometry_set", "geometry_restore", "reset", "diff", "dump", "preview", "operation_status", "request_status"]
    static var writableMetadataSchema: [String: Any] {
        object(["rating": ["type": "integer", "minimum": 0, "maximum": 5],
                "colorTag": ["type": "integer", "minimum": 0, "maximum": 7]], required: ["rating", "colorTag"])
    }
    static var cropSchema: [String: Any] { object(["centerX": number, "centerY": number, "width": ["type":"number", "exclusiveMinimum":0], "height": ["type":"number", "exclusiveMinimum":0]], required:["centerX","centerY","width","height"]) }
    static var keystoneSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for (index, name) in KeystoneAdjustments.fields.enumerated() {
            properties[name] = ["type": index == 0 ? "integer" : "number", "minimum": KeystoneAdjustments.ranges[index].lowerBound, "maximum": KeystoneAdjustments.ranges[index].upperBound]
        }
        var result = object(properties); result["minProperties"] = 1
        return result
    }
    static var geometrySchema: [String: Any] { object(["crop":cropSchema, "rotation":number, "orientation":["type":"integer"], "imageWidth":number, "imageHeight":number, "maximumCrop":cropSchema, "flip":string, "aspectRatioName":string, "keystone":array(number), "lensGeometry":array(number), "lensProfile":["type":"string"], "hideDistortedAreas":boolean, "cropOutsideImage":boolean]) }
    public static func input(_ name: String) -> [String: Any] {
        switch name {
        case "variants_list":
            var result = object([
                "collection": string, "selected": boolean,
                "batchSize": ["type": "integer", "minimum": 1, "maximum": 256],
                "deadlineSeconds": ["type": "number", "exclusiveMinimum": 0, "maximum": 86400],
                "rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Exact star rating (0 means unrated). Mutually exclusive with minRating."],
                "minRating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Inclusive minimum star rating. Mutually exclusive with rating."]
            ])
            result["not"] = ["required": ["rating", "minRating"]]
            return result
        case "variant_edit": return object(["sourceRef": string, "ifState": string, "ifGeometryState": string, "ifDocument": string], required: ["sourceRef", "ifState", "ifDocument"])
        case "geometry_restore": return object(["workingRef": string, "ifGeometryState": string, "dryRun": boolean], required: ["workingRef", "ifGeometryState"])
        case "variant_clone", "variant_baseline": return object(["sourceRef": string], required: ["sourceRef"])
        case "variant_delete": return object(["workingRef": string], required: ["workingRef"])
        case "metadata_set":
            var props = writableMetadataSchema["properties"] as! [String: Any]
            props["workingRef"] = string; props["ifMetadataState"] = string; props["dryRun"] = boolean
            var result = object(props, required: ["workingRef", "ifMetadataState"])
            result["anyOf"] = ["rating", "colorTag"].map { ["required": [$0]] }
            return result
        case "get": return object(["ref": string], required: ["ref"])
        case "set", "add":
            let adj = adjustments(delta: name == "add", aliases: true)
            var props = adj["properties"] as! [String: Any]
            props["workingRef"] = string; props["ifState"] = string; props["dryRun"] = boolean; props["adjustments"] = adj
            var result = object(props, required: ["workingRef", "ifState"])
            let fields = (adj["properties"] as! [String: Any]).keys.sorted()
            result["anyOf"] = (["adjustments"] + fields).map { ["required": [$0]] }
            result["not"] = ["allOf": [["required": ["adjustments"]], ["anyOf": fields.map { ["required": [$0]] }]]]
            return result
        case "geometry_set":
            var result = object(["workingRef":string, "ifGeometryState":string, "crop":cropSchema, "keystone":keystoneSchema, "rotation":["type":"number", "minimum":-45, "maximum":45], "aspectRatio":["type":"number", "exclusiveMinimum":0], "dryRun":boolean], required:["workingRef","ifGeometryState"])
            result["anyOf"] = ["crop", "rotation", "aspectRatio", "keystone"].map { ["required": [$0]] }
            result["not"] = ["required": ["crop", "aspectRatio"]]
            return result
        case "reset": return object(["workingRef": string, "ifState": string, "fields": array(string), "dryRun": boolean], required: ["workingRef", "ifState"])
        case "diff": return object(["ref1": string, "ref2": string], required: ["ref1"])
        case "dump": return object(["collection": string, "selected": boolean, "batchSize": ["type": "integer", "minimum": 1, "maximum": 1000]])
        case "preview": return object(["ref": string, "outputDir": string, "timeout": ["type": "number", "exclusiveMinimum": 0, "maximum": 300], "fullFrame":boolean], required: ["ref"])
        case "request_status": return object(["requestId": string], required: ["requestId"])
        case "operation_status": return object(["operationId": string], required: ["operationId"])
        default: return object([:])
        }
    }

    public static func parseAdjustments(_ values: [String: Any], delta: Bool) throws -> Adjustments {
        try validate(tool: delta ? "add" : "set", arguments: ["workingRef": "validation", "ifState": "validation", "adjustments": values])
        var result = Adjustments()
        for (name, value) in values {
            result.setValue((value as! NSNumber).doubleValue, for: FieldRegistry.shared.canonicalName(for: name)!)
        }
        return result
    }

    public static func validate(tool: String, arguments: [String: Any]) throws {
        guard names.contains(tool) else { throw C1Error.invalidRequest("Unknown tool: \(tool)") }
        try validateValue(arguments, schema: input(tool), path: tool)
        if tool == "variants_list", arguments["rating"] != nil, arguments["minRating"] != nil {
            throw C1Error.invalidRequest("rating and minRating are mutually exclusive. Provide an exact rating or an inclusive minimum.")
        }
        if tool == "set" || tool == "add" {
            let controls: Set<String> = ["workingRef", "ifState", "dryRun", "adjustments"]
            let top = arguments.filter { !controls.contains($0.key) }
            let nested = arguments["adjustments"] as? [String: Any]
            guard nested == nil || top.isEmpty else { throw C1Error.invalidRequest("Use nested or flat adjustments, not both.") }
            let values = nested ?? top
            guard !values.isEmpty else { throw C1Error.invalidRequest("At least one adjustment is required.") }
            var canonical = Set<String>()
            for key in values.keys {
                guard let name = FieldRegistry.shared.canonicalName(for: key), canonical.insert(name).inserted else {
                    throw C1Error.invalidRequest("Duplicate adjustment aliases: \(key)")
                }
            }
        }
        if tool == "metadata_set", arguments["rating"] == nil, arguments["colorTag"] == nil {
            throw C1Error.invalidRequest("Provide rating and/or colorTag.")
        }
        if tool == "geometry_set" {
            guard ["crop", "rotation", "aspectRatio", "keystone"].contains(where: { arguments[$0] != nil }), arguments["crop"] == nil || arguments["aspectRatio"] == nil else {
                throw C1Error.invalidRequest("Provide crop, rotation, aspectRatio, or keystone; crop and aspectRatio are mutually exclusive.")
            }
        }
        if tool == "reset", let fields = arguments["fields"] as? [String] {
            _ = try FieldRegistry.shared.computeResetValues(fields: fields, baseline: Adjustments(temperature: 5000, tint: 0))
        }
    }

    static func validateValue(_ value: Any, schema: [String: Any], path: String) throws {
        func invalid() -> C1Error { .invalidRequest("Invalid value for \(path). Expected \(schema["type"] ?? "value").") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw invalid() }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] { guard object[key] != nil else { throw C1Error.invalidRequest("Missing required argument: \(path).\(key)") } }
            if let min = schema["minProperties"] as? Int, object.count < min { throw invalid() }
            for (key, item) in object {
                guard let spec = properties[key] else { throw C1Error.invalidRequest("Unknown argument: \(path).\(key)") }
                try validateValue(item, schema: spec, path: "\(path).\(key)")
            }
        case "array":
            guard let items = value as? [Any], let spec = schema["items"] as? [String: Any] else { throw invalid() }
            for item in items { try validateValue(item, schema: spec, path: path) }
        case "string": guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }
        case "boolean": guard let num = value as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else { throw invalid() }
        case "number", "integer":
            guard let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite else { throw invalid() }
            let n = num.doubleValue
            if schema["type"] as? String == "integer", n.rounded() != n { throw invalid() }
            if let min = (schema["minimum"] as? NSNumber)?.doubleValue, n < min { throw invalid() }
            if let min = (schema["exclusiveMinimum"] as? NSNumber)?.doubleValue, n <= min { throw invalid() }
            if let max = (schema["maximum"] as? NSNumber)?.doubleValue, n > max { throw invalid() }
        default: throw invalid()
        }
    }

    public static func document() -> [String: Any] {
        var requests: [String: Any] = [:]
        for name in names { requests[name] = input(name) }
        let diff = object(["before": ["type": ["number", "null"]], "after": ["type": ["number", "null"]], "delta": number])
        let diffs: [String: Any] = ["type": "object", "additionalProperties": diff]
        let adj = adjustments()
        let metadata: [String: Any] = ["type": "object", "properties": Dictionary(uniqueKeysWithValues: ["camera", "lens", "iso", "shutterSpeed", "asShotWB", "captureDate"].map { ($0, string) }).merging(["rating": ["type": "integer"], "colorTag": ["type": "integer"]]) { _, b in b }]
        let get = object(["id": string, "workingRef": string, "parentImagePath": string, "adjustments": adj, "metadata": metadata, "metadataStateHash": string, "stateHash": string, "geometry":geometrySchema, "geometryStateHash":string, "geometryUsableBounds":cropSchema, "geometryUnavailableReason":string], required: ["id", "adjustments", "metadata", "stateHash"])
        let mutation = object(["operationId": string, "workingRef": string, "before": adj, "after": adj, "diff": diffs, "stateHash": string, "isDryRun": boolean], required: ["operationId", "workingRef", "before", "after", "diff", "stateHash", "isDryRun"])
        let clone = object(["workingRef": string, "cloneVariantId": string, "sourceVariantId": string, "documentPath": string, "baselineStateHash": string], required: ["workingRef", "cloneVariantId", "sourceVariantId", "documentPath", "baselineStateHash"])
        let variantProps: [String: Any] = ["id": string, "name": ["type": "string"], "parentImagePath": ["type": "string"], "isSelected": boolean, "rating": ["type": "integer"], "colorTag": ["type": "integer"], "isManagedWorkingClone": boolean, "workingRef": string]
        var dumpProps = variantProps; dumpProps["adjustments"] = adj; dumpProps["metadata"] = metadata; dumpProps["stateHash"] = string; dumpProps["geometry"] = geometrySchema; dumpProps["geometryStateHash"] = string; dumpProps["geometryUnavailableReason"] = string
        var requestStatusProperties: [String: Any] = [
            "requestId": string, "tool": string, "phase": string, "status": string,
            "documentIdentity": string, "scope": string, "operationId": string, "handler": string,
            "applicationProgress": string, "inventoryStrategy": string, "waitingForAppleEvent": boolean, "processAlive": boolean, "stale": boolean, "slow": boolean,
            "startedAt": number, "updatedAt": number
        ]
        for name in ["processId", "elapsedMs", "lastProgressAgoMs", "candidatesScanned", "matchesFound", "summariesCompleted", "totalCandidates", "rating", "minRating", "handlerCalls"] {
            requestStatusProperties[name] = ["type": "integer"]
        }
        var responses: [String: Any] = [
            "doctor": object(["appRunning": boolean, "appVersion": string, "exactBuildMatched": boolean, "testedBuilds": array(string), "pinnedBuild": string, "hasDocument": boolean, "docName": string, "docPath": string, "isSession": boolean, "writesEnabled": boolean, "lockAcquired": boolean, "unresolvedOperationsCount": ["type": "integer"], "allChecksPassed": boolean, "warning": string]),
            "doc_info": object(["documentId": string, "documentName": string, "documentPath": string, "isSession": boolean, "writesEnabled": boolean, "openToken": string, "captureFolder": ["type": "string"], "outputFolder": ["type": "string"], "appVersion": string]),
            "request_status": object(requestStatusProperties, required: ["requestId", "tool", "phase", "status", "elapsedMs", "processAlive", "stale"]),
            "capabilities": ["type": "object"], "schema": ["type": "object"],
            "variants_list": array(object(variantProps)), "variant_clone": clone, "variant_baseline": clone,
            "variant_delete": object(["deleted": boolean, "workingRef": string, "cloneVariantId": string]),
            "metadata_set": object(["operationId": string, "workingRef": string, "before": writableMetadataSchema,
                "after": writableMetadataSchema, "diff": diffs, "metadataStateHash": string, "isDryRun": boolean],
                required: ["operationId", "workingRef", "before", "after", "diff", "metadataStateHash", "isDryRun"]),
            "get": get, "set": mutation, "add": mutation, "reset": mutation,
            "geometry_set": object(["operationId":string,"workingRef":string,"before":geometrySchema,"after":geometrySchema,"diff":diffs,"geometryStateHash":string,"isDryRun":boolean], required:["operationId","workingRef","before","after","diff","geometryStateHash","isDryRun"]),
            "diff": object(["ref1": string, "ref2": string, "stateHash1": string, "stateHash2": string, "diff": diffs, "geometryBefore":geometrySchema, "geometryAfter":geometrySchema, "geometryDiff":diffs, "metadataBefore":writableMetadataSchema, "metadataAfter":writableMetadataSchema, "metadataDiff":diffs]),
            "dump": array(object(dumpProps)),
            "preview": object(["operationId": string, "workingRef": string, "outputPath": string, "fileSizeBytes": ["type": "integer"], "width": ["type": "integer"], "height": ["type": "integer"], "pixelSha256": string, "stateHash": string, "nativeVariantId": string, "geometry":geometrySchema, "geometryStateHash":string, "contextSourceRef":string]),
            "operation_status": object(["operationId": string, "timestamp": string, "operationType": string, "workingRef": string, "documentPath": string, "preconditionStateHash": string, "intendedAdjustments": adj, "beforeAdjustments": adj, "afterAdjustments": adj, "diff": diffs, "status": ["enum": ["pending", "succeeded", "failed", "partial-failure", "outcome-unknown", "reconciled"]], "error": string, "previewOutputPath": string, "appInstance": string, "documentIdentity": string, "nativeVariantId": string, "parentImagePath": string, "variantIdsBefore": array(string), "observedVariantIds": array(string), "beforeGeometry":geometrySchema, "intendedGeometry":geometrySchema, "requestedGeometry":object(["crop":cropSchema, "rotation":number, "aspectRatio":number, "keystone":keystoneSchema], required:["rotation"]), "afterGeometry":geometrySchema, "beforeMetadata":writableMetadataSchema, "intendedMetadata":writableMetadataSchema, "afterMetadata":writableMetadataSchema])
        ]
        responses["geometry_restore"] = responses["geometry_set"]
        responses["variant_edit"] = object(["workingRef": string, "variantId": string, "documentPath": string, "documentToken": string,
            "parentImagePath": string, "baselineAdjustments": adj, "baselineGeometry": geometrySchema, "baselineStateHash": string,
            "baselineGeometryStateHash": string, "baselineMetadata": writableMetadataSchema, "createdAt": string], required: ["workingRef", "variantId", "documentToken", "baselineAdjustments", "baselineStateHash"])
        return ["$schema": "https://json-schema.org/draft/2020-12/schema", "title": "c1-contract-schema", "version": version,
                "requests": requests, "responses": responses,
                "definitions": ["Adjustments": adj, "MutationResponse": mutation, "Error": object(["error": object(["code": string, "message": string, "operationId": string, "outcome": string, "requestId": string, "phase": string, "elapsedMs": ["type": "integer"], "recoveryAction": string], required: ["code", "message"])], required: ["error"])]]
    }
}
