import AppKit
import Foundation

/// Talks to Capture One by running one generated AppleScript per call in-process.
public final class AppleScriptCaptureOne: CaptureOne {
    let terminology: Terminology
    let timeoutSeconds: Int
    /// Optional per-call log line with compile and run times.
    public var trace: ((String) -> Void)?

    public init(terminology: Terminology, timeoutSeconds: Int = 120) {
        self.terminology = terminology; self.timeoutSeconds = timeoutSeconds
    }

    /// Errors that end the whole call; a per-variant `try` must not swallow them.
    static let fatalErrors = [-1712, -1743, -1744, -600, -609, -128]
    static let notFoundErrors: Set = [-1728, -1719]

    public func document() throws -> LiveDocument {
        let result = try run("""
            tell application "Capture One"
            \twith timeout of \(timeoutSeconds) seconds
            \t\ttry
            \t\t\tset d to current document
            \t\ton error
            \t\t\treturn {version}
            \t\tend try
            \t\treturn {version, kind of d, name of d, folder of d}
            \tend timeout
            end tell
            """)
        let items = list(result)
        let version = items.first?.stringValue ?? "unknown"
        guard items.count == 4 else { throw C1Failure(.noDocument, "Capture One \(version) has no open document.") }
        guard case .string(let kindName)? = terminology.decode(items[1], type: "documentType"),
              let kind = DocumentKind(rawValue: kindName), let name = items[2].stringValue,
              case .string(let folder)? = terminology.decode(items[3]) else {
            throw C1Failure(.scriptError, "Unexpected document description from Capture One: \(result).")
        }
        return LiveDocument(kind: kind, name: name, folder: folder, appVersion: version)
    }

    public func selection() throws -> [VariantID] {
        let result = try run("""
            tell application "Capture One"
            \twith timeout of \(timeoutSeconds) seconds
            \t\treturn id of every variant of current document whose selected is true
            \tend timeout
            end tell
            """)
        return try list(result).map { item in
            guard let id = item.stringValue.flatMap(VariantID.init) else {
                throw C1Failure(.scriptError, "Capture One returned a selected variant without an id: \(item).")
            }
            return id
        }
    }

    public func read(_ targets: [ReadTarget]) throws -> [VariantID: ReadResult] {
        guard !targets.isEmpty else { return [:] }
        let result = try run(Self.readScript(targets, timeoutSeconds: timeoutSeconds, layerFields: terminology.propertyCodes(ofClass: Self.adjustmentsClass)))
        var output: [VariantID: ReadResult] = [:]
        for item in list(result) {
            let fields = list(item)
            guard let id = fields.first?.stringValue.flatMap(VariantID.init) else { continue }
            output[id] = decodeRead(id, fields)
        }
        return output
    }

    static let adjustmentsClass = "CVas"

