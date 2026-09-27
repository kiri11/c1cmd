import Foundation
import ArgumentParser
import CaptureOneCore

struct GlobalOptions: ParsableArguments {
    @Option(help: "Read workflow ID from read-session begin; alternatively set C1_READ_WORKFLOW for the agent batch.")
    var readWorkflow: String?
    var readWorkflowID: String? { readWorkflow ?? ProcessInfo.processInfo.environment["C1_READ_WORKFLOW"] }

    @Option(name: .shortAndLong, help: "Output format: auto, json, or human.")
    var format: String = "auto"

    @Flag(help: "Suppress request progress on stderr (errors are still reported).")
    var quiet = false

    @Option(help: "Request progress on stderr: human, json, or quiet. Defaults to human on a terminal, quiet in pipelines.")
    var progress: String?

    var outputFormat: OutputFormat {
        switch format.lowercased() {
        case "json": return .json
        case "human": return .human
        default: return .auto
        }
    }
}

func handleExecution(tool: String, format: OutputFormat, progressMode: String? = nil, _ block: () throws -> Void) -> ExitCode {
    let context = RequestContext(tool: tool, progressMode: progressMode)
    var signalSource: DispatchSourceSignal?
    let oldSignal = tool == "variants_list" ? signal(SIGINT, SIG_IGN) : nil
    if tool == "variants_list" {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { context.cancel() }
        source.resume(); signalSource = source
    }
    defer { signalSource?.cancel(); if tool == "variants_list" { signal(SIGINT, oldSignal) } }
    do {
        if let progressMode, !["quiet", "json", "human"].contains(progressMode) { throw C1Error.invalidRequest("progress must be human, json, or quiet.") }
        context.update(phase: "executing")
        try context.withCurrent(block)
        context.finish()
        return ExitCode.success
    } catch {
        context.finish(error: error)
        if OutputFormatter.resolveFormat(format) == .json,
           let data = try? JSONSerialization.data(withJSONObject: context.annotate(ErrorResponse.payload(error)), options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[\(context.snapshot.requestId)] \(error)\n".utf8))
        }
        return ExitCode(error is OperationFailure ? 4 : (error as? C1Error)?.exitCode ?? 1)
    }
}

extension GlobalOptions {
    var progressMode: String? { quiet ? "quiet" : progress }

    /// Maps a command's flags to the shared arguments object and runs it through the
    /// core dispatcher, exactly as the MCP server does for the same tool.
    func run(_ tool: String, full: ResultOptions? = nil, _ arguments: () throws -> [String: Any]) throws {
        try run(tool, full: full, arguments) { print(rendered($0)) }
    }

    func run(_ tool: String, full: ResultOptions? = nil, _ arguments: () throws -> [String: Any], render: (ToolResponse) throws -> Void) throws {
        var failed = false
        let code = handleExecution(tool: tool, format: outputFormat, progressMode: progressMode) {
            var args = try arguments()
            put(&args, "full", flag(full?.full ?? false))
            let response = try ToolRequest(tool: tool, arguments: args).dispatch()
            try render(response)
            failed = response.reportsFailure
        }
        if code != .success { throw code }
        if failed { throw ExitCode.failure }
    }

