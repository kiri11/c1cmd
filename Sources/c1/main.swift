import Foundation
import ArgumentParser
import CaptureOneCore

struct GlobalOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output format: auto, json, or human.")
    var format: String = "auto"

    var outputFormat: OutputFormat {
        switch format.lowercased() {
        case "json": return .json
        case "human": return .human
        default: return .auto
        }
    }
}

func handleExecution<T>(format: OutputFormat, _ block: () throws -> T) -> ExitCode {
    do {
        _ = try block()
        return ExitCode.success
    } catch {
        if OutputFormatter.resolveFormat(format) == .json,
           let data = try? JSONSerialization.data(withJSONObject: ErrorResponse.payload(error), options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
        return ExitCode(error is OperationFailure ? 4 : (error as? C1Error)?.exitCode ?? 1)
    }
}

@main
struct C1: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "c1",
        abstract: "Unofficial CLI interface for Capture One automation.",
        subcommands: [
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
            DiffCommand.self,
            DumpCommand.self,
            PreviewCommand.self,
            OperationCommand.self
        ]
    )
}

// MARK: - Doctor
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check environment, app status, exact build, and document readiness.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let report = try SessionController.shared.doctor()
            let output = OutputFormatter.renderDoctorReport(report, format: globals.outputFormat)
            print(output)
            if !report.allChecksPassed {
                if !report.appRunning {
                    throw C1Error.appNotRunning("Capture One is not running.")
                } else if !report.hasDocument {
                    throw C1Error.noDocument("No document is currently open in Capture One.")
                } else if !report.lockAcquired {
                    throw C1Error.captureOneBusy("Capture One application lock could not be acquired.")
                } else if report.unresolvedOperationsCount > 0 {
                    throw C1Error.invalidRequest("Doctor diagnostic detected unresolved operations.")
                } else if SessionController.evaluateVersionCompatibility(report.appVersion).isAllowed {
                    throw C1Error.documentChanged("Exactly one open document is required.")
                } else {
                    throw C1Error.unsupportedVersion("Running version '\(report.appVersion)' is not supported (supported: 16.4+ through 16.x; tested: \(report.testedBuilds.joined(separator: ", "))). Set C1_ALLOW_UNTESTED_BUILD=1 to override.")
                }
            }
        }
        if code != .success {
            throw ExitCode(code.rawValue)
        }
    }
}

