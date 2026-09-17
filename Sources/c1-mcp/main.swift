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

func parseAdjustments(from arguments: [String: Any]) throws -> Adjustments {
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

func formatErrorResult(_ error: Error, context: CaptureOneCore.RequestContext? = nil) -> CallTool.Result {
    let errObj = context?.annotate(ErrorResponse.payload(error)) ?? ErrorResponse.payload(error)
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
            ("doc_info", "Show current open document info, folders, and open token.", true),
            ("capabilities", "Show capability matrix for the running Capture One build.", true),
            ("schema", "Output JSON Schema for c1 requests and responses.", true),
            ("variants_list", "List variants in the current document or specified collection, optionally filtered by exact or minimum star rating. Filters narrow results without changing UI selection.", true),
            ("variant_edit", "Prepare editing on an existing variant without cloning. Requires ifDocument from doc_info and ifState from get; optionally check ifGeometryState too. Saves its baseline and returns a c1_edit_ reference for supported adjustments and geometry. Does not authorize deletion.", false),
            ("geometry_restore", "Restore saved crop/rotation/keystone for an editing or clone reference. Requires fresh ifGeometryState; refuses changed lens/orientation context. Never delete an existing variant to reject a crop.", false),
            ("variant_clone", "Clone a source variant and return a c1-managed working reference (c1_wrk_<uuid>). Use variant_edit to edit existing variants.", false),
            ("variant_delete", "Delete a c1-managed working clone. (Originals cannot be deleted).", false),
            ("variant_baseline", "Create a managed default-settings baseline variant using native New Variant behavior.", false),
            ("get", "Get adjustments and metadata for a variant or working reference, including current stateHash.", true),
            ("set", "Set absolute adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            ("add", "Apply relative delta adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            ("geometry_set", "Set crop, rotation, and keystone on a c1_edit_ existing variant or c1_wrk_ clone, requiring ifGeometryState from get. Native rotated canvas pixels with bottom-left origin. aspectRatio fits a centered crop; use explicit crop for composition. Optional keystone object sets amount, vertical, horizontal, skew, or aspect; omitted controls are preserved. Preserves lens distortion and tilt/shift using native bounds. Dry runs cannot predict keystone changes or corrected rotation crops.", false),
            ("reset", "Reset verified adjustment fields on an editing reference or managed clone to defaults; white balance uses its saved baseline.", false),
            ("diff", "Compare adjustments between two variants or compare a working variant against its baseline.", true),
            ("dump", "Batched export of variants, adjustments, and metadata in JSON format.", true),
            ("preview", "Export and verify dedicated preview JPEG for a variant or working clone. Returns JSON metadata and an image content block with JPEG data.", false),
            ("request_status", "Read stored request progress and process liveness without contacting Capture One.", true),
            ("operation_status", "Inspect status and, after an app restart, journal recovery observations without retrying the operation.", false),
        ]
        let compositionOnly = ProcessInfo.processInfo.environment["C1_MCP_PROFILE"] == "composition"
        let excluded: Set<String> = ["set", "add", "reset", "variant_baseline"]
        let enabled = definitions.filter { !compositionOnly || !excluded.contains($0.0) }
        let enabledNames = Set(enabled.map { $0.0 })
        let tools: [Tool] = try enabled.map { name, description, readOnly in
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
            let (events, continuation) = AsyncStream<RequestSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let context = CaptureOneCore.RequestContext(tool: params.name, observer: { continuation.yield($0) })
            let progress = Task.detached {
                var lastUnits = -1
                for await event in events {
                    guard let token = params._meta?.progressToken else { continue }
                    let units = event.candidatesScanned + event.summariesCompleted
                    // Heartbeats never masquerade as work. The total is unknown until filtering finishes.
                    guard units > lastUnits else { continue }
                    lastUnits = units
                    try? await server.notify(ProgressNotification.message(.init(progressToken: token, progress: Double(units),
                        message: "\(event.requestId): \(event.phase); scanned \(event.candidatesScanned), summaries \(event.summariesCompleted)")))
                }
            }
            let result: CallTool.Result
            do {
                result = try await withTaskCancellationHandler {
                    // Status bypasses the occupied main actor and application lock entirely.
                    if params.name == "request_status" {
                        let data = try JSONEncoder().encode(params.arguments ?? [:])
                        let args = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                        try ContractSchema.validate(tool: params.name, arguments: args)
                        let status = try CaptureOneCore.RequestContext.status(requestId: args["requestId"] as! String)
                        return CallTool.Result(content: [textContent(OutputFormatter.formatJson(status))], isError: false)
                    }
                    return try await MainActor.run {
                        try context.withCurrent {
                            guard !Task.isCancelled else { throw C1Error.requestCancelled("Request cancelled before dispatch.") }
                            let raw = try JSONEncoder().encode(params.arguments ?? [:])
                            let args = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                            guard enabledNames.contains(params.name) else { throw C1Error.invalidRequest("Tool is not enabled in this MCP profile: \(params.name)") }
                            try ContractSchema.validate(tool: params.name, arguments: args)
                            context.update(phase: "executing")
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
                                let rating = (args["rating"] as? NSNumber)?.intValue
                                let minRating = (args["minRating"] as? NSNumber)?.intValue
                                let list = try SessionController.shared.listVariants(collectionName: collection, selectedOnly: selected, rating: rating, minRating: minRating, batchSize: extractInt(from: params.arguments, key: "batchSize") ?? 32, deadlineSeconds: extractDouble(from: params.arguments, key: "deadlineSeconds"))
                                let json = OutputFormatter.formatJson(list)
                                return CallTool.Result(content: [textContent(json)], isError: false)
                        
                            case "variant_edit":
                                let result = try SessionController.shared.editVariant(sourceRef: args["sourceRef"] as! String,
                                    ifState: args["ifState"] as! String, ifDocument: args["ifDocument"] as! String, ifGeometryState: args["ifGeometryState"] as? String)
                                return CallTool.Result(content: [textContent(OutputFormatter.formatJson(result))], isError: false)
                            case "geometry_restore":
                                let result = try SessionController.shared.geometryRestore(workingRef: args["workingRef"] as! String,
                                    ifGeometryState: args["ifGeometryState"] as! String, dryRun: args["dryRun"] as? Bool ?? false)
                                return CallTool.Result(content: [textContent(OutputFormatter.formatJson(result))], isError: false)
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
                        
                            case "set", "add":
                                guard let workingRef = extractString(from: params.arguments, key: "workingRef") else {
                                    throw C1Error.invalidRequest("Missing required argument: 'workingRef'")
                                }
                                guard let ifState = extractString(from: params.arguments, key: "ifState") else {
                                    throw C1Error.invalidRequest("Missing required argument: 'ifState'")
                                }
                                let dryRun = extractBool(from: params.arguments, key: "dryRun") ?? false
                                let adjustments = try parseAdjustments(from: args)
                                let res = try SessionController.shared.mutate(
                                    workingRefString: workingRef,
                                    ifState: ifState,
                                    setAdjustments: params.name == "set" ? adjustments : nil,
                                    addAdjustments: params.name == "add" ? adjustments : nil,
                                    isDryRun: dryRun
                                )
                                let json = OutputFormatter.formatJson(res)
                                return CallTool.Result(content: [textContent(json)], isError: false)
                        
                            case "geometry_set":
                                let crop: CropRect?
                                if let value = args["crop"] { crop = try JSONDecoder().decode(CropRect.self, from: JSONSerialization.data(withJSONObject: value)) } else { crop = nil }
                                let keystone = try args["keystone"].map { try JSONDecoder().decode(KeystoneAdjustments.self, from: JSONSerialization.data(withJSONObject: $0)) }
                                let result = try SessionController.shared.geometrySet(workingRef: args["workingRef"] as! String,
                                    ifGeometryState: args["ifGeometryState"] as! String, crop: crop,
                                    rotation: (args["rotation"] as? NSNumber)?.doubleValue, aspectRatio: (args["aspectRatio"] as? NSNumber)?.doubleValue, keystone: keystone,
                                    dryRun: args["dryRun"] as? Bool ?? false)
                                return CallTool.Result(content: [textContent(OutputFormatter.formatJson(result))], isError: false)
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
                                    timeout: timeout, fullFrame: extractBool(from: params.arguments, key: "fullFrame") ?? false
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
                    }
                } onCancel: { context.cancel() }
                context.finish(error: result.isError == true ? C1Error.invalidRequest("Tool reported a failed diagnostic check.") : nil)
            } catch {
                context.finish(error: error)
                result = formatErrorResult(error, context: context)
            }
            continuation.finish()
            await progress.value
            return result
        }
        
        let transport = StdioTransport()
        try await server.start(transport: transport)
        FileHandle.standardError.write(Data("[c1-mcp] Server ready and listening on stdio.\n".utf8))
        await server.waitUntilCompleted()
    }
}