    func rendered(_ response: ToolResponse) -> String {
        let human = OutputFormatter.resolveFormat(outputFormat) != .json
        switch response {
        case .documentInfo(let info): return OutputFormatter.renderDocumentInfo(info, format: outputFormat)
        case .variants(let list): return OutputFormatter.renderVariants(list, format: outputFormat)
        case .get(let result): return OutputFormatter.renderGetResult(result, format: outputFormat)
        case .mutation(let result): return OutputFormatter.renderMutationResult(result, format: outputFormat)
        case .diff(let result): return OutputFormatter.renderDiffResult(result, format: outputFormat)
        case .preview(let result): return OutputFormatter.renderPreviewResult(result, format: outputFormat)
        case .delete(let res) where human:
            return ["Deleted working variant:", "  Working Ref: \(res.workingRef)", "  Clone ID   : \(res.cloneVariantId)",
                    "  Deleted    : \(res.deleted)"].joined(separator: "\n")
        case .compact(let summary, let complete) where human:
            return rendered(complete) + "\nEvidence: \(summary["evidencePath"] as? String ?? "")"
        case .operation(let entry) where human:
            var lines = ["Operation Status", "----------------", "Operation ID : \(entry.operationId)", "Type         : \(entry.operationType)",
                         "Status       : \(entry.status)", "Timestamp    : \(entry.timestamp)"]
            if let err = entry.error { lines.append("Error        : \(err)") }
            return lines.joined(separator: "\n")
        default: return response.json
        }
    }
}

/// Only on commands whose results are compact by default.
struct ResultOptions: ParsableArguments {
    @Flag(help: "Print the complete result instead of a compact summary with evidencePath.")
    var full = false
}

/// Adds a value to an arguments object only when the flag was given.
func put(_ arguments: inout [String: Any], _ key: String, _ value: Any?) {
    if let value { arguments[key] = value }
}

func flag(_ value: Bool) -> Bool? { value ? true : nil }

@main
struct C1: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "c1",
        abstract: "Unofficial CLI interface for Capture One automation.",
        subcommands: [
            ReadSessionCommand.self,
            CatalogCommand.self,
            NativeCommand.self,
            DoctorCommand.self,
            VersionCommand.self,
            CapabilitiesCommand.self,
            SchemaCommand.self,
            DocCommand.self,
            VariantsCommand.self,
            VariantCommand.self,
            GetCommand.self,
            SetCommand.self,
            AddCommand.self,
            ResetCommand.self,
            GeometryCommand.self,
            RecipeCommand.self,
            MetadataCommand.self,
            DiffCommand.self,
            DumpCommand.self,
            PreviewCommand.self,
            OperationCommand.self,
            RequestCommand.self
        ]
    )
}

// MARK: - Doctor
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check environment, app status, exact build, and document readiness.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        try globals.run("doctor", { [:] }) { response in
            guard case .doctor(let report) = response else { return print(response.json) }
            print(OutputFormatter.renderDoctorReport(report, format: globals.outputFormat))
            if !report.allChecksPassed {
                if let error = report.diagnosticError {
                    throw error
                } else if !report.appRunning {
                    throw C1Error.appNotRunning("Capture One is not running.")
                } else if !report.hasDocument {
                    throw C1Error.noDocument("No document is currently open in Capture One.")
                } else if !report.lockAcquired {
                    throw C1Error.captureOneBusy("Capture One application lock could not be acquired.")
                } else if (report.unresolvedOperationsCount ?? 0) > 0 {
                    throw C1Error.invalidRequest("Doctor diagnostic detected unresolved operations.")
                } else if SessionController.evaluateVersionCompatibility(report.appVersion).isAllowed {
                    throw C1Error.documentChanged("Exactly one open document is required.")
                } else {
                    throw C1Error.unsupportedVersion("Running version '\(report.appVersion)' is not supported (supported: 16.4+ through 16.x; tested: \(report.testedBuilds.joined(separator: ", "))). Set C1_ALLOW_UNTESTED_BUILD=1 to override.")
                }
            }
        }
    }
}

