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
    guard let args = args else {
        throw C1Error.invalidRequest("Missing adjustment arguments.")
    }
    
    // Check if nested under "adjustments"
    if let adjVal = args["adjustments"], let obj = adjVal.objectValue {
        return try decodeAdjustmentsFromValueDict(obj)
    }
    
    // Check top-level keys
    return try decodeAdjustmentsFromValueDict(args)
}

func decodeAdjustmentsFromValueDict(_ dict: [String: Value]) throws -> Adjustments {
    var exposure: Double?
    var contrast: Double?
    var saturation: Double?
    var temperature: Double?
    var tint: Double?
    
    for (k, v) in dict {
        let doubleVal = v.doubleValue ?? v.intValue.map(Double.init)
        switch k.lowercased() {
        case "exposure", "exp":
            exposure = doubleVal
        case "contrast":
            contrast = doubleVal
        case "saturation", "sat":
            saturation = doubleVal
        case "temperature", "kelvin", "temp":
            temperature = doubleVal
        case "tint":
            tint = doubleVal
        default:
            break
        }
    }
    
    let adj = Adjustments(
        exposure: exposure,
        contrast: contrast,
        saturation: saturation,
        temperature: temperature,
        tint: tint
    )
    
    guard adj.hasAnyField else {
        throw C1Error.invalidRequest("No valid adjustment fields provided (exposure, contrast, saturation, temperature, tint).")
    }
    return adj
}

func textContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func imageContent(base64: String, mimeType: String = "image/jpeg") -> Tool.Content {
    .image(data: base64, mimeType: mimeType, annotations: nil, _meta: nil)
}

