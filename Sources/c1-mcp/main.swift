import Foundation
import MCP
import CaptureOneCore

// MARK: - Main Thread Execution
/// NSAppleScript on macOS requires execution on the main thread to prevent
/// Carbon/HIToolbox event loop deadlocks when communicating via Apple Events.

// MARK: - Argument Helpers
func extractString(from args: [String: Value]?, key: String) -> String? {
    args?[key]?.stringValue
}

func extractBool(from args: [String: Value]?, key: String) -> Bool? {
    args?[key]?.boolValue
}

func extractInt(from args: [String: Value]?, key: String) -> Int? {
    args?[key]?.intValue
}

func extractDouble(from args: [String: Value]?, key: String) -> Double? {
    args?[key]?.doubleValue ?? args?[key]?.intValue.map(Double.init)
}

func extractStringArray(from args: [String: Value]?, key: String) -> [String]? {
    guard let arr = args?[key]?.arrayValue else { return nil }
    return arr.compactMap { $0.stringValue }
}

func parseAdjustments(from args: [String: Value]?) throws -> Adjustments {
    let data = try JSONEncoder().encode(args ?? [:])
    let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let controls: Set<String> = ["workingRef", "ifState", "dryRun", "adjustments"]
    let values = arguments["adjustments"] as? [String: Any] ?? arguments.filter { !controls.contains($0.key) }
    // The tool-specific contract has already checked absolute bounds for set.
    return try ContractSchema.parseAdjustments(values, delta: true)
}

func textContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func imageContent(base64: String, mimeType: String = "image/jpeg") -> Tool.Content {
    .image(data: base64, mimeType: mimeType, annotations: nil, _meta: nil)
}

func formatErrorResult(_ error: Error) -> CallTool.Result {
    let errObj = ErrorResponse.payload(error)
    let jsonString: String
    if let data = try? JSONSerialization.data(withJSONObject: errObj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        jsonString = str
    } else {
        jsonString = "{\"error\":{\"code\":\"encoding-error\",\"message\":\"Cannot encode error\"}}"
    }
    
    return CallTool.Result(content: [textContent(jsonString)], isError: true)
}