// MARK: - Version
/// Static build information; not a contract tool, so it takes no request.
struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Show c1 version, pinned Capture One version, and schema version.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let code = handleExecution(tool: "version", format: globals.outputFormat, progressMode: globals.progressMode) {
            let info: [String: Any] = [
                "c1Version": "0.1.0",
                "testedCaptureOneBuilds": SessionController.testedBuilds,
                "pinnedCaptureOneBuild": SessionController.pinnedBuild,
                "supportedVersionRange": "16.4+ through 16.x",
                "schemaVersion": ContractSchema.version,
                "platform": "macOS-arm64"
            ]
            if OutputFormatter.resolveFormat(globals.outputFormat) == .json {
                if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                print("c1 version 0.1.0 (tested for Capture One: \(SessionController.testedBuilds.joined(separator: ", ")))")
                print("Supported Capture One versions: 16.4+ through 16.x")
                print("Schema version: \(ContractSchema.version)")
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Capabilities
struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capabilities", abstract: "Show capability matrix for running Capture One build.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws { try globals.run("capabilities", { [:] }) }
}

// MARK: - Schema
struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schema", abstract: "Output JSON Schema for c1 requests and responses.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws { try globals.run("schema", { [:] }) }
}

// MARK: - Doc
struct DocCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doc",
        abstract: "Document inspection commands.",
        subcommands: [DocInfoCommand.self]
    )
}

struct DocInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show current open document info and open token.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws { try globals.run("doc_info", { [:] }) }
}

// MARK: - Variants
struct VariantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract: "Manage and inspect variants.",
        subcommands: [VariantsListCommand.self]
    )
}

struct VariantsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List live variants, or stored Catalog variants with --database.")
    @Option(help: "Known native IDs, comma-separated (1–512 unique IDs); always reads fresh.")
    var ids: String?

    @Option(help: "Subset fields: minimal (ID, rating, parent image path) or summary. Requires --ids.")
    var fields: String?

    @Option(help: "Exact absolute parent image path filter; requires --ids.")
    var parentPath: String?

    @OptionGroup var globals: GlobalOptions
    @Flag(help: "Force fresh native reads, including mutation tokens; bypass the browsing workflow.")
    var live = false

    @Option(help: "Explicit .cocatalogdb: use parallel-capable SQLite stored discovery; returns provenance and database identities, not live references.")
    var database: String?

    @Option(help: "Explicit stored collection ID; requires --database. Does not evaluate smart collections.")
    var collectionID: Int?

    @Flag(help: "List only selected variants.")
    var selected: Bool = false

    @Option(help: "Name of the collection to list variants from (e.g. Capture).")
    var collection: String?

    @Option(help: "Exact star rating (0–5; 0 means unrated). Cannot combine with --min-rating.")
    var rating: Int?

    @Option(help: "Inclusive minimum star rating (0–5). Cannot combine with --rating.")
    var minRating: Int?

    @Option(help: "Maximum variants per inventory batch (1–256; default 32).")
    var batchSize: Int?

    @Option(help: "Read deadline checked between Apple Events; does not interrupt an outstanding event.")
    var deadlineSeconds: Double?

    mutating func run() throws {
        if let database {
            try globals.run("catalog_variants", {
                guard ids == nil, fields == nil, parentPath == nil, !live, !selected, collection == nil, deadlineSeconds == nil, batchSize == nil else {
                    throw C1Error.invalidRequest("--database uses stored discovery: --selected, --collection, --deadline-seconds and custom --batch-size require live AppleScript reads. Use --collection-id for explicit stored membership.")
                }
                var args: [String: Any] = ["database": database]
                put(&args, "collectionID", collectionID); put(&args, "rating", rating); put(&args, "minRating", minRating)
                return args
            })
            return
        }
        try globals.run("variants_list", {
            guard collectionID == nil else { throw C1Error.invalidRequest("--collection-id requires --database.") }
            var args: [String: Any] = [:]
            put(&args, "ids", ids?.components(separatedBy: ",")); put(&args, "fields", fields); put(&args, "parentPath", parentPath)
            put(&args, "live", flag(live)); put(&args, "selected", flag(selected)); put(&args, "collection", collection)
            put(&args, "rating", rating); put(&args, "minRating", minRating); put(&args, "batchSize", batchSize)
            put(&args, "deadlineSeconds", deadlineSeconds); put(&args, "readWorkflow", globals.readWorkflowID)
            return args
        })
    }
}

