import Foundation

/// `c1 --help` and `c1 <command> --help`, from the command table alone, so they work without Capture One.
extension Command {
    public static let usage = """
        usage: c1 <command> '<json>' [--document <path>] [--pretty]
               c1 <command> --help
               c1 --help | --version
        """

    public static var overview: String {
        let width = allCases.map(\.rawValue.count).max()!
        let commands = allCases.map { command in
            "  " + command.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + (command.readOnly ? "" : "[writes] ") + command.summary
        }
        return ([usage, ""] + wrap(general) + ["", "Commands:"] + commands + ["", "Run c1 <command> --help for its arguments."]).joined(separator: "\n")
    }

    static let general = [
        "c1 reads and edits photos in Capture One, the open Catalog or Session, through its scripting interface and database.",
        "Arguments are one JSON object; '-' reads it from stdin. Output is compact JSON with nulls left out; --pretty indents it. Exit status: 0 for a result, including an unknown outcome; 1 for a failure, whose JSON is on stdout; 2 for a usage error, on stderr.",
        "--document <path> reads a Catalog (.cocatalog) or Session folder's database instead of the open document, without Capture One: list, collections, contact_sheet and thumb take it.",
        "c1 never touches originals and never deletes variants. Before its first write to a variant it saves a snapshot that revert restores.",
    ]

    public var help: String {
        var lines = ["usage: c1 \(rawValue) '<json>'\(acceptsDocumentPath ? " [--document <path>]" : "") [--pretty]", ""]
        lines += Self.wrap([summary] + details)
        lines += ["", arguments.isEmpty ? "Arguments: none; pass {} or nothing." : "Arguments:"]
        lines += Self.argumentLines(arguments, prefix: "")
        if self == .set { lines += [""] + Self.setFieldLines() }
        if self == .action { lines += [""] + Self.actionLines() }
        lines += [""]
        lines += Self.wrap([readOnly ? "Read-only: changes no variant." : "Writes: changes variants, after saving a snapshot that revert restores."])
        lines += Self.wrap(["Failures: \(failures.map(\.rawValue).joined(separator: ", "))."])
        if !variantErrors.isEmpty { lines += Self.wrap(["Per-variant errors: \(variantErrors.joined(separator: ", "))."]) }
        lines += ["", "Example:", "  c1 \(rawValue) '\(example)'"]
        return lines.joined(separator: "\n")
    }

    static func argumentLines(_ arguments: [Argument], prefix: String) -> [String] {
        arguments.flatMap { argument -> [String] in
            var facts = [argument.type, argument.required ? "required" : "optional"]
            if let range = argument.range { facts.append(range) }
            if let values = argument.values { facts.append("one of " + values.joined(separator: ", ")) }
            var lines = ["  \(prefix)\(argument.name)  (\(facts.joined(separator: "; ")))"]
            lines += wrap([argument.description], indent: "      ")
            switch argument.kind {
            case .object(let keys): lines += argumentLines(keys, prefix: "\(prefix)\(argument.name).")
            case .list(.object(let keys), _): lines += argumentLines(keys, prefix: "\(prefix)\(argument.name)[].")
            default: break
            }
            return lines
        }
    }

    /// Every field set takes, with its type and the range measured on 16.8.5.30, from the built-in terms and Bounds.json.
    public static func setFields() -> [(path: String, type: String)] {
        guard let bounds = try? BoundsTable.bundled() else { return [] }
        let schema = WriteSchema(terminology: .snapshot, bounds: bounds)
        func describe(_ spec: FieldSpec) -> String {
            let range = spec.bound.map { " " + $0.description } ?? ""
            switch spec.kind {
            case .real: return "number" + range
            case .integer: return "integer" + range
            case .boolean: return "boolean"
            case .text: return "text"
            case .enumeration(let values): return "one of " + values.keys.sorted().joined(separator: ", ")
            case .rgb: return "[red, green, blue]" + range
            case .rectangle: return "[centre x, centre y, width, height] in crop pixels"
            case .curve: return "\(WriteSchema.curvePoints.lowerBound)–\(WriteSchema.curvePoints.upperBound) [x, y] points within 0–100, x more than \(format(WriteSchema.curveGap)) apart"
            }
        }
        func rows(_ section: Section, _ path: (String) -> String, skip: (String) -> Bool = { _ in false }) -> [(String, String)] {
            (schema.fields[section] ?? [:]).values.sorted { $0.name < $1.name }.filter { !skip($0.name) }.map { (path($0.name), describe($0)) }
        }
        let curves = Set(WriteSchema.curveChannels.map(WriteSchema.curveField))
        return rows(.variant) { "variant.\($0)" }
            + rows(.adjustments, { "adjustments.\($0)" }, skip: curves.contains)
            + rows(.adjustments, { "adjustments.curves.\(WriteSchema.curveChannel($0))" }, skip: { !curves.contains($0) })
            + rows(.basicColor) { "adjustments.colorEditor.basic[].\($0)" }
            + rows(.advancedColor) { "adjustments.colorEditor.advanced[].\($0)" }
            + rows(.lensCorrection) { "lensCorrection.\($0)" }
            + rows(.layer) { "layers[].\($0)" }
    }

    static func setFieldLines() -> [String] {
        let fields = setFields()
        let width = fields.map(\.path.count).max() ?? 0
        return wrap(["Fields, named as get reports them; ranges were measured on Capture One 16.8.5.30. A layer's adjustments take the same fields as adjustments, except geometry (orientation, flip, rotation, keystone). A basic color correction is addressed by name (red, orange, yellow, green, cyan, blue, purple, pink, all); an advanced one by index, its position in get's list."])
            + fields.map { "  " + $0.path.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.type }
    }

    static func actionLines() -> [String] {
        let width = Action.allCases.map(\.rawValue.count).max()!
        return ["Actions (arguments in brackets; a layer is an index, exact name or c1 tag):"]
            + Action.allCases.map { action in
                let arguments = action.arguments.isEmpty ? "" : " [\(action.arguments.joined(separator: ", "))]"
                return "  " + action.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + action.summary + arguments
            }
    }

    /// Paragraphs wrapped at 100 columns, separated by blank lines.
    static func wrap(_ paragraphs: [String], indent: String = "") -> [String] {
        var lines: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0, indent.isEmpty { lines.append("") }
            var line = indent
            for word in paragraph.split(separator: " ") {
                if line.count > indent.count, line.count + word.count + 1 > 100 { lines.append(line); line = indent }
                line += (line.count > indent.count ? " " : "") + word
            }
            lines.append(line)
        }
        return lines
    }
}
