import Foundation
import MCP
import CaptureOneCore

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
        
        // One profile for the process lifetime; an unknown or conflicting setting refuses to serve.
        let profile: ToolProfile
        do { profile = try .configured() } catch {
            FileHandle.standardError.write(Data("[c1-mcp] \(error)\n".utf8))
            exit(1)
        }
        let tools: [Tool] = try profile.tools.map { tool in
            let data = try JSONSerialization.data(withJSONObject: tool.inputSchema)
            return Tool(name: tool.name, description: tool.description, inputSchema: try JSONDecoder().decode(Value.self, from: data),
                        annotations: .init(readOnlyHint: tool.readOnly, destructiveHint: tool.destructive))
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
                    let units = event.candidatesScanned + event.summariesCompleted + (event.revalidatedRows ?? 0)
                    // Heartbeats never masquerade as work. The total is unknown until filtering finishes.
                    guard units > lastUnits else { continue }
                    lastUnits = units
                    try? await server.notify(ProgressNotification.message(.init(progressToken: token, progress: Double(units),
                        message: "\(event.requestId): \(event.phase); scanned \(event.candidatesScanned), summaries \(event.summariesCompleted), revalidated \(event.revalidatedRows ?? 0)")))
                }
            }
            let result: CallTool.Result
            do {
                result = try await withTaskCancellationHandler {
                    let raw = try JSONEncoder().encode(params.arguments ?? [:])
                    let args = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                    // Status and stored Catalog reads bypass the occupied main actor and application lock entirely.
                    if ToolRequest.localTools.contains(params.name) {
                        let request = try ToolRequest(tool: params.name, arguments: args, profile: profile)
                        let response = try await Task.detached { try request.dispatch() }.value
                        return CallTool.Result(content: [textContent(response.json)], isError: false)
                    }
                    // NSAppleScript must run on the main thread. This long-lived process also keeps
                    // AppleScriptExecutor.shared's compiled handlers, so only the first call compiles them.
                    return try await MainActor.run {
                        try context.withCurrent {
                            guard !Task.isCancelled else { throw C1Error.requestCancelled("Request cancelled before dispatch.") }
                            let request = try ToolRequest(tool: params.name, arguments: args, profile: profile)
                            context.update(phase: "executing")
                            let response = try request.dispatch()
                            var content = [textContent(response.json)]
                            if case .preview(let preview) = response.complete {
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