// MARK: - Variant (clone / delete / baseline)
struct VariantCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variant",
        abstract: "Edit existing variants or manage optional clones.",
        subcommands: [VariantEditCommand.self, VariantCloneCommand.self, VariantDeleteCommand.self, VariantBaselineCommand.self]
    )
}

func renderClone(_ response: ToolResponse, _ lines: (title: String, clone: String, source: String), globals: GlobalOptions) {
    guard case .clone(let res) = response, OutputFormatter.resolveFormat(globals.outputFormat) != .json else { return print(response.json) }
    print(lines.title)
    print("  Working Ref     : \(res.workingRef)")
    print("  \(lines.clone): \(res.cloneVariantId)")
    print("  \(lines.source): \(res.sourceVariantId)")
    print("  Baseline Hash   : \(res.baselineStateHash)")
}

struct VariantCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clone", abstract: "Clone a source variant and return a c1 working reference.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Source variant native ID or name.")
    var sourceRef: String

    mutating func run() throws {
        try globals.run("variant_clone", { ["sourceRef": sourceRef] }) {
            renderClone($0, ("Created working clone:", "Clone Native ID ", "Source Native ID"), globals: globals)
        }
    }
}

struct VariantDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a c1-managed working clone. (Originals cannot be deleted).")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>) to delete.")
    var workingRef: String

    mutating func run() throws { try globals.run("variant_delete", { ["workingRef": workingRef] }) }
}

struct VariantBaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "baseline", abstract: "Create a managed default-settings baseline variant using native New Variant behavior.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Source variant native ID or name.")
    var sourceRef: String

    mutating func run() throws {
        try globals.run("variant_baseline", { ["sourceRef": sourceRef] }) {
            renderClone($0, ("Created managed baseline variant:", "Baseline Nat ID ", "Source Nat ID   "), globals: globals)
        }
    }
}

// MARK: - Get
struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get adjustments and metadata for a variant or working ref.")
    @OptionGroup var globals: GlobalOptions
    @Flag(help: "Force fresh native reads, including mutation tokens; bypass the browsing workflow.")
    var live = false

    @Argument(help: "Native variant ID or working reference.")
    var ref: String

    @Option(help: "Optional JSON array of native scopes, e.g. [{\"scope\":\"adjustments\"},{\"scope\":\"lens\"}].")
    var nativeTargets: String?

    @Option(help: "Inspect a stored variant in an explicit Catalog database, even when closed. No native tokens.")
    var database: String?

    mutating func run() throws {
        if let database {
            try globals.run("catalog_get", {
                guard !live, nativeTargets == nil, let id = Int(ref) else { throw C1Error.invalidRequest("--database requires a numeric stored variant ID and cannot combine with --live or --native-targets.") }
                return ["database": database, "variantID": id]
            })
            return
        }
        try globals.run("get", {
            var args: [String: Any] = ["ref": ref]
            put(&args, "live", flag(live)); put(&args, "readWorkflow", globals.readWorkflowID)
            put(&args, "nativeTargets", try nativeTargets.map { try jsonArgument($0, name: "--native-targets") })
            return args
        })
    }
}

/// A JSON flag value, decoded into the arguments object unchanged.
func jsonArgument(_ text: String, name: String) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
    catch { throw C1Error.invalidRequest("\(name) must be valid JSON.") }
}

// MARK: - Helper to map input adjustments
func adjustmentArguments(keyValues: [String], jsonStr: String?, filePath: String?) throws -> Any {
    let sources = (keyValues.isEmpty ? 0 : 1) + (jsonStr == nil ? 0 : 1) + (filePath == nil ? 0 : 1)
    guard sources == 1 else { throw C1Error.invalidRequest("Provide exactly one of key=value pairs, --json, or --file.") }
    let data: Data
    if let json = jsonStr { data = Data(json.utf8) }
    else if let path = filePath {
        data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: path.hasPrefix("@") ? String(path.dropFirst()) : path))
    } else { return try FieldRegistry.shared.keyValueArguments(keyValues) }
    guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw C1Error.invalidRequest("Adjustments must be a JSON object.")
    }
    return values
}

