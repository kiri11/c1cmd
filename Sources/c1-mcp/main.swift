import Foundation
import MCP
import CaptureOneCore

// MARK: - Main Thread Execution
/// NSAppleScript on macOS requires execution on the main thread to prevent
/// Carbon/HIToolbox event loop deadlocks when communicating via Apple Events.

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
        
        let definitions: [(String, String, Bool)] = Recipes.tools.map { ($0, "Versioned reference recipes and bounded compound edits. Verification requires a managed clone. Inspect status and child operation IDs after failure; never retry automatically.", $0 == "edit_status") } + [
            ("read_session_begin", "Begin exclusive c1 browsing with a native scope baseline. No UI changes until read_session_end. Auto-routed browse results omit mutation tokens; use live:true before edits.", false),
            ("read_session_end", "End accelerated browsing before returning control to the photographer.", false),
            ("read_session_status", "Inspect read workflow state and process new journal observations.", true),
            ("catalog_get", "Inspect raw stored settings for one variant in an explicit Catalog database. Works while closed; no native tokens.", true),
            ("catalog_variants", "Discover distinct stored variants with explicit image/variant membership and optional ratings. No live mutation tokens or smart collection evaluation.", true),
            ("catalog_inspect", "Read versioned stored Catalog records from an explicit database path. No native references or live tokens; may lag Capture One.", true),
            ("catalog_snapshot", "Archive a Catalog using SQLite backup to a new destination file. Does not modify the source or include originals or external masks.", false),
            ("native_set", "Set typed native editing properties using exact dictionary field names and ifNativeState from get.nativeSnapshots. Curves use flat x,y pairs in 0...100. Saves before-state in the operation journal. Geometry guards still apply.", false),
            ("native_action", "Run an allowlisted layer, mask, color-editor, style or dehaze operation with a fresh nativeStateHash. Mask pixels cannot be captured or restored from property snapshots. Inspect a preview after commands.", false),
            ("doctor", "Check environment, app status, exact build, document readiness, and unresolved operations.", true),
            ("doc_info", "Show current open document info, folders, and open token.", true),
            ("capabilities", "Show capability matrix for the running Capture One build.", true),
            ("schema", "Output JSON Schema for c1 requests and responses.", true),
            ("variants_list", "List variants, optionally filtered by exact or minimum rating. Supply 1–512 known ids for fresh bounded discovery with minimal fields, optional summary fields and exact parentPath filtering. Subset reads return no mutation tokens.", true),
            ("variant_edit", "Prepare editing on an existing variant without cloning. Requires ifDocument from doc_info and ifState from get; optionally check ifGeometryState too. Saves its baseline and returns a c1_edit_ reference for supported adjustments and geometry. Does not authorize deletion.", false),
            ("geometry_restore", "Restore saved crop/rotation/keystone for an editing or clone reference. Requires fresh ifGeometryState; refuses changed lens/orientation context. Never delete an existing variant to reject a crop.", false),
            ("variant_clone", "Clone a source variant and return a c1-managed working reference (c1_wrk_<uuid>). Use variant_edit to edit existing variants.", false),
            ("variant_delete", "Delete a c1-managed working clone. (Originals cannot be deleted).", false),
            ("variant_baseline", "Create a managed default-settings baseline variant using native New Variant behavior.", false),
            ("get", "Read a variant: adjustments, metadata, geometry and their state tokens. Optionally include 1...16 nativeTargets for curves, lens or layer properties in nativeSnapshots, with shared validation and independent nativeStateHash tokens. Live AppleScript observations; not SQLite or an atomic multi-scope snapshot.", true),
            ("set", "Set absolute adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            ("add", "Apply relative delta adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            ("metadata_set", "Set rating (0–5) and/or colorTag (0–7; 0 clears) on an editing reference or managed clone. Requires ifMetadataState from get. Preserves omitted fields and image adjustments. dryRun returns the current metadata token.", false),
            ("geometry_set", "Set crop, rotation, and keystone on a c1_edit_ existing variant or c1_wrk_ clone, requiring ifGeometryState from get. Native rotated canvas pixels with bottom-left origin. aspectRatio fits a centered crop; use explicit crop for composition. Optional keystone object sets amount, vertical, horizontal, skew, or aspect; omitted controls are preserved. Preserves lens distortion and tilt/shift using native bounds. Dry runs cannot predict keystone changes or corrected rotation crops.", false),
            ("reset", "Reset verified adjustment fields on an editing reference or managed clone to defaults; white balance uses its saved baseline.", false),
            ("diff", "Compare adjustments between two variants or compare a working variant against its baseline.", true),
            ("dump", "Batched export of variants, adjustments, and metadata in JSON format.", true),
            ("preview", "Export and verify dedicated preview JPEG for a variant or working clone. Returns JSON metadata and an image content block with JPEG data.", false),
            ("request_status", "Read stored request progress and process liveness without contacting Capture One.", true),
            ("operation_status", "Inspect status and, after an app restart, journal recovery observations without retrying the operation.", false),
        ]
        let compositionOnly = ProcessInfo.processInfo.environment["C1_MCP_PROFILE"] == "composition"
        let excluded: Set<String> = Set(Recipes.tools.filter { $0 != "edit_status" }).union(["native_set", "native_action", "set", "add", "reset", "variant_baseline", "metadata_set"])
        let enabled = definitions.filter { !compositionOnly || !excluded.contains($0.0) }
        let enabledNames = Set(enabled.map { $0.0 })
        let tools: [Tool] = try enabled.map { name, description, readOnly in
            let data = try JSONSerialization.data(withJSONObject: ContractSchema.input(name))
            let input = try JSONDecoder().decode(Value.self, from: data)
            return Tool(name: name, description: description, inputSchema: input,
                        annotations: .init(readOnlyHint: readOnly, destructiveHint: ["variant_delete", "native_action"].contains(name)))
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
                    let raw = try JSONEncoder().encode(params.arguments ?? [:])
                    let args = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                    // Status and stored Catalog reads bypass the occupied main actor and application lock entirely.
                    if ToolRequest.localTools.contains(params.name) {
                        let request = try ToolRequest(tool: params.name, arguments: args)
                        let response = try await Task.detached { try request.dispatch() }.value
                        return CallTool.Result(content: [textContent(response.json)], isError: false)
                    }
                    return try await MainActor.run {
                        try context.withCurrent {
                            guard !Task.isCancelled else { throw C1Error.requestCancelled("Request cancelled before dispatch.") }
                            guard enabledNames.contains(params.name) else { throw C1Error.invalidRequest("Tool is not enabled in this MCP profile: \(params.name)") }
                            let request = try ToolRequest(tool: params.name, arguments: args)
                            context.update(phase: "executing")
                            let response = try request.dispatch()
                            var content = [textContent(response.json)]
                            if case .preview(let preview) = response {
                                let image = try Data(contentsOf: URL(fileURLWithPath: preview.outputPath))
                                content.append(imageContent(base64: image.base64EncodedString(), mimeType: "image/jpeg"))
                            }
                            return CallTool.Result(content: content, isError: response.reportsFailure)
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