func formatErrorResult(_ error: Error) -> CallTool.Result {
    let errorCode: String
    let message: String
    if let c1Err = error as? C1Error {
        errorCode = c1Err.errorCode
        message = c1Err.description
    } else {
        errorCode = "unexpected-error"
        message = error.localizedDescription
    }
    
    let errObj: [String: Any] = [
        "error": [
            "code": errorCode,
            "message": message
        ]
    ]
    let jsonString: String
    if let data = try? JSONSerialization.data(withJSONObject: errObj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        jsonString = str
    } else {
        jsonString = "{\"error\":{\"code\":\"\(errorCode)\",\"message\":\"\(message)\"}}"
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
        
        // Define all 16 tools
        let tools: [Tool] = [
            Tool(
                name: "doctor",
                description: "Check environment, app status, exact build, document readiness, and unresolved operations.",
                inputSchema: [
                    "type": "object"
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "doc_info",
                description: "Show current open Session document info, folders, and open token.",
                inputSchema: [
                    "type": "object"
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "capabilities",
                description: "Show capability matrix for the running Capture One build.",
                inputSchema: [
                    "type": "object"
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "schema",
                description: "Output JSON Schema for c1 requests and responses.",
                inputSchema: [
                    "type": "object"
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "variants_list",
                description: "List variants in the current Session or specified collection.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "collection": [
                            "type": "string",
                            "description": "Optional name of the collection to list variants from (e.g. Capture)."
                        ],
                        "selected": [
                            "type": "boolean",
                            "description": "If true, lists only currently selected variants."
                        ]
                    ]
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "variant_clone",
                description: "Clone a source variant and return a c1-managed working reference (c1_wrk_<uuid>). Originals cannot be mutated directly.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sourceRef": [
                            "type": "string",
                            "description": "Source variant native ID or name."
                        ]
                    ],
                    "required": ["sourceRef"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "variant_delete",
                description: "Delete a c1-managed working clone. (Originals cannot be deleted).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workingRef": [
                            "type": "string",
                            "description": "Working reference (c1_wrk_<uuid>) to delete."
                        ]
                    ],
                    "required": ["workingRef"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "variant_baseline",
                description: "Create a managed default-settings baseline variant using native New Variant behavior.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sourceRef": [
                            "type": "string",
                            "description": "Source variant native ID or name."
                        ]
                    ],
                    "required": ["sourceRef"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "get",
                description: "Get adjustments and metadata for a variant or working reference, including current stateHash.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "ref": [
                            "type": "string",
                            "description": "Native variant ID or working reference (c1_wrk_<uuid>)."
                        ]
                    ],
                    "required": ["ref"]
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "set",
                description: "Set absolute adjustments on a managed working clone. Requires matching ifState precondition.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workingRef": [
                            "type": "string",
                            "description": "Working reference (c1_wrk_<uuid>)."
                        ],
                        "ifState": [
                            "type": "string",
                            "description": "Expected stateHash before applying mutation (precondition)."
                        ],
                        "adjustments": [
                            "type": "object",
                            "description": "Adjustments to set (exposure, contrast, saturation, temperature, tint).",
                            "properties": [
                                "exposure": ["type": "number", "description": "Exposure in EV (-4.0 to 4.0)"],
                                "contrast": ["type": "number", "description": "Contrast (-50.0 to 50.0)"],
                                "saturation": ["type": "number", "description": "Saturation (-100.0 to 100.0)"],
                                "temperature": ["type": "number", "description": "White balance temperature in Kelvin (800 to 14000)"],
                                "tint": ["type": "number", "description": "White balance tint (-50.0 to 50.0)"]
                            ]
                        ],
                        "exposure": ["type": "number", "description": "Direct exposure in EV (-4.0 to 4.0)"],
                        "contrast": ["type": "number", "description": "Direct contrast (-50.0 to 50.0)"],
                        "saturation": ["type": "number", "description": "Direct saturation (-100.0 to 100.0)"],
                        "temperature": ["type": "number", "description": "Direct temperature in Kelvin (800 to 14000)"],
                        "tint": ["type": "number", "description": "Direct tint (-50.0 to 50.0)"],
                        "dryRun": [
                            "type": "boolean",
                            "description": "Predict diff and target hash without mutating."
                        ]
                    ],
                    "required": ["workingRef", "ifState"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "add",
                description: "Apply relative delta adjustments on a managed working clone. Requires matching ifState precondition.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workingRef": [
                            "type": "string",
                            "description": "Working reference (c1_wrk_<uuid>)."
                        ],
                        "ifState": [
                            "type": "string",
                            "description": "Expected stateHash before applying mutation (precondition)."
                        ],
                        "adjustments": [
                            "type": "object",
                            "description": "Adjustment deltas to add (exposure, contrast, saturation, temperature, tint).",
                            "properties": [
                                "exposure": ["type": "number", "description": "Exposure delta in EV"],
                                "contrast": ["type": "number", "description": "Contrast delta"],
                                "saturation": ["type": "number", "description": "Saturation delta"],
                                "temperature": ["type": "number", "description": "Temperature delta in Kelvin"],
                                "tint": ["type": "number", "description": "Tint delta"]
                            ]
                        ],
                        "exposure": ["type": "number", "description": "Direct exposure delta in EV"],
                        "contrast": ["type": "number", "description": "Direct contrast delta"],
                        "saturation": ["type": "number", "description": "Direct saturation delta"],
                        "temperature": ["type": "number", "description": "Direct temperature delta in Kelvin"],
                        "tint": ["type": "number", "description": "Direct tint delta"],
                        "dryRun": [
                            "type": "boolean",
                            "description": "Predict diff and target hash without mutating."
                        ]
                    ],
                    "required": ["workingRef", "ifState"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "reset",
                description: "Reset verified adjustment fields on a managed working clone to defaults.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workingRef": [
                            "type": "string",
                            "description": "Working reference (c1_wrk_<uuid>)."
                        ],
                        "ifState": [
                            "type": "string",
                            "description": "Expected stateHash before applying mutation (precondition)."
                        ],
                        "fields": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional fields to reset (e.g. ['exposure', 'wb', 'contrast']). If omitted, resets all verified fields."
                        ],
                        "dryRun": [
                            "type": "boolean",
                            "description": "Predict diff and target hash without mutating."
                        ]
                    ],
                    "required": ["workingRef", "ifState"]
                ],
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "diff",
                description: "Compare adjustments between two variants or compare a working variant against its baseline.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "ref1": [
                            "type": "string",
                            "description": "First variant reference (or working reference to compare against its baseline)."
                        ],
                        "ref2": [
                            "type": "string",
                            "description": "Optional second variant reference to compare against ref1."
                        ]
                    ],
                    "required": ["ref1"]
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "dump",
                description: "Batched export of variants, adjustments, and metadata in JSON format.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "collection": [
                            "type": "string",
                            "description": "Optional collection name to dump from."
                        ],
                        "selected": [
                            "type": "boolean",
                            "description": "Dump only selected variants."
                        ],
                        "batchSize": [
                            "type": "integer",
                            "description": "Chunk size for batched variant queries (default 100)."
                        ]
                    ]
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "preview",
                description: "Export and verify dedicated preview JPEG for a variant or working clone. Returns JSON metadata and an image content block with JPEG data.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "ref": [
                            "type": "string",
                            "description": "Variant reference (working ref c1_wrk_<uuid> or native variant ID)."
                        ],
                        "outputDir": [
                            "type": "string",
                            "description": "Custom output directory."
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "Timeout in seconds for preview render (default 30.0)."
                        ]
                    ],
                    "required": ["ref"]
                ],
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "operation_status",
                description: "Inspect operation status in the Session journal.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "operationId": [
                            "type": "string",
                            "description": "Operation ID to check."
                        ]
                    ],
                    "required": ["operationId"]
                ],
                annotations: .init(readOnlyHint: true)
            )
        ]
        
        // Register tools list handler
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        
        // Register tool call handler
        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await MainActor.run {
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
                        let schemaObj: [String: Any] = [
                            "$schema": "https://json-schema.org/draft/2020-12/schema",
                            "title": "c1-contract-schema",
                            "version": "1.0.0",
                            "definitions": [
                                "Adjustments": [
                                    "type": "object",
                                    "properties": [
                                        "exposure": ["type": "number", "minimum": -4.0, "maximum": 4.0, "unit": "EV"],
                                        "contrast": ["type": "number", "minimum": -50.0, "maximum": 50.0],
                                        "saturation": ["type": "number", "minimum": -100.0, "maximum": 100.0],
                                        "temperature": ["type": "number", "minimum": 800.0, "maximum": 14000.0, "unit": "K"],
                                        "tint": ["type": "number", "minimum": -50.0, "maximum": 50.0]
                                    ],
                                    "additionalProperties": false
                                ]
                            ]
                        ]
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