// MARK: - Set
struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set absolute adjustments on an editing reference or managed clone.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>).")
    var workingRef: String

    @Option(help: "Expected stateHash before applying mutation (precondition).")
    var ifState: String

    @Option(help: "Inline JSON adjustments string.")
    var json: String?

    @Option(help: "Path to JSON adjustments file (or '-' for stdin).")
    var file: String?

    @Flag(help: "Predict diff and target hash without mutating.")
    var dryRun: Bool = false

    @Argument(parsing: .remaining, help: "key=value adjustment pairs (e.g. exposure=0.3 kelvin=5400).")
    var keyValues: [String] = []

    mutating func run() throws {
        try globals.run("set", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifState": ifState,
                                       "adjustments": try adjustmentArguments(keyValues: keyValues, jsonStr: json, filePath: file)]
            put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

// MARK: - Add
struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Apply relative delta adjustments on an editing reference or managed clone.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>).")
    var workingRef: String

    @Option(help: "Expected stateHash before applying mutation (precondition).")
    var ifState: String

    @Option(help: "Inline JSON adjustments string.")
    var json: String?

    @Option(help: "Path to JSON adjustments file (or '-' for stdin).")
    var file: String?

    @Flag(help: "Predict diff and target hash without mutating.")
    var dryRun: Bool = false

    @Argument(parsing: .remaining, help: "key=value adjustment deltas (e.g. exposure=-0.2 kelvin=+150).")
    var keyValues: [String] = []

    mutating func run() throws {
        try globals.run("add", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifState": ifState,
                                       "adjustments": try adjustmentArguments(keyValues: keyValues, jsonStr: json, filePath: file)]
            put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

// MARK: - Reset
struct ResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset verified adjustment fields on an editing reference or managed clone.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>).")
    var workingRef: String

    @Option(help: "Expected stateHash before applying mutation (precondition).")
    var ifState: String

    @Flag(help: "Predict diff and target hash without mutating.")
    var dryRun: Bool = false

    @Argument(parsing: .remaining, help: "Optional fields to reset (e.g. exposure wb contrast). If omitted, resets all verified fields.")
    var fields: [String] = []

    mutating func run() throws {
        try globals.run("reset", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifState": ifState]
            put(&args, "fields", fields.isEmpty ? nil : fields); put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

// MARK: - Diff
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "Compare adjustments between two variants or compare a working variant against its baseline.")
    @OptionGroup var globals: GlobalOptions
    @Flag(help: "Force fresh native reads, including mutation tokens; bypass the browsing workflow.")
    var live = false

    @Argument(help: "First variant reference (or working reference to compare against its baseline).")
    var ref1: String

    @Argument(help: "Optional second variant reference to compare against ref1.")
    var ref2: String?

    mutating func run() throws {
        try globals.run("diff", {
            var args: [String: Any] = ["ref1": ref1]
            put(&args, "ref2", ref2); put(&args, "live", flag(live)); put(&args, "readWorkflow", globals.readWorkflowID)
            return args
        })
    }
}

