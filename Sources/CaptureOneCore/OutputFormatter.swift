import Foundation

public enum OutputFormat: String, Codable {
    case json
    case human
    case auto
}

public struct OutputFormatter {
    public static var isTerminal: Bool {
        isatty(STDOUT_FILENO) != 0
    }

    public static func resolveFormat(_ format: OutputFormat) -> OutputFormat {
        if format == .auto {
            return isTerminal ? .human : .json
        }
        return format
    }

    public static func formatJson<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    public static func renderDoctorReport(_ r: DoctorReport, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(r)
        }
        var lines: [String] = []
        lines.append("c1 Doctor Diagnostic Report")
        lines.append("===========================")
        lines.append("Capture One Process : \(r.appRunning ? "Running (OK)" : "Not Running (FAIL)")")
        lines.append("Capture One Version : \(r.appVersion) \(r.exactBuildMatched ? "(Pinned build matched: \(r.pinnedBuild))" : "(Expected \(r.pinnedBuild))")")
        lines.append("Active Document     : \(r.hasDocument ? (r.docName ?? "Unknown") : "None (FAIL)")")
        lines.append("Document Type       : \(r.isSession ? "Session (OK)" : "Catalog or unsupported (FAIL)")")
        if let p = r.docPath {
            lines.append("Document Path       : \(p)")
        }
        lines.append("Advisory Lock       : \(r.lockAcquired ? "Available (OK)" : "Contended / Failed (FAIL)")")
        lines.append("Unresolved Ops      : \(r.unresolvedOperationsCount == 0 ? "0 (Clean)" : "\(r.unresolvedOperationsCount) (Warning: pending/failed ops in journal)")")
        lines.append("---------------------------")
        lines.append("Status              : \(r.allChecksPassed ? "READY (All checks passed)" : "ISSUES DETECTED")")
        return lines.joined(separator: "\n")
    }

    public static func renderDocumentInfo(_ info: DocumentInfo, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(info)
        }
        var lines: [String] = []
        lines.append("Session Document Information")
        lines.append("----------------------------")
        lines.append("Name          : \(info.documentName)")
        lines.append("Path          : \(info.documentPath)")
        lines.append("Capture Folder: \(info.captureFolder)")
        lines.append("Output Folder : \(info.outputFolder)")
        lines.append("Open Token    : \(info.openToken)")
        return lines.joined(separator: "\n")
    }

    public static func renderVariants(_ variants: [VariantSummary], format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(variants)
        }
        if variants.isEmpty {
            return "No variants found."
        }
        var lines: [String] = []
        lines.append(String(format: "%-6s  %-24s  %-8s  %-5s  %-6s  %-36s", "ID", "NAME", "SELECTED", "STARS", "TAG", "MANAGED WORKING REF"))
        lines.append(String(repeating: "-", count: 90))
        for v in variants {
            let workingRefDisplay = v.workingRef ?? (v.isManagedWorkingClone ? "(managed)" : "-")
            lines.append(String(
                format: "%-6s  %-24s  %-8s  %-5d  %-6d  %-36s",
                v.id,
                String(v.name.prefix(24)),
                v.isSelected ? "yes" : "no",
                v.rating,
                v.colorTag,
                workingRefDisplay
            ))
        }
        return lines.joined(separator: "\n")
    }

    public static func renderGetResult(_ res: GetResult, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(res)
        }
        var lines: [String] = []
        lines.append("Variant Adjustments & Metadata")
        lines.append("------------------------------")
        lines.append("Native ID    : \(res.id)")
        if let w = res.workingRef {
            lines.append("Working Ref  : \(w)")
        }
        lines.append("State Hash   : \(res.stateHash)")
        lines.append("\nAdjustments:")
        if let v = res.adjustments.exposure { lines.append(String(format: "  exposure    : %+.4f EV", v)) }
        if let v = res.adjustments.contrast { lines.append(String(format: "  contrast    : %+.2f", v)) }
        if let v = res.adjustments.saturation { lines.append(String(format: "  saturation  : %+.2f", v)) }
        if let v = res.adjustments.temperature { lines.append(String(format: "  temperature : %.1f K", v)) }
        if let v = res.adjustments.tint { lines.append(String(format: "  tint        : %+.2f", v)) }

        lines.append("\nMetadata:")
        if let v = res.metadata.camera { lines.append("  camera      : \(v)") }
        if let v = res.metadata.lens { lines.append("  lens        : \(v)") }
        if let v = res.metadata.iso { lines.append("  ISO         : \(v)") }
        if let v = res.metadata.shutterSpeed { lines.append("  shutter     : \(v)") }
        if let v = res.metadata.asShotWB { lines.append("  as-shot WB  : \(v)") }
        if let v = res.metadata.captureDate { lines.append("  date        : \(v)") }
        if let v = res.metadata.rating { lines.append("  rating      : \(v)") }
        if let v = res.metadata.colorTag { lines.append("  colorTag    : \(v)") }
        return lines.joined(separator: "\n")
    }

    public static func renderMutationResult(_ res: MutationResult, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(res)
        }
        var lines: [String] = []
        lines.append(res.isDryRun ? "Predicted Mutation Diff (Dry Run)" : "Applied Mutation Diff")
        lines.append("---------------------------------")
        lines.append("Operation ID: \(res.operationId)")
        lines.append("Working Ref : \(res.workingRef)")
        lines.append("New Hash    : \(res.stateHash)")
        lines.append("")
        lines.append(String(format: "%-14s  %-14s  %-14s  %-10s", "FIELD", "BEFORE", "AFTER", "DELTA"))
        lines.append(String(repeating: "-", count: 56))
        for (field, diff) in res.diff.sorted(by: { $0.key < $1.key }) {
            let bStr = diff.before != nil ? String(format: "%.4f", diff.before!) : "null"
            let aStr = diff.after != nil ? String(format: "%.4f", diff.after!) : "null"
            let dStr = diff.delta != nil ? String(format: "%+.4f", diff.delta!) : "-"
            lines.append(String(format: "%-14s  %-14s  %-14s  %-10s", field, bStr, aStr, dStr))
        }
        return lines.joined(separator: "\n")
    }

    public static func renderPreviewResult(_ res: PreviewResult, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(res)
        }
        var lines: [String] = []
        lines.append("Preview Export Completed")
        lines.append("------------------------")
        lines.append("Operation ID: \(res.operationId)")
        lines.append("Working Ref : \(res.workingRef)")
        lines.append("Output Path : \(res.outputPath)")
        lines.append("File Size   : \(res.fileSizeBytes) bytes")
        lines.append("Dimensions  : \(res.width) x \(res.height) px")
        lines.append("Pixel SHA256: \(res.pixelSha256)")
        return lines.joined(separator: "\n")
    }
}
