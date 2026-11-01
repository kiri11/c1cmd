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
    /// Raised by a write script whose document is no longer the open one.
    static let documentChangedError = 9001

    public func document() throws -> LiveDocument {
        let result = try run("""
            tell application "Capture One"
            \twith timeout of \(timeoutSeconds) seconds
            \(Self.documentLines.joined(separator: "\n"))
            \t\treturn info
            \tend timeout
            end tell
            """)
        return try decodeDocument(result)
    }

    /// Sets `d` to the current document and `info` to its description, or returns `{{version}}` without one.
    static let documentLines = [
        "try", "set d to current document", "on error", "return {{version}}", "end try",
        "set info to {version, kind of d, name of d, folder of d, id of d}",
    ]

    func decodeDocument(_ descriptor: NSAppleEventDescriptor) throws -> LiveDocument {
        let items = list(descriptor)
        let version = items.first?.stringValue ?? list(items.first ?? descriptor).first?.stringValue ?? "unknown"
        guard items.count == 5 else { throw C1Failure(.noDocument, "Capture One \(version) has no open document.") }
        guard case .string(let kindName)? = terminology.decode(items[1], type: "documentType"),
              let kind = DocumentKind(rawValue: kindName), let name = items[2].stringValue,
              case .string(let folder)? = terminology.decode(items[3]), let id = items[4].stringValue else {
            throw C1Failure(.scriptError, "Unexpected document description from Capture One: \(descriptor).")
        }
        return LiveDocument(id: id, kind: kind, name: name, folder: folder, appVersion: version)
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

    public func read(_ targets: [ReadTarget]) throws -> ReadBatch {
        let result = try run(Self.readScript(targets, timeoutSeconds: timeoutSeconds, layerFields: terminology.propertyCodes(ofClass: Self.adjustmentsClass)))
        let parts = list(result)
        let document = try decodeDocument(parts.count == 2 ? parts[0] : result)
        var output: [VariantID: ReadResult] = [:]
        for item in list(parts[1]) {
            let fields = list(item)
            guard let id = fields.first?.stringValue.flatMap(VariantID.init) else { continue }
            output[id] = decodeRead(id, fields)
        }
        return ReadBatch(document: document, results: output)
    }

    public func write(_ writes: [VariantWrite], in document: LiveDocument) throws -> [VariantID: WriteResult] {
        guard !writes.isEmpty else { return [:] }
        let result = try run(Self.writeScript(writes, document: document, timeoutSeconds: timeoutSeconds))
        var output: [VariantID: WriteResult] = [:]
        for (write, item) in zip(writes, list(result)) {
            let fields = list(item)
            guard fields.count >= 2, fields[1].booleanValue else {
                let number = fields.count > 2 ? Int(fields[2].int32Value) : 0
                output[write.target.id] = Self.notFoundErrors.contains(number) ? .notFound
                    : .failed("Capture One error \(number): \(fields.count > 3 ? fields[3].stringValue ?? "" : "")")
                continue
            }
            guard fields.count == 5 else {
                output[write.target.id] = .failed("Unexpected write result with \(fields.count) items.")
                continue
            }
            let errors = list(fields[2]).map { error -> StepError in
                let parts = list(error)
                return StepError(step: Int(parts[0].int32Value) - 1,
                                 message: "Capture One error \(parts[1].int32Value): \(parts[2].stringValue ?? "")")
            }
            let values = zip(write.readBack, list(fields[3])).map { read, descriptor -> JSONValue? in
                read.kind == .curve ? curve(descriptor) : terminology.field(ofClass: read.owner.classCode, code: read.code, descriptor)?.1
            }
            output[write.target.id] = .done(stepErrors: errors, readBack: values, layerNames: list(fields[4]).compactMap(\.stringValue))
        }
        return output
    }

    /// Each step runs in its own `try`, so one refused value does not stop the rest; errors that end
    /// the call (timeout, permission, Capture One quitting) still propagate.
    public static func writeScript(_ writes: [VariantWrite], document: LiveDocument, timeoutSeconds: Int) -> String {
        let fatal = "{\(fatalErrors.map(String.init).joined(separator: ", "))}"
        let notFound = "{\(notFoundErrors.sorted().map(String.init).joined(separator: ", "))}"
        var lines = ["tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds",
                     "set d to current document",
                     "if (id of d as text) is not \(quote(document.id)) then error \(quote("The open document is no longer \(document.name).")) number \(documentChangedError)",
                     "set out to {}"]
        if writes.contains(where: { $0.target.route == .favoritesScan }) {
            lines.append("set favorites to every collection of d whose kind is favorite")
        }
        for write in writes {
            let id = write.target.id
            lines += ["set found to false", "set r to {\"\(id)\", false, -1728, \"not found\"}"]
            switch write.target.route {
            case .collection(let collection), .allImages(let collection):
                lines += ["try", "set v to a reference to (variant id \"\(id)\" of collection id \"\(collection)\" of d)",
                          "get id of v", "set found to true",
                          "on error e number n", "if n is in \(fatal) then error e number n", "set r to {\"\(id)\", false, n, e}", "end try"]
            case .favoritesScan:
                lines += ["repeat with c in favorites", "try", "set v to a reference to (variant id \"\(id)\" of (contents of c))",
                          "get id of v", "set found to true", "exit repeat",
                          "on error e number n", "if n is in \(fatal) then error e number n",
                          "if n is not in \(notFound) then", "set r to {\"\(id)\", false, n, e}", "exit repeat", "end if", "end try", "end repeat"]
            }
            lines += ["if found then", "try", "set errs to {}"]
            for (index, step) in write.steps.enumerated() {
                lines += ["try"] + statements(step) + ["on error e number n", "if n is in \(fatal) then error e number n",
                                                      "set end of errs to {\(index + 1), n, e}", "end try"]
            }
            lines.append("set rb to {}")
            for read in write.readBack {
                lines += ["try", "set end of rb to \(readExpression(read))",
                          "on error e number n", "if n is in \(fatal) then error e number n", "set end of rb to missing value", "end try"]
            }
            lines += ["set r to {\"\(id)\", true, errs, rb, name of every layer of v}",
                      "on error e number n", "if n is in \(fatal) then error e number n", "set r to {\"\(id)\", false, n, e}",
                      "end try", "end if", "set end of out to r"]
        }
        lines += ["return out", "end timeout", "end tell"]
        return lines.joined(separator: "\n")
    }

    static func layer(_ index: Int) -> String { "layer \(index + 1) of v" }

    static func adjustments(ofLayer index: Int) -> String {
        index == 0 ? "«property vset» of v" : "«property vset» of \(layer(index))"
    }

    static func owner(_ owner: FieldOwner) -> String {
        switch owner {
        case .variant: return "v"
        case .adjustments: return "«property vset» of v"
        case .lensCorrection: return "«property vlns» of v"
        case .layer(let index): return layer(index)
        case .layerAdjustments(let index): return adjustments(ofLayer: index)
        case .basicColor(let layer, let name): return "basic color correction \(quote(name)) of «property CCEs» of \(adjustments(ofLayer: layer))"
        case .advancedColor(let layer, let index): return "advanced color correction \(index + 1) of «property CCEs» of \(adjustments(ofLayer: layer))"
        }
    }

    /// The expression a read-back evaluates: a curve's points, or the property itself.
    static func readExpression(_ read: FieldRead) -> String {
        let property = "«property \(read.code)» of \(owner(read.owner))"
        return read.kind == .curve ? "properties of every curve point of \(property)" : property
    }

    /// Replaces a curve's points. Capture One keeps points sorted by x and refuses one within 1.5 of another,
    /// so the endpoints move out to 0 and 100 before taking their new places, and the rest are added between.
    static func curveStatements(_ write: FieldWrite) -> [String] {
        let points = (write.field.value.array ?? []).map { $0.array?.compactMap(\.number) ?? [] }
        guard let first = points.first, let last = points.last else { return [] }
        return ["tell «property \(write.field.spec.code)» of \(owner(write.owner))",
                "repeat while (count of curve points) > 2", "delete curve point 2", "end repeat",
                "set brightness of first curve point to 0", "set brightness of last curve point to 100",
                "set brightness of first curve point to \(number(first[0]))", "set brightness of last curve point to \(number(last[0]))",
                "set amount of first curve point to \(number(first[1]))", "set amount of last curve point to \(number(last[1]))"]
            + points.dropFirst().dropLast().map { "make new curve point with properties {brightness:\(number($0[0])), amount:\(number($0[1]))}" }
            + ["end tell"]
    }

    static func statements(_ step: Step) -> [String] {
        switch step {
        case .write(let write) where write.field.spec.kind == .curve:
            return curveStatements(write)
        case .write(let write):
            return ["set «property \(write.field.spec.code)» of \(owner(write.owner)) to \(literal(write.field))"]
        case .action(let action):
            switch action {
            case .createLayer(let kind, let name):
                return ["make new layer at v with properties {name:\(quote(name)), kind:\(layerKind(kind))}"]
            case .deleteLayer(let index):
                return ["delete \(layer(index))"]
            case .layerCommand(let command, let index):
                return ["\(command) \(layer(index))"]
            case .maskAmount(let command, let index, let amount):
                return ["\(command) \(layer(index)) amount \(number(amount))"]
            case .copyMask(let from, let to):
                return ["copy mask (\(layer(from))) to layer (\(layer(to)))"]
            case .peopleMask(let areas, let separate, let tags):
                return ["set before to count of layers of v",
                        "create people mask v areas {\(areas.joined(separator: ", "))} separate layers \(separate)",
                        "set tags to {\(tags.map(quote).joined(separator: ", "))}",
                        "repeat with k from before + 1 to count of layers of v",
                        "if k - before ≤ (count of tags) then set name of layer k of v to (name of layer k of v) & \" [\" & item (k - before) of tags & \"]\"",
                        "end repeat"]
            case .applyStyle(let index, let name):
                return ["apply style (\(layer(index))) named \(quote(name))"]
            case .createColor(let index):
                return ["make new advanced color correction at color editor settings of \(adjustments(ofLayer: index))"]
            case .deleteColor(let index, let color):
                return ["delete advanced color correction \(color + 1) of color editor settings of \(adjustments(ofLayer: index))"]
            case .pickDehaze(let index, let point):
                return ["pick dehaze \(adjustments(ofLayer: index)) at {\(point.map(number).joined(separator: ", "))}"]
            case .recalculateDehaze(let index):
                return ["recalculate dehaze \(adjustments(ofLayer: index))"]
            case .resetLens:
                return ["reset «property vlns» of v"]
            case .resetVariant:
                return ["reset adjustments v"]
            }
        }
    }

    static let layerKinds = ["adjustment": "CLnm", "clone": "CLcl", "heal": "CLhl", "filled": "CLfl",
                             "subject mask": "CLsm", "background mask": "CLbm"]

    static func layerKind(_ kind: String) -> String { "«constant ****\(layerKinds[kind]!)»" }

    /// AppleScript source for a validated value; never anything the schema did not accept.
    static func literal(_ field: FieldValue) -> String {
        switch (field.spec.kind, field.value) {
        case (.enumeration(let enumerators), .string(let name)):
            return "«constant ****\(enumerators[name]!)»"
        case (_, .bool(let value)):
            return value ? "true" : "false"
        case (_, .string(let text)):
            return quote(text)
        case (_, .array(let items)):
            return "{\(items.compactMap(\.number).map(number).joined(separator: ", "))}"
        case (_, let value):
            return number(value.number ?? 0)
        }
    }

    public static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.9f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let adjustmentsClass = "CVas"

    /// Capture One refuses `properties of adjustments` on a layer other than the background (-50),
    /// so those layers are read one field at a time by raw code; unsupported fields raise and are skipped.
    /// Curves and color corrections are elements, which `properties of adjustments` leaves as references,
    /// so every layer's, the background's included, are read as `properties of every …`: seven events per layer.
    public static func readScript(_ targets: [ReadTarget], timeoutSeconds: Int, layerFields: [String]) -> String {
        let fatal = "{\(fatalErrors.map(String.init).joined(separator: ", "))}"
        let notFound = "{\(notFoundErrors.sorted().map(String.init).joined(separator: ", "))}"
        func reads(_ id: VariantID) -> String {
            "{\"\(id)\", true, properties of v, properties of lens correction of v, properties of every layer of v, properties of adjustments of v, my layerFields(v), dimensions of parent image of v, maximum crop v apply false}"
        }
        let curves = WriteSchema.curveChannels.map { "properties of every curve point of \($0) curve of a" }
        var lines = ["on editor(a)", "tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds",
                     "return {\(curves.joined(separator: ", ")), properties of every basic color correction of color editor settings of a, properties of every advanced color correction of color editor settings of a}",
                     "end timeout", "end tell", "end editor"]
        lines += ["on layerFields(v)", "tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds",
                  "set kinds to kind of every layer of v", "set out to {}", "repeat with i from 1 to count of kinds",
                  "set fields to {}", "if item i of kinds is background then", "set a to a reference to adjustments of v", "else",
                  "set a to a reference to adjustments of layer i of v"]
        for code in layerFields {
            lines += ["try", "set end of fields to {\"\(code)\", «property \(code)» of a}",
                      "on error e number n", "if n is in \(fatal) then error e number n", "end try"]
        }
        lines += ["end if", "set end of out to {fields, my editor(a)}", "end repeat", "return out", "end timeout", "end tell", "end layerFields"]
        lines += ["tell application \"Capture One\"", "with timeout of \(timeoutSeconds) seconds"] + documentLines + ["set out to {}"]
        if targets.contains(where: { $0.route == .favoritesScan }) {
            lines.append("set favorites to every collection of d whose kind is favorite")
        }
        for target in targets {
            let id = target.id
            switch target.route {
            case .collection(let collection), .allImages(let collection):
                lines += [
                    "try",
                    "set v to a reference to (variant id \"\(id)\" of collection id \"\(collection)\" of d)",
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
        lines += ["return {info, out}", "end timeout", "end tell"]
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
        guard fields.count == 9 else { return .failed("Unexpected read result with \(fields.count) items.") }
        let variant = terminology.record(fields[2]).filter { !Self.isDroppedVariantField($0.key) }
        let lens = terminology.record(fields[3])
        let layerRecords = list(fields[4]).map(terminology.record)
        let layerReads = list(fields[6]).map(list)
        guard layerRecords.count == layerReads.count, layerReads.allSatisfy({ $0.count == 2 }) else {
            return .failed("Capture One returned \(layerRecords.count) layers but \(layerReads.count) layer field lists.")
        }
        var adjustments = terminology.record(fields[5])
        var layers: [[String: JSONValue]] = []
        for (layer, read) in zip(layerRecords, layerReads) {
            let editor = self.editor(read[1])
            guard layer["kind"] != .string("background") else {
                adjustments.merge(editor) { $1 }
                layers.append(layer)
                continue
            }
            var values = editor
            for pair in list(read[0]) {
                let items = list(pair)
                guard items.count == 2, let code = items[0].stringValue,
                      let (name, value) = terminology.field(ofClass: Self.adjustmentsClass, code: code, items[1]), value != .null else { continue }
                values[name] = value
            }
            layers.append(layer.merging(["adjustments": .object(values)]) { $1 })
        }
        func numbers(_ descriptor: NSAppleEventDescriptor) -> [Double]? {
            guard case .array(let items)? = terminology.decode(descriptor) else { return nil }
            let values = items.compactMap(\.number)
            return values.count == items.count ? values : nil
        }
        return .state(VariantState(id: id, variant: variant, adjustments: adjustments, lensCorrection: lens, layers: layers,
                                   canvasSize: numbers(fields[7]), maximumCrop: numbers(fields[8])))
    }

    /// `curves` and `colorEditor` from a layer's `editor(a)` result.
    func editor(_ descriptor: NSAppleEventDescriptor) -> [String: JSONValue] {
        let items = list(descriptor)
        guard items.count == WriteSchema.curveChannels.count + 2 else { return [:] }
        var curves: [String: JSONValue] = [:]
        for (channel, points) in zip(WriteSchema.curveChannels, items) { curves[channel] = curve(points) }
        let corrections = items.suffix(2).map { JSONValue.array(list($0).map { .object(terminology.record($0)) }) }
        return ["curves": .object(curves), "colorEditor": .object(["basic": corrections[0], "advanced": corrections[1]])]
    }

    /// A curve's points, from `properties of every curve point`, as [x, y] pairs ordered by x.
    func curve(_ descriptor: NSAppleEventDescriptor) -> JSONValue {
        let points = list(descriptor).map(terminology.record).compactMap { point -> [Double]? in
            guard let x = point["brightness"]?.number, let y = point["amount"]?.number else { return nil }
            return [x, y]
        }
        return .array(points.sorted { $0[0] < $1[0] }.map { .array($0.map(JSONValue.double)) })
    }

    func list(_ descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard fourCC(descriptor.descriptorType) == "list", descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    func run(_ source: String) throws -> NSAppleEventDescriptor {
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
        case documentChangedError:
            return C1Failure(.documentChanged, message, hint: "Capture One's open document changed during the call; c1 wrote nothing. Call it again.")
        default:
            return C1Failure(.scriptError, "AppleScript error \(number.map(String.init) ?? "?"): \(message)")
        }
    }

    /// `tell application` would launch Capture One, so check first.
    static func isCaptureOneRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.captureone.captureone") == true }
    }
}