    /// Capture One refuses `properties of adjustments` on a layer other than the background (-50),
    /// so those layers are read one field at a time by raw code; unsupported fields raise and are skipped.
    public static func readScript(_ targets: [ReadTarget], timeoutSeconds: Int, layerFields: [String]) -> String {
        let fatal = "{\(fatalErrors.map(String.init).joined(separator: ", "))}"
        let notFound = "{\(notFoundErrors.sorted().map(String.init).joined(separator: ", "))}"
        func reads(_ id: VariantID) -> String {
            "{\"\(id)\", true, properties of v, properties of lens correction of v, properties of every layer of v, properties of adjustments of v, my layerFields(v)}"
        }
        var lines = ["on layerFields(v)", "tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds",
                     "set kinds to kind of every layer of v", "set out to {}", "repeat with i from 1 to count of kinds",
                     "set fields to {}", "if item i of kinds is not background then", "set a to a reference to adjustments of layer i of v"]
        for code in layerFields {
            lines += ["try", "set end of fields to {\"\(code)\", «property \(code)» of a}",
                      "on error e number n", "if n is in \(fatal) then error e number n", "end try"]
        }
        lines += ["end if", "set end of out to fields", "end repeat", "return out", "end timeout", "end tell", "end layerFields"]
        lines += ["tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds", "set out to {}"]
        if targets.contains(where: { $0.route == .favoritesScan }) {
            lines.append("set favorites to every collection of current document whose kind is favorite")
        }
        for target in targets {
            let id = target.id
            switch target.route {
            case .collection(let collection), .allImages(let collection):
                lines += [
                    "try",
                    "set v to a reference to (variant id \"\(id)\" of collection id \"\(collection)\" of current document)",
                    "set end of out to \(reads(id))",
                    "on error e number n",
                    "if n is in \(fatal) then error e number n",
                    "set end of out to {\"\(id)\", false, n, e}",
                    "end try",
                ]
            case .favoritesScan:
                lines += [
                    "set r to {\"\(id)\", false, -1728, \"not in any favorite\"}",
                    "repeat with c in favorites",
                    "try",
                    "set v to a reference to (variant id \"\(id)\" of (contents of c))",
                    "set r to \(reads(id))",
                    "exit repeat",
                    "on error e number n",
                    "if n is in \(fatal) then error e number n",
                    "if n is not in \(notFound) then",
                    "set r to {\"\(id)\", false, n, e}",
                    "exit repeat",
                    "end if",
                    "end try",
                    "end repeat",
                    "set end of out to r",
                ]
            }
        }
        lines += ["return out", "end timeout", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// IPTC, contact, status and Getty fields are metadata, not editing state; `selected` and
    /// `visible` describe the current collection's browser, not the variant.
    static func isDroppedVariantField(_ name: String) -> Bool {
        name == "selected" || name == "visible" || ["contact ", "content ", "status ", "Getty ", "image "].contains { name.hasPrefix($0) }
    }

    func decodeRead(_ id: VariantID, _ fields: [NSAppleEventDescriptor]) -> ReadResult {
        guard fields.count >= 2, fields[1].booleanValue else {
            let number = fields.count > 2 ? Int(fields[2].int32Value) : 0
            if Self.notFoundErrors.contains(number) { return .notFound }
            let message = fields.count > 3 ? fields[3].stringValue ?? "" : ""
            return .failed("Capture One error \(number): \(message)")
        }
        guard fields.count == 7 else { return .failed("Unexpected read result with \(fields.count) items.") }
        let variant = terminology.record(fields[2]).filter { !Self.isDroppedVariantField($0.key) }
        let lens = terminology.record(fields[3])
        let layerRecords = list(fields[4]).map(terminology.record)
        let adjustments = terminology.record(fields[5])
        let layerFields = list(fields[6])
        guard layerRecords.count == layerFields.count else {
            return .failed("Capture One returned \(layerRecords.count) layers but \(layerFields.count) layer field lists.")
        }
        let layers = zip(layerRecords, layerFields).map { layer, pairs -> [String: JSONValue] in
            guard layer["kind"] != .string("background") else { return layer }
            var values: [String: JSONValue] = [:]
            for pair in list(pairs) {
                let items = list(pair)
                guard items.count == 2, let code = items[0].stringValue,
                      let (name, value) = terminology.field(ofClass: Self.adjustmentsClass, code: code, items[1]), value != .null else { continue }
                values[name] = value
            }
            return layer.merging(["adjustments": .object(values)]) { $1 }
        }
        return .state(VariantState(id: id, variant: variant, adjustments: adjustments, lensCorrection: lens, layers: layers))
    }

    private func list(_ descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard fourCC(descriptor.descriptorType) == "list", descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard Self.isCaptureOneRunning() else {
            throw C1Failure(.notRunning, "Capture One is not running.", hint: "Open Capture One and its document, then try again.")
        }
        guard let script = NSAppleScript(source: source) else {
            throw C1Failure(.scriptError, "Cannot create the AppleScript.")
        }
        var error: NSDictionary?
        let start = Date()
        script.compileAndReturnError(&error)
        let compiled = Date()
        let result = error == nil ? script.executeAndReturnError(&error) : NSAppleEventDescriptor.null()
        trace?(String(format: "AppleScript of %d chars: compile %.3f s, run %.3f s", source.count,
                      compiled.timeIntervalSince(start), Date().timeIntervalSince(compiled)))
        if let error {
            throw Self.failure(message: error[NSAppleScript.errorMessage] as? String ?? "unknown error",
                               number: error[NSAppleScript.errorNumber] as? Int)
        }
        return result
    }

    public static func failure(message: String, number: Int?) -> C1Failure {
        switch number {
        case -1712:
            return C1Failure(.timeout, "Capture One did not answer in time (-1712): \(message)", hint: C1Failure.timeoutHint, outcomeUnknown: true)
        case -1743, -1744:
            return C1Failure(.permissionDenied, "macOS denied Automation access to Capture One (\(number!)): \(message)",
                             hint: "Allow it under System Settings > Privacy & Security > Automation.")
        case -600, -609:
            return C1Failure(.notRunning, "Capture One is not running (\(number!)): \(message)")
        default:
            return C1Failure(.scriptError, "AppleScript error \(number.map(String.init) ?? "?"): \(message)")
        }
    }

    /// `tell application` would launch Capture One, so check first.
    static func isCaptureOneRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.captureone.captureone") == true }
    }
}
