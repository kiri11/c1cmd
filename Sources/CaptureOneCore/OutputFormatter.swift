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
        let versionDetail: String
        if r.exactBuildMatched {
            versionDetail = "(Tested build matched)"
        } else {
            versionDetail = "(Untested; tested: \(r.testedBuilds.joined(separator: ", ")))"
        }
        lines.append("Capture One Version : \(r.appVersion) \(versionDetail)")
        lines.append("Active Document     : \(r.hasDocument ? (r.docName ?? "Unknown") : "None (FAIL)")")
        lines.append("Document Type       : \(r.isSession ? "Session (Full Read/Write)" : (r.hasDocument ? "Catalog (\(r.writesEnabled ? "Editing Enabled" : "Read-Only Mode"))" : "None (FAIL)"))")
        if let p = r.docPath {
            lines.append("Document Path       : \(p)")
        }
        lines.append("Advisory Lock       : \(r.lockAcquired ? "Available (OK)" : "Contended / Failed (FAIL)")")
        lines.append("Unresolved Ops      : \(r.unresolvedOperationsCount == 0 ? "0 (Clean)" : "\(r.unresolvedOperationsCount) (Warning: pending/failed ops in journal)")")
        if let w = r.warning {
            lines.append("Warning             : \(w)")
        }
        lines.append("---------------------------")
        let statusStr: String
        if !r.allChecksPassed {
            statusStr = "ISSUES DETECTED"
        } else if r.warning != nil {
            statusStr = "READY (All checks passed, with warnings)"
        } else {
            statusStr = "READY (All checks passed)"
        }
        lines.append("Status              : \(statusStr)")
        return lines.joined(separator: "\n")
    }

    public static func renderDocumentInfo(_ info: DocumentInfo, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(info)
        }
        var lines: [String] = []
        lines.append("\(info.isSession ? "Session" : "Catalog") Document Information")
        lines.append("----------------------------")
        lines.append("Name          : \(info.documentName)")
        lines.append("Type          : \(info.isSession ? "Session (Read/Write)" : "Catalog (\(info.writesEnabled ? "Editing Enabled" : "Read-Only"))")")
        lines.append("Path          : \(info.documentPath)")
        if info.isSession || info.writesEnabled {
            lines.append("Capture Folder: \(info.captureFolder)")
            lines.append("Output Folder : \(info.outputFolder)")
        }
        lines.append("Open Token    : \(info.openToken)")
        return lines.joined(separator: "\n")
    }

    public static func padRight(_ str: String, _ length: Int) -> String {
        if str.count >= length {
            return String(str.prefix(length))
        }
        return str.padding(toLength: length, withPad: " ", startingAt: 0)
    }

    public static func renderVariants(_ variants: [VariantSummary], format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(variants)
        }
        if variants.isEmpty {
            return "No variants found."
        }
        var lines: [String] = []
        lines.append("\(padRight("ID", 6))  \(padRight("NAME", 24))  \(padRight("SELECTED", 8))  \(padRight("STARS", 5))  \(padRight("TAG", 6))  \(padRight("MANAGED WORKING REF", 36))")
        lines.append(String(repeating: "-", count: 90))
        for v in variants {
            let workingRefDisplay = v.workingRef ?? (v.isManagedWorkingClone ? "(managed)" : "-")
            lines.append("\(padRight(v.id, 6))  \(padRight(v.name, 24))  \(padRight(v.isSelected ? "yes" : "no", 8))  \(padRight(String(v.rating), 5))  \(padRight(String(v.colorTag), 6))  \(padRight(workingRefDisplay, 36))")
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
        lines.append("Metadata Hash: \(res.metadataStateHash ?? "unavailable")")
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
        if let g = res.geometry {
            lines.append("\nGeometry (rotated canvas, bottom-left pixels):")
            lines.append("  crop        : \(g.crop.centerX), \(g.crop.centerY), \(g.crop.width), \(g.crop.height)")
            lines.append("  rotation    : \(g.rotation) degrees")
            lines.append("  orientation : \(g.orientation) degrees")
            lines.append("  state       : \(res.geometryStateHash ?? "unavailable")")
        }
        if let reason = res.geometryUnavailableReason { lines.append("Geometry writes: \(reason)") }
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
        lines.append(contentsOf: renderDiffTable(res.diff))
        return lines.joined(separator: "\n")
    }

    public static func renderDiffResult(_ res: DiffResult, format: OutputFormat) -> String {
        if resolveFormat(format) == .json {
            return formatJson(res)
        }
        var lines: [String] = []
        lines.append("Variant Adjustments Diff: \(res.ref1) -> \(res.ref2)")
        lines.append("------------------------------------------")
        lines.append("Ref 1 (Before) State Hash: \(res.stateHash1)")
        lines.append("Ref 2 (After)  State Hash: \(res.stateHash2)")
        lines.append("")
        if res.diff.isEmpty {
            lines.append("No adjustment differences found between \(res.ref1) and \(res.ref2).")
        }
        if !res.diff.isEmpty { lines.append(contentsOf: renderDiffTable(res.diff)) }
        if let metadataDiff = res.metadataDiff, !metadataDiff.isEmpty {
            lines.append("\nRating / color tag differences:")
            lines.append(contentsOf: renderDiffTable(metadataDiff))
        }
        if let geometryDiff = res.geometryDiff, !geometryDiff.isEmpty {
            lines.append("\nCrop / rotation differences:")
            lines.append(contentsOf: renderDiffTable(geometryDiff))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderDiffTable(_ diffs: [String: DoubleDiff]) -> [String] {
        var lines: [String] = []
        lines.append("\(padRight("FIELD", 14))  \(padRight("BEFORE", 14))  \(padRight("AFTER", 14))  \(padRight("DELTA", 10))")
        lines.append(String(repeating: "-", count: 56))
        for (field, diff) in diffs.sorted(by: { $0.key < $1.key }) {
            let bStr = diff.before != nil ? String(format: "%.4f", diff.before!) : "null"
            let aStr = diff.after != nil ? String(format: "%.4f", diff.after!) : "null"
            let dStr = diff.delta != nil ? String(format: "%+.4f", diff.delta!) : "-"
            lines.append("\(padRight(field, 14))  \(padRight(bStr, 14))  \(padRight(aStr, 14))  \(padRight(dStr, 10))")
        }
        return lines
    }

    public static func renderDump(_ records: [DumpRecord], format: OutputFormat, jsonl: Bool = true) -> String {
        if jsonl {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var lines: [String] = []
            for r in records {
                if let data = try? encoder.encode(r), let str = String(data: data, encoding: .utf8) {
                    lines.append(str)
                }
            }
            return lines.joined(separator: "\n")
        }
        if resolveFormat(format) == .json {
            return formatJson(records)
        }
        if records.isEmpty {
            return "No variants dumped."
        }
        var lines: [String] = []
        lines.append("\(padRight("ID", 6))  \(padRight("NAME", 20))  \(padRight("EXP", 10))  \(padRight("CONT", 10))  \(padRight("SAT", 10))  \(padRight("TEMP", 10))  \(padRight("TINT", 10))")
        lines.append(String(repeating: "-", count: 85))
        for r in records {
            let exp = r.adjustments.exposure != nil ? String(format: "%+.2f", r.adjustments.exposure!) : "-"
            let cont = r.adjustments.contrast != nil ? String(format: "%+.1f", r.adjustments.contrast!) : "-"
            let sat = r.adjustments.saturation != nil ? String(format: "%+.1f", r.adjustments.saturation!) : "-"
            let temp = r.adjustments.temperature != nil ? String(format: "%.0fK", r.adjustments.temperature!) : "-"
            let tint = r.adjustments.tint != nil ? String(format: "%+.1f", r.adjustments.tint!) : "-"
            lines.append("\(padRight(r.id, 6))  \(padRight(r.name, 20))  \(padRight(exp, 10))  \(padRight(cont, 10))  \(padRight(sat, 10))  \(padRight(temp, 10))  \(padRight(tint, 10))")
        }
        lines.append("-------------------------------------------------------------------------------------")
        lines.append("Total variants dumped: \(records.count)")
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
        lines.append("Working Ref : \(res.workingRef ?? "(none/native)")")
        lines.append("Output Path : \(res.outputPath)")
        lines.append("File Size   : \(res.fileSizeBytes) bytes")
        lines.append("Dimensions  : \(res.width) x \(res.height) px")
        lines.append("Pixel SHA256: \(res.pixelSha256)")
        return lines.joined(separator: "\n")
    }
}