// MARK: - Dump
struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump", abstract: "Batched export of variants, adjustments, and metadata as JSONL.")
    @OptionGroup var globals: GlobalOptions
    @Flag(help: "Force fresh native reads, including mutation tokens; bypass the browsing workflow.")
    var live = false

    @Option(help: "Name of collection to dump variants from.")
    var collection: String?

    @Flag(help: "Dump only selected variants.")
    var selected: Bool = false

    @Option(help: "Chunk size for batched variant queries (1–1000; default 100).")
    var batchSize: Int?

    @Option(help: "Dump format: jsonl (default), json, or human.")
    var dumpFormat: String = "jsonl"

    mutating func run() throws {
        let format = dumpFormat.lowercased(), globals = globals
        try globals.run("dump", {
            var args: [String: Any] = [:]
            put(&args, "collection", collection); put(&args, "selected", flag(selected)); put(&args, "live", flag(live))
            put(&args, "batchSize", batchSize); put(&args, "readWorkflow", globals.readWorkflowID)
            return args
        }) { response in
            switch response {
            case .object(let value) where format == "jsonl" && value is [[String: Any]]:
                    for row in value as! [[String: Any]] { print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!) }
            case .dump(let records):
                if format == "jsonl" || (format != "json" && format != "human" && globals.outputFormat != .human) {
                    print(OutputFormatter.renderDump(records, format: globals.outputFormat, jsonl: true))
                } else if format == "json" || globals.outputFormat == .json {
                    print(OutputFormatter.renderDump(records, format: .json, jsonl: false))
                } else {
                    print(OutputFormatter.renderDump(records, format: .human, jsonl: false))
                }
            default: print(response.json)
            }
        }
    }
}

// MARK: - Preview
struct PreviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preview", abstract: "Export and verify dedicated preview JPEG for a variant or working clone.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions

    @Argument(help: "Variant reference (working ref c1_wrk_<uuid> or native variant ID).")
    var ref: String

    @Option(help: "Custom output directory.")
    var outputDir: String?

    @Option(help: "Timeout in seconds for preview render (default 30).")
    var timeout: Double?

    @Flag(help: "Render full-frame context using a temporary managed clone.")
    var fullFrame: Bool = false

    mutating func run() throws {
        try globals.run("preview", full: result, {
            var args: [String: Any] = ["ref": ref]
            put(&args, "outputDir", outputDir); put(&args, "timeout", timeout); put(&args, "fullFrame", flag(fullFrame))
            return args
        })
    }
}

// MARK: - Operation
struct OperationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operation",
        abstract: "Inspect operation journal.",
        subcommands: [OperationStatusCommand.self]
    )
}

struct OperationStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Inspect operation status in the document journal.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Operation ID to check.")
    var operationId: String

    mutating func run() throws { try globals.run("operation_status", { ["operationId": operationId] }) }
}

struct GeometryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "geometry", abstract: "Crop, rotation, and keystone on managed variants.", subcommands: [GeometrySetCommand.self, GeometryRestoreCommand.self])
}
struct GeometrySetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set absolute crop/rotation/keystone; preserves other edits.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    @Argument var workingRef: String
    @Option(help: "geometryStateHash from get, independent of the tonal stateHash.") var ifGeometryState: String
    @Option(help: "centerX,centerY,width,height in rotated-canvas pixels, bottom-left origin.") var crop: String?
    @Option(help: "Absolute rotation in degrees (-45 to 45).") var rotation: Double?
    @Option(help: "Width/height ratio for a centered crop fitted inside safe bounds (1.5 landscape, 0.75 portrait).") var aspectRatio: Double?
    @Option(help: "Keystone amount (integer 10 to 120).") var keystoneAmount: Double?
    @Option(help: "Absolute vertical keystone (-75 to 75).") var keystoneVertical: Double?
    @Option(help: "Absolute horizontal keystone (-75 to 75).") var keystoneHorizontal: Double?
    @Option(help: "Absolute keystone skew (-45 to 45).") var keystoneSkew: Double?
    @Option(help: "Absolute keystone aspect (-50 to 100).") var keystoneAspect: Double?
    @Flag var dryRun: Bool = false
    mutating func run() throws {
        try globals.run("geometry_set", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifGeometryState": ifGeometryState]
            if let crop {
                let parts = crop.split(separator: ",", omittingEmptySubsequences: false)
                let values = parts.compactMap { Double($0) }
                guard parts.count == 4, values.count == 4 else { throw C1Error.invalidRequest("crop requires centerX,centerY,width,height.") }
                args["crop"] = ["centerX": values[0], "centerY": values[1], "width": values[2], "height": values[3]]
            }
            put(&args, "rotation", rotation); put(&args, "aspectRatio", aspectRatio); put(&args, "dryRun", flag(dryRun))
            var keystone: [String: Any] = [:]
            for (name, value) in zip(KeystoneAdjustments.fields, [keystoneAmount, keystoneVertical, keystoneHorizontal, keystoneSkew, keystoneAspect]) {
                put(&keystone, name, value)
            }
            if !keystone.isEmpty { args["keystone"] = keystone }
            return args
        })
    }
}