// MARK: - Server Main
@main
struct C1MCPServer {
    static func main() async throws {
        // Log startup to stderr only
        FileHandle.standardError.write(Data("[c1-mcp] Starting Capture One MCP Server v0.1.0\n".utf8))
        
        let server = Server(
            name: "c1-mcp",
            version: "0.1.0",
            capabilities: .init(
                tools: .init(listChanged: true)
            )
        )
        
        let definitions: [(String, String, Bool)] = [
            ("doctor", "Check environment, app status, exact build, document readiness, and unresolved operations.", true),
            ("doc_info", "Show current open Session document info, folders, and open token.", true),
            ("capabilities", "Show capability matrix for the running Capture One build.", true),
            ("schema", "Output JSON Schema for c1 requests and responses.", true),
            ("variants_list", "List variants in the current Session or specified collection.", true),
            ("variant_clone", "Clone a source variant and return a c1-managed working reference (c1_wrk_<uuid>). Originals cannot be mutated directly.", false),
            ("variant_delete", "Delete a c1-managed working clone. (Originals cannot be deleted).", false),
            ("variant_baseline", "Create a managed default-settings baseline variant using native New Variant behavior.", false),
            ("get", "Get adjustments and metadata for a variant or working reference, including current stateHash.", true),
            ("set", "Set absolute adjustments on a managed working clone. Requires matching ifState precondition.", false),
            ("add", "Apply relative delta adjustments on a managed working clone. Requires matching ifState precondition.", false),
            ("reset", "Reset verified adjustment fields on a managed working clone to defaults.", false),
            ("diff", "Compare adjustments between two variants or compare a working variant against its baseline.", true),
            ("dump", "Batched export of variants, adjustments, and metadata in JSON format.", true),
            ("preview", "Export and verify dedicated preview JPEG for a variant or working clone. Returns JSON metadata and an image content block with JPEG data.", false),
            ("operation_status", "Inspect status and, after an app restart, journal recovery observations without retrying the operation.", false),
        ]
        let tools: [Tool] = try definitions.map { name, description, readOnly in
            let data = try JSONSerialization.data(withJSONObject: ContractSchema.input(name))
            let input = try JSONDecoder().decode(Value.self, from: data)
            return Tool(name: name, description: description, inputSchema: input,
                        annotations: .init(readOnlyHint: readOnly, destructiveHint: name == "variant_delete"))
        }

        // Register tools list handler
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        
        // Register tool call handler
        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await MainActor.run {
                    let raw = try JSONEncoder().encode(params.arguments ?? [:])
                    let args = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                    try ContractSchema.validate(tool: params.name, arguments: args)
                    switch params.name {
                    case "doctor":
                        let report = try SessionController.shared.doctor()
                        let json = OutputFormatter.formatJson(report)
                        return CallTool.Result(content: [textContent(json)], isError: !report.allChecksPassed)
                        
                    case "doc_info":
                        let info = try SessionController.shared.getDocumentInfo()
                        let json = OutputFormatter.formatJson(info)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "capabilities":
                        let caps = SessionController.shared.capabilities()
                        guard let data = try? JSONSerialization.data(withJSONObject: caps, options: [.prettyPrinted, .sortedKeys]),
                              let str = String(data: data, encoding: .utf8) else {
                            throw C1Error.invalidRequest("Failed to encode capabilities to JSON.")
                        }
                        return CallTool.Result(content: [textContent(str)], isError: false)
                        
                    case "schema":
                        let schemaObj = ContractSchema.document()
                        guard let data = try? JSONSerialization.data(withJSONObject: schemaObj, options: [.prettyPrinted, .sortedKeys]),
                              let str = String(data: data, encoding: .utf8) else {
                            throw C1Error.invalidRequest("Failed to encode schema to JSON.")
                        }
                        return CallTool.Result(content: [textContent(str)], isError: false)
                        
                    case "variants_list":
                        let collection = extractString(from: params.arguments, key: "collection")
                        let selected = extractBool(from: params.arguments, key: "selected") ?? false
                        let list = try SessionController.shared.listVariants(collectionName: collection, selectedOnly: selected)
                        let json = OutputFormatter.formatJson(list)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "variant_clone":
                        guard let sourceRef = extractString(from: params.arguments, key: "sourceRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'sourceRef'")
                        }
                        let res = try SessionController.shared.cloneVariant(sourceRef: sourceRef)
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "variant_delete":
                        guard let workingRef = extractString(from: params.arguments, key: "workingRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'workingRef'")
                        }
                        let res = try SessionController.shared.deleteVariant(workingRefString: workingRef)
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "variant_baseline":
                        guard let sourceRef = extractString(from: params.arguments, key: "sourceRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'sourceRef'")
                        }
                        let res = try SessionController.shared.createBaselineVariant(sourceRef: sourceRef)
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "get":
                        guard let ref = extractString(from: params.arguments, key: "ref") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ref'")
                        }
                        let res = try SessionController.shared.get(ref: ref)
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "set":
                        guard let workingRef = extractString(from: params.arguments, key: "workingRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'workingRef'")
                        }
                        guard let ifState = extractString(from: params.arguments, key: "ifState") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ifState'")
                        }
                        let dryRun = extractBool(from: params.arguments, key: "dryRun") ?? false
                        let adjustments = try parseAdjustments(from: params.arguments)
                        let res = try SessionController.shared.mutate(
                            workingRefString: workingRef,
                            ifState: ifState,
                            setAdjustments: adjustments,
                            addAdjustments: nil,
                            isDryRun: dryRun
                        )
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "add":
                        guard let workingRef = extractString(from: params.arguments, key: "workingRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'workingRef'")
                        }
                        guard let ifState = extractString(from: params.arguments, key: "ifState") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ifState'")
                        }
                        let dryRun = extractBool(from: params.arguments, key: "dryRun") ?? false
                        let adjustments = try parseAdjustments(from: params.arguments)
                        let res = try SessionController.shared.mutate(
                            workingRefString: workingRef,
                            ifState: ifState,
                            setAdjustments: nil,
                            addAdjustments: adjustments,
                            isDryRun: dryRun
                        )
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "reset":
                        guard let workingRef = extractString(from: params.arguments, key: "workingRef") else {
                            throw C1Error.invalidRequest("Missing required argument: 'workingRef'")
                        }
                        guard let ifState = extractString(from: params.arguments, key: "ifState") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ifState'")
                        }
                        let dryRun = extractBool(from: params.arguments, key: "dryRun") ?? false
                        let fields = extractStringArray(from: params.arguments, key: "fields") ?? []
                        let res = try SessionController.shared.reset(
                            workingRefString: workingRef,
                            ifState: ifState,
                            fields: fields,
                            isDryRun: dryRun
                        )
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "diff":
                        guard let ref1 = extractString(from: params.arguments, key: "ref1") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ref1'")
                        }
                        let ref2 = extractString(from: params.arguments, key: "ref2")
                        let res = try SessionController.shared.diff(ref1: ref1, ref2: ref2)
                        let json = OutputFormatter.formatJson(res)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "dump":
                        let collection = extractString(from: params.arguments, key: "collection")
                        let selected = extractBool(from: params.arguments, key: "selected") ?? false
                        let batchSize = extractInt(from: params.arguments, key: "batchSize") ?? 100
                        let records = try SessionController.shared.dump(
                            collectionName: collection,
                            selectedOnly: selected,
                            batchSize: batchSize
                        )
                        let json = OutputFormatter.formatJson(records)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    case "preview":
                        guard let ref = extractString(from: params.arguments, key: "ref") else {
                            throw C1Error.invalidRequest("Missing required argument: 'ref'")
                        }
                        let outputDir = extractString(from: params.arguments, key: "outputDir")
                        let timeout = extractDouble(from: params.arguments, key: "timeout") ?? 30.0
                        let res = try SessionController.shared.preview(
                            ref: ref,
                            outputDirOverride: outputDir,
                            timeout: timeout
                        )
                        let json = OutputFormatter.formatJson(res)
                        
                        let imageUrl = URL(fileURLWithPath: res.outputPath)
                        let imageData = try Data(contentsOf: imageUrl)
                        let base64 = imageData.base64EncodedString()
                        
                        return CallTool.Result(
                            content: [
                                textContent(json),
                                imageContent(base64: base64, mimeType: "image/jpeg")
                            ],
                            isError: false
                        )
                        
                    case "operation_status":
                        guard let opId = extractString(from: params.arguments, key: "operationId") else {
                            throw C1Error.invalidRequest("Missing required argument: 'operationId'")
                        }
                        let entry = try SessionController.shared.operationStatus(operationId: opId)
                        let json = OutputFormatter.formatJson(entry)
                        return CallTool.Result(content: [textContent(json)], isError: false)
                        
                    default:
                        throw C1Error.invalidRequest("Unknown tool name '\(params.name)'.")
                    }
                }
            } catch {
                return formatErrorResult(error)
            }
        }
        
        let transport = StdioTransport()
        try await server.start(transport: transport)
        FileHandle.standardError.write(Data("[c1-mcp] Server ready and listening on stdio.\n".utf8))
        await server.waitUntilCompleted()
    }
}
