import Foundation

/// Compact results for mutation, recipe and preview tools. The complete result is
/// written beside the document's journal and the summary names that file. Anything a
/// reviewer must see stays in the summary: changed fields, new state tokens, coverage
/// gaps and unavailable fields. Thrown errors and unfinished compound edits are never
/// compacted, and a result whose evidence cannot be written is returned in full.
public enum ResultCompaction {
    public static let tools: Set<String> = Set(["set", "add", "reset", "metadata_set", "geometry_set", "geometry_restore",
                                                "native_set", "native_action", "preview"] + Recipes.tools)

    /// `documentPath` is the document directory whose `.c1` folder holds the journal.
    public static func compact(_ response: ToolResponse, tool: String, documentPath: String?) -> ToolResponse {
        let text = response.json
        guard let documentPath, let full = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              var result = summary(tool: tool, full: full) else { return response }
        let directory = URL(fileURLWithPath: documentPath).appendingPathComponent(".c1/results", isDirectory: true)
        let file = directory.appendingPathComponent("\(tool)-\(UUID().uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((text + "\n").utf8).write(to: file, options: .atomic)
        } catch { return response }
        result["evidencePath"] = file.path
        return .compact(result, complete: response)
    }

    /// The summary of one complete result, or nil when the result must stay complete.
    static func summary(tool: String, full: [String: Any]) -> [String: Any]? {
        func pick(_ keys: [String]) -> [String: Any] { full.filter { keys.contains($0.key) } }
        switch tool {
        case "set", "add", "reset": return pick(["operationId", "workingRef", "diff", "stateHash", "isDryRun"])
        case "metadata_set": return pick(["operationId", "workingRef", "diff", "metadataStateHash", "isDryRun"])
        case "geometry_set", "geometry_restore": return pick(["operationId", "workingRef", "diff", "geometryStateHash", "isDryRun", "exposedCorners"])
        case "native_set", "native_action":
            guard let before = full["before"] as? [String: Any], let after = full["after"] as? [String: Any] else { return nil }
            let identity = ["target", "nativeStateHash", "unavailable"]
            var result = pick(["operationId", "dryRun"])
            result["target"] = after["target"]; result["nativeStateHash"] = after["nativeStateHash"]
            result["diff"] = CompoundResultBundle.changes(before.filter { !identity.contains($0.key) }, after.filter { !identity.contains($0.key) })
            if let unavailable = after["unavailable"] as? [String: Any], !unavailable.isEmpty { result["unavailable"] = unavailable }
            return result
        case "preview":
            return pick(["operationId", "workingRef", "outputPath", "width", "height", "stateHash", "geometryStateHash",
                         "nativeVariantId", "contextSourceRef"])
        case "reference_capture":
            guard let bundle = full["bundle"] as? [String: Any] else { return nil }
            var result = pick(["referenceId"])
            result["previewPath"] = (bundle["preview"] as? [String: Any])?["outputPath"]
            result["coverage"] = bundle["coverage"]
            return result
        case "recipe_register": return pick(["recipeId", "status"])
        default:
            // Failed, uncertain and interrupted compound edits keep every field.
            guard full["status"] as? String == "succeeded", let bundle = full["resultBundle"] as? [String: Any],
                  let provenance = bundle["provenance"] as? [String: Any] else { return nil }
            var result = pick(["compoundId", "recipeId", "status"])
            result["workingRef"] = provenance["workingRef"]
            result["operations"] = provenance["operations"]
            result["finalHashes"] = provenance["finalHashes"]
            result["diff"] = bundle["diff"]
            result["coverage"] = bundle["coverage"]
            if let preview = bundle["preview"] as? [String: Any] { result["previewPath"] = preview["outputPath"] }
            if let scoped = bundle["scopedNative"] as? [String: Any] { result["scopedDiff"] = scoped["diff"] }
            return result
        }
    }

    /// Response schemas for compact results; `responses` keeps the complete shapes.
    static func schemas(_ responses: [String: Any]) -> [String: Any] {
        let string = ContractSchema.string
        let open: [String: Any] = ["type": "object", "additionalProperties": true]
        func compact(_ tool: String, _ keys: [String], extra: [String: Any] = [:], required: [String]) -> [String: Any] {
            let complete = (responses[tool] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            var properties = complete.filter { keys.contains($0.key) }.merging(extra) { _, new in new }
            properties["evidencePath"] = string
            return ContractSchema.object(properties, required: required + ["evidencePath"])
        }
        let tonal = ["operationId", "workingRef", "diff", "stateHash", "isDryRun"]
        let bundle = CompoundResultBundle.schema(responses)["properties"] as! [String: Any]
        let provenance = (bundle["provenance"] as! [String: Any])["properties"] as! [String: Any]
        let changes: [String: Any] = ["type": "object", "additionalProperties": open]
        let report = compact("edit_apply", ["compoundId", "recipeId", "status"],
            extra: ["status": ["enum": ["succeeded"]], "workingRef": string, "operations": provenance["operations"]!,
                    "finalHashes": provenance["finalHashes"]!, "diff": bundle["diff"]!, "coverage": bundle["coverage"]!,
                    "previewPath": string, "scopedDiff": open],
            required: ["compoundId", "recipeId", "status", "workingRef", "operations", "finalHashes", "diff", "coverage"])
        var result: [String: Any] = [
            "set": compact("set", tonal, required: tonal), "add": compact("add", tonal, required: tonal),
            "reset": compact("reset", tonal, required: tonal),
            "metadata_set": compact("metadata_set", ["operationId", "workingRef", "diff", "metadataStateHash", "isDryRun"],
                                    required: ["operationId", "workingRef", "diff", "metadataStateHash", "isDryRun"]),
            "preview": compact("preview", ["operationId", "workingRef", "outputPath", "width", "height", "stateHash",
                                           "geometryStateHash", "nativeVariantId", "contextSourceRef"],
                               required: ["operationId", "outputPath", "width", "height"]),
            "reference_capture": compact("reference_capture", ["referenceId"], extra: ["previewPath": string, "coverage": open],
                                         required: ["referenceId", "coverage"]),
            "recipe_register": compact("recipe_register", ["recipeId", "status"], required: ["recipeId", "status"]),
            "recipe_verify": report, "edit_apply": report, "edit_status": report,
        ]
        let geometry = ["operationId", "workingRef", "diff", "geometryStateHash", "isDryRun"]
        result["geometry_set"] = compact("geometry_set", geometry + ["exposedCorners"], required: geometry)
        result["geometry_restore"] = result["geometry_set"]
        let native = compact("native_set", ["operationId", "dryRun"],
            extra: ["target": NativeEditing.targetSchema, "nativeStateHash": string, "diff": changes, "unavailable": open],
            required: ["operationId", "dryRun", "target", "nativeStateHash", "diff"])
        result["native_set"] = native; result["native_action"] = native
        return result
    }
}

/// The document directory the running dispatch observed, recorded per thread so compact
/// evidence lands beside that request's journal without another Apple Event.
enum ObservedDocument {
    private static let key = "c1.observedDocumentPath"
    static func note(_ path: String) {
        if Thread.current.threadDictionary[key] != nil { Thread.current.threadDictionary[key] = path }
    }
    static func recording<T>(_ body: () throws -> T) rethrows -> (T, String?) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = NSNull()
        defer { dictionary[key] = previous }
        let value = try body()
        return (value, dictionary[key] as? String)
    }
}