struct VariantEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Prepare adjustment and geometry editing of an existing variant without cloning.")
    @OptionGroup var globals: GlobalOptions
    @Argument var sourceRef: String
    @Option(help: "stateHash from get.") var ifState: String
    @Option(help: "Optional geometryStateHash check from get.") var ifGeometryState: String?
    @Option(help: "openToken from doc info when selecting the targets.") var ifDocument: String
    mutating func run() throws {
        try globals.run("variant_edit", {
            var args: [String: Any] = ["sourceRef": sourceRef, "ifState": ifState, "ifDocument": ifDocument]
            put(&args, "ifGeometryState", ifGeometryState)
            return args
        })
    }
}

struct GeometryRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore saved crop/rotation/keystone with fresh state and matching geometry context.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    @Argument var workingRef: String
    @Option var ifGeometryState: String
    @Flag var dryRun: Bool = false
    mutating func run() throws {
        try globals.run("geometry_restore", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifGeometryState": ifGeometryState]
            put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

// This inspection path never contacts Capture One and remains usable during another request.
struct RequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request", abstract: "Inspect local request diagnostics.", subcommands: [RequestStatusCommand.self])
}
struct RequestStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Read stored request progress without contacting Capture One.")
    @OptionGroup var globals: GlobalOptions
    @Argument var requestId: String
    mutating func run() throws { try globals.run("request_status", { ["requestId": requestId] }) }
}


struct MetadataCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metadata", abstract: "Edit ratings and color tags.", subcommands: [MetadataSetCommand.self])
}
struct MetadataSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set rating and/or color tag on an editing reference or managed clone.")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    @Argument var workingRef: String
    @Option(help: "metadataStateHash from a fresh get.") var ifMetadataState: String
    @Option(help: "Star rating: integer 0–5; 0 clears.") var rating: Int?
    @Option(help: "Native color tag: integer 0–7; 0 clears.") var colorTag: Int?
    @Flag var dryRun: Bool = false
    mutating func run() throws {
        try globals.run("metadata_set", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifMetadataState": ifMetadataState]
            put(&args, "rating", rating); put(&args, "colorTag", colorTag); put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

// MARK: - Native editing
struct NativeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native", abstract: "Typed native adjustments, curves, layers, and masks.", subcommands: [NativeSetCommand.self, NativeActionCommand.self])
}
struct NativeTargetOptions: ParsableArguments {
    @Option(help: "adjustments, lens, layer, luma, basicColor, advancedColor, or variant.") var scope: String = "adjustments"
    @Option(help: "1-based layer index; 0 (default) means image adjustments.") var layer: Int?
    @Option(help: "1-based color-editor element index.") var element: Int?
    var target: [String: Any] {
        var target: [String: Any] = ["scope": scope]
        put(&target, "layer", layer); put(&target, "element", element)
        return target
    }
}
struct NativeSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName:"set")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    @OptionGroup var target: NativeTargetOptions
    @Argument var workingRef: String
    @Option var ifNativeState: String
    @Option(help:"JSON object using exact dictionary property names. Curves are flat x,y pairs.") var json: String
    @Flag var dryRun = false
    mutating func run() throws {
        try globals.run("native_set", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifNativeState": ifNativeState, "target": target.target,
                                       "patch": try jsonArgument(json, name: "--json")]
            put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}