// MARK: - Version
struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Show c1 version, pinned Capture One version, and schema version.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
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

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let caps = SessionController.shared.capabilities()
            if let data = try? JSONSerialization.data(withJSONObject: caps, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Schema
struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schema", abstract: "Output JSON Schema for c1 requests and responses.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let schema = ContractSchema.document()
        if let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
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
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show current open Session document info and open token.")
    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let info = try SessionController.shared.getDocumentInfo()
            print(OutputFormatter.renderDocumentInfo(info, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
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
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List variants in the current Session.")
    @OptionGroup var globals: GlobalOptions

    @Flag(help: "List only selected variants.")
    var selected: Bool = false

    @Option(help: "Name of the collection to list variants from (e.g. Capture).")
    var collection: String?

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let list = try SessionController.shared.listVariants(collectionName: collection, selectedOnly: selected)
            print(OutputFormatter.renderVariants(list, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Variant (clone / delete / baseline)
struct VariantCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variant",
        abstract: "Manage individual variants (clone, delete, baseline).",
        subcommands: [VariantCloneCommand.self, VariantDeleteCommand.self, VariantBaselineCommand.self]
    )
}

struct VariantCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clone", abstract: "Clone a source variant and return a c1 working reference.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Source variant native ID or name.")
    var sourceRef: String

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.cloneVariant(sourceRef: sourceRef)
            if OutputFormatter.resolveFormat(globals.outputFormat) == .json {
                print(OutputFormatter.formatJson(res))
            } else {
                print("Created working clone:")
                print("  Working Ref     : \(res.workingRef)")
                print("  Clone Native ID : \(res.cloneVariantId)")
                print("  Source Native ID: \(res.sourceVariantId)")
                print("  Baseline Hash   : \(res.baselineStateHash)")
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

struct VariantDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a c1-managed working clone. (Originals cannot be deleted).")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>) to delete.")
    var workingRef: String

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.deleteVariant(workingRefString: workingRef)
            if OutputFormatter.resolveFormat(globals.outputFormat) == .json {
                print(OutputFormatter.formatJson(res))
            } else {
                print("Deleted working variant:")
                print("  Working Ref: \(res.workingRef)")
                print("  Clone ID   : \(res.cloneVariantId)")
                print("  Deleted    : \(res.deleted)")
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

struct VariantBaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "baseline", abstract: "Create a managed default-settings baseline variant using native New Variant behavior.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Source variant native ID or name.")
    var sourceRef: String

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.createBaselineVariant(sourceRef: sourceRef)
            if OutputFormatter.resolveFormat(globals.outputFormat) == .json {
                print(OutputFormatter.formatJson(res))
            } else {
                print("Created managed baseline variant:")
                print("  Working Ref     : \(res.workingRef)")
                print("  Baseline Nat ID : \(res.cloneVariantId)")
                print("  Source Nat ID   : \(res.sourceVariantId)")
                print("  Baseline Hash   : \(res.baselineStateHash)")
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Get
struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get adjustments and metadata for a variant or working ref.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Native variant ID or working reference.")
    var ref: String

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.get(ref: ref)
            print(OutputFormatter.renderGetResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Helper to parse input adjustments
func parseAdjustmentInputs(keyValues: [String], jsonStr: String?, filePath: String?, delta: Bool = false) throws -> Adjustments {
    let sources = (keyValues.isEmpty ? 0 : 1) + (jsonStr == nil ? 0 : 1) + (filePath == nil ? 0 : 1)
    guard sources == 1 else { throw C1Error.invalidRequest("Provide exactly one of key=value pairs, --json, or --file.") }
    let data: Data
    if let json = jsonStr { data = Data(json.utf8) }
    else if let path = filePath {
        data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: path.hasPrefix("@") ? String(path.dropFirst()) : path))
    } else { return try FieldRegistry.shared.parseKeyValueArguments(keyValues) }
    guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw C1Error.invalidRequest("Adjustments must be a JSON object.")
    }
    return try ContractSchema.parseAdjustments(values, delta: delta)
}

// MARK: - Set
struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set absolute adjustments on a managed working clone.")
    @OptionGroup var globals: GlobalOptions

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
        let code = handleExecution(format: globals.outputFormat) {
            let adjustments = try parseAdjustmentInputs(keyValues: keyValues, jsonStr: json, filePath: file)
            let res = try SessionController.shared.mutate(
                workingRefString: workingRef,
                ifState: ifState,
                setAdjustments: adjustments,
                addAdjustments: nil,
                isDryRun: dryRun
            )
            print(OutputFormatter.renderMutationResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Add
struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Apply relative delta adjustments on a managed working clone.")
    @OptionGroup var globals: GlobalOptions

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
        let code = handleExecution(format: globals.outputFormat) {
            let adjustments = try parseAdjustmentInputs(keyValues: keyValues, jsonStr: json, filePath: file, delta: true)
            let res = try SessionController.shared.mutate(
                workingRefString: workingRef,
                ifState: ifState,
                setAdjustments: nil,
                addAdjustments: adjustments,
                isDryRun: dryRun
            )
            print(OutputFormatter.renderMutationResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Reset
struct ResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset verified adjustment fields on a managed working clone.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Working reference (c1_wrk_<uuid>).")
    var workingRef: String

    @Option(help: "Expected stateHash before applying mutation (precondition).")
    var ifState: String

    @Flag(help: "Predict diff and target hash without mutating.")
    var dryRun: Bool = false

    @Argument(parsing: .remaining, help: "Optional fields to reset (e.g. exposure wb contrast). If omitted, resets all verified fields.")
    var fields: [String] = []

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.reset(
                workingRefString: workingRef,
                ifState: ifState,
                fields: fields,
                isDryRun: dryRun
            )
            print(OutputFormatter.renderMutationResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Diff
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "Compare adjustments between two variants or compare a working variant against its baseline.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "First variant reference (or working reference to compare against its baseline).")
    var ref1: String

    @Argument(help: "Optional second variant reference to compare against ref1.")
    var ref2: String?

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.diff(ref1: ref1, ref2: ref2)
            print(OutputFormatter.renderDiffResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Dump
struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump", abstract: "Batched export of variants, adjustments, and metadata as JSONL.")
    @OptionGroup var globals: GlobalOptions

    @Option(help: "Name of collection to dump variants from.")
    var collection: String?

    @Flag(help: "Dump only selected variants.")
    var selected: Bool = false

    @Option(help: "Chunk size for batched variant queries.")
    var batchSize: Int = 100

    @Option(help: "Dump format: jsonl (default), json, or human.")
    var dumpFormat: String = "jsonl"

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let records = try SessionController.shared.dump(
                collectionName: collection,
                selectedOnly: selected,
                batchSize: batchSize
            )
            let isJsonl = dumpFormat.lowercased() == "jsonl" || (dumpFormat.lowercased() != "json" && dumpFormat.lowercased() != "human" && globals.outputFormat != .human)
            if isJsonl {
                print(OutputFormatter.renderDump(records, format: globals.outputFormat, jsonl: true))
            } else if dumpFormat.lowercased() == "json" || globals.outputFormat == .json {
                print(OutputFormatter.renderDump(records, format: .json, jsonl: false))
            } else {
                print(OutputFormatter.renderDump(records, format: .human, jsonl: false))
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

// MARK: - Preview
struct PreviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preview", abstract: "Export and verify dedicated preview JPEG for a variant or working clone.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Variant reference (working ref c1_wrk_<uuid> or native variant ID).")
    var ref: String

    @Option(help: "Custom output directory.")
    var outputDir: String?

    @Option(help: "Timeout in seconds for preview render.")
    var timeout: Double = 30.0

    @Flag(help: "Render full-frame context using a temporary managed clone.")
    var fullFrame: Bool = false

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let res = try SessionController.shared.preview(
                ref: ref,
                outputDirOverride: outputDir,
                timeout: timeout, fullFrame: fullFrame
            )
            print(OutputFormatter.renderPreviewResult(res, format: globals.outputFormat))
        }
        if code != .success { throw ExitCode(code.rawValue) }
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
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Inspect operation status in the Session journal.")
    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Operation ID to check.")
    var operationId: String

    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            let entry = try SessionController.shared.operationStatus(operationId: operationId)
            if OutputFormatter.resolveFormat(globals.outputFormat) == .json {
                print(OutputFormatter.formatJson(entry))
            } else {
                print("Operation Status")
                print("----------------")
                print("Operation ID : \(entry.operationId)")
                print("Type         : \(entry.operationType)")
                print("Status       : \(entry.status)")
                print("Timestamp    : \(entry.timestamp)")
                if let err = entry.error {
                    print("Error        : \(err)")
                }
            }
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}

struct GeometryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "geometry", abstract: "Crop and rotation on managed variants.", subcommands: [GeometrySetCommand.self])
}
struct GeometrySetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set absolute crop/rotation; preserves other edits.")
    @OptionGroup var globals: GlobalOptions
    @Argument var workingRef: String
    @Option(help: "geometryStateHash from get, independent of the tonal stateHash.") var ifGeometryState: String
    @Option(help: "centerX,centerY,width,height in rotated-canvas pixels, bottom-left origin.") var crop: String?
    @Option(help: "Absolute rotation in degrees (-45 to 45).") var rotation: Double?
    @Option(help: "Width/height ratio for a centered crop fitted inside safe bounds (1.5 landscape, 0.75 portrait).") var aspectRatio: Double?
    @Flag var dryRun: Bool = false
    mutating func run() throws {
        let code = handleExecution(format: globals.outputFormat) {
            var args: [String: Any] = ["workingRef":workingRef, "ifGeometryState":ifGeometryState, "dryRun":dryRun]
            var rect: CropRect?
            if let crop = crop {
                let parts = crop.split(separator:",", omittingEmptySubsequences:false)
                let values = parts.compactMap { Double($0) }
                guard parts.count == 4, values.count == 4 else { throw C1Error.invalidRequest("crop requires centerX,centerY,width,height.") }
                rect = CropRect(centerX:values[0], centerY:values[1], width:values[2], height:values[3])
                args["crop"] = ["centerX":values[0], "centerY":values[1], "width":values[2], "height":values[3]]
            }
            if let v = rotation { args["rotation"] = v }
            if let v = aspectRatio { args["aspectRatio"] = v }
            try ContractSchema.validate(tool: "geometry_set", arguments: args)
            let result = try SessionController.shared.geometrySet(workingRef:workingRef, ifGeometryState:ifGeometryState,
                crop:rect, rotation:rotation, aspectRatio:aspectRatio, dryRun:dryRun)
            print(OutputFormatter.formatJson(result))
        }
        if code != .success { throw ExitCode(code.rawValue) }
    }
}