struct NativeActionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName:"action")
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    @OptionGroup var target: NativeTargetOptions
    @Argument var workingRef: String
    @Argument var action: String
    @Option var ifNativeState: String
    @Option(help:"JSON action arguments.") var json: String?
    @Flag var dryRun = false
    mutating func run() throws {
        try globals.run("native_action", full: result, {
            var args: [String: Any] = ["workingRef": workingRef, "ifNativeState": ifNativeState, "target": target.target, "action": action]
            put(&args, "arguments", try json.map { try jsonArgument($0, name: "--json") }); put(&args, "dryRun", flag(dryRun))
            return args
        })
    }
}

struct CatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "catalog", abstract: "Inspect stored Catalog records or archive a SQLite snapshot without contacting Capture One.", subcommands: [CatalogInspect.self, CatalogSnapshot.self, CatalogVariants.self])
}
struct CatalogInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect")
    @Option var database: String
    @OptionGroup var globals: GlobalOptions
    mutating func run() throws { try globals.run("catalog_inspect", { ["database": database] }) }
}
struct CatalogSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot")
    @Option var database: String
    @Option var destination: String
    @OptionGroup var globals: GlobalOptions
    mutating func run() throws { try globals.run("catalog_snapshot", { ["database": database, "destination": destination] }) }
}

struct CatalogVariants: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "variants", abstract: "Discover distinct stored variants through SQLite; explicit memberships only.")
    @Option var database: String
    @Option var collectionID: Int?
    @Option var rating: Int?
    @Option var minRating: Int?
    @OptionGroup var globals: GlobalOptions
    mutating func run() throws {
        try globals.run("catalog_variants", {
            var args: [String: Any] = ["database": database]
            put(&args, "collectionID", collectionID); put(&args, "rating", rating); put(&args, "minRating", minRating)
            return args
        })
    }
}

struct ReadSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read-session", abstract: "Begin/end exclusive c1 browsing; end before returning to UI editing.", subcommands: [ReadSessionBegin.self, ReadSessionEnd.self, ReadSessionStatus.self])
}
struct ReadSessionBegin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "begin")
    @OptionGroup var globals: GlobalOptions
    @Option var collection: String?
    @Flag var selected = false
    mutating func run() throws {
        try globals.run("read_session_begin", {
            var args: [String: Any] = [:]
            put(&args, "collection", collection); put(&args, "selected", flag(selected))
            return args
        })
    }
}
struct ReadSessionEnd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "end")
    @OptionGroup var globals: GlobalOptions
    mutating func run() throws {
        let workflow = globals.readWorkflowID
        try globals.run("read_session_end", { workflow.map { ["readWorkflow": $0] } ?? [:] })
    }
}
struct ReadSessionStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var globals: GlobalOptions
    mutating func run() throws {
        let workflow = globals.readWorkflowID
        try globals.run("read_session_status", { workflow.map { ["readWorkflow": $0] } ?? [:] })
    }
}


struct RecipeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName:"recipe", abstract:"Reference capture, registration, verification and single-photo compound editing.")
    @Argument(help:"capture, register, verify, apply, or status") var action: String
    @Option(help:"JSON request file using the shared MCP schema.") var file: String
    @OptionGroup var globals: GlobalOptions
    @OptionGroup var result: ResultOptions
    mutating func run() throws {
        let names = ["capture":"reference_capture","register":"recipe_register","verify":"recipe_verify","apply":"edit_apply","status":"edit_status"]
        try globals.run(names[action] ?? "recipe", full: result, {
            guard names[action] != nil, let args = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as? [String:Any] else { throw C1Error.invalidRequest("Expected recipe action and JSON object request.") }
            return args
        })
    }
}
