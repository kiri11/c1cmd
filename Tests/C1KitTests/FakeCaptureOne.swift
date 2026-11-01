import C1Kit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An in-memory Capture One: variants are reachable only through the routes that hold them,
/// and writes change the stored state.
final class FakeCaptureOne: CaptureOne {
    enum Call: Equatable { case document, read([ReadTarget]), write([VariantWrite]), selection, export(ExportRequest) }

    var liveDocument = LiveDocument(id: "/fixture.cocatalog", kind: .catalog, name: "fixture", folder: "/fixture.cocatalog", appVersion: "16.8.5.30")
    var variants: [Route: [VariantID: VariantState]] = [:]
    var selected: [VariantID] = []
    /// Routes that answer not-found for every variant, as when SQLite still names an old folder.
    var notFoundRoutes: Set<Route> = []
    var delay: TimeInterval = 0
    var failure: C1Failure?
    var writeFailure: C1Failure?
    /// Stored values Capture One clamps silently, by field name.
    var clamps: [String: ClosedRange<Double>] = [:]
    /// Field names Capture One refuses to write.
    var refused: Set<String> = []
    /// Values Capture One stores in place of the one sent, by field name.
    var substitutes: [String: JSONValue] = [:]
    /// Adjustments after `reset adjustments`.
    var resetAdjustments: [String: JSONValue] = ["exposure": .double(0)]
    private(set) var commands: [String] = []
    /// Seconds before an export's file lands; nil never lands it.
    var exportDelay: TimeInterval? = 0
    /// The rectangle a full-frame export renders, by variant; otherwise the state's `maximumCrop`.
    var defaultCrops: [VariantID: [Double]] = [:]
    /// A Catalog whose output folder is unset, which Capture One refuses to export from.
    var outputFolderMissing = false

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var running = 0
    private(set) var maxConcurrent = 0

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    private func enter(_ call: Call, failure: C1Failure? = nil) throws {
        lock.lock()
        recorded.append(call); running += 1; maxConcurrent = max(maxConcurrent, running)
        lock.unlock()
        defer { lock.lock(); running -= 1; lock.unlock() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let failure = failure ?? self.failure { throw failure }
    }

    func document() throws -> LiveDocument {
        try enter(.document)
        return liveDocument
    }

    private func locate(_ target: ReadTarget) -> Route? {
        let candidates: [Route] = target.route == .favoritesScan
            ? variants.keys.filter { if case .collection = $0 { return true }; return false }.sorted { "\($0)" < "\($1)" }
            : [target.route]
        return candidates.first { !notFoundRoutes.contains($0) && variants[$0]?[target.id] != nil }
    }

    func state(_ id: VariantID) -> VariantState? {
        variants.values.lazy.compactMap { $0[id] }.first
    }

    func read(_ targets: [ReadTarget]) throws -> ReadBatch {
        try enter(.read(targets))
        var output: [VariantID: ReadResult] = [:]
        for target in targets {
            output[target.id] = locate(target).flatMap { variants[$0]?[target.id] }.map(ReadResult.state) ?? .notFound
        }
        return ReadBatch(document: liveDocument, results: output)
    }

    func write(_ writes: [VariantWrite], in document: LiveDocument) throws -> [VariantID: WriteResult] {
        try enter(.write(writes), failure: writeFailure)
        guard document == liveDocument else {
            throw C1Failure(.documentChanged, "The open document is no longer \(document.name).")
        }
        var output: [VariantID: WriteResult] = [:]
        for write in writes {
            guard let route = locate(write.target), var state = variants[route]?[write.target.id] else {
                output[write.target.id] = .notFound
                continue
            }
            var errors: [StepError] = []
            for (index, step) in write.steps.enumerated() {
                if let message = apply(step, to: &state) { errors.append(StepError(step: index, message: message)) }
            }
            variants[route]![write.target.id] = state
            output[write.target.id] = .done(stepErrors: errors, readBack: write.readBack.map { FieldPath($0).get(state) },
                                            layerNames: state.layers.map { $0["name"].flatMap { if case .string(let name) = $0 { return name }; return nil } ?? "" })
        }
        return output
    }

    /// Returns an error message when Capture One would refuse the step.
    private func apply(_ step: Step, to state: inout VariantState) -> String? {
        switch step {
        case .write(let write):
            let name = write.field.spec.name
            if refused.contains(name) { return "Capture One refused \(name)" }
            var value = write.field.value
            if let range = clamps[name], let number = value.number {
                value = .double(min(max(number, range.lowerBound), range.upperBound))
            }
            if let substitute = substitutes[name] { value = substitute }
            return FieldPath(write.read).set(&state, value) ? nil : "no such layer"
        case .action(let action):
            commands.append("\(action)")
            switch action {
            case .createLayer(let kind, let name):
                state.layers.append(["kind": .string(kind), "name": .string(name), "enabled": .bool(true), "opacity": .int(100),
                                     "adjustments": .object(Self.editor.merging(["exposure": .double(0)]) { $1 })])
            case .deleteLayer(let index):
                guard index > 0, index < state.layers.count else { return "Invalid index." }
                state.layers.remove(at: index)
            case .peopleMask(_, _, let tags):
                state.layers.append(["kind": .string("adjustment"), "name": .string("People [\(tags[0])]"), "enabled": .bool(true),
                                     "opacity": .int(100), "adjustments": .object([:])])
            case .resetVariant:
                state.adjustments.merge(resetAdjustments) { $1 }
                state.layers = [state.layers[0]]
            case .createColor(let layer):
                guard Self.modifyAdjustments(&state, layer: layer, { adjustments in
                    var advanced = adjustments["colorEditor"]?["advanced"]?.arrayValue ?? []
                    advanced.append(.object(Self.newAdvancedColor))
                    adjustments["colorEditor"] = .object(["basic": adjustments["colorEditor"]?["basic"] ?? .array([]), "advanced": .array(advanced)])
                    return true
                }) else { return "Invalid index." }
            case .deleteColor(let layer, let index):
                guard Self.modifyAdjustments(&state, layer: layer, { adjustments in
                    var advanced = adjustments["colorEditor"]?["advanced"]?.arrayValue ?? []
                    guard index < advanced.count else { return false }
                    advanced.remove(at: index)
                    adjustments["colorEditor"] = .object(["basic": adjustments["colorEditor"]?["basic"] ?? .array([]), "advanced": .array(advanced)])
                    return true
                }) else { return "Invalid index." }
            case .layerCommand(_, let index), .maskAmount(_, let index, _), .copyMask(_, let index), .applyStyle(let index, _),
                 .pickDehaze(let index, _), .recalculateDehaze(let index):
                guard index < state.layers.count else { return "Invalid index." }
            case .resetLens:
                state.lensCorrection["distortion"] = .double(0)
            }
            return nil
        }
    }

    func selection() throws -> [VariantID] {
        try enter(.selection)
        return selected
    }

    /// Renders a gradient whose colour encodes canvas position (red rises with x, green with y), so a test
    /// can tell which canvas point any output pixel shows.
    func export(_ request: ExportRequest, in document: LiveDocument) throws -> Bool {
        try enter(.export(request))
        guard document == liveDocument else { throw C1Failure(.documentChanged, "The open document is no longer \(document.name).") }
        guard let state = locate(request.target).flatMap({ variants[$0]?[request.target.id] }) else {
            throw C1Failure(.notFound, "Capture One has no variant \(request.target.id) in this document.")
        }
        let outputSet = outputFolderMissing && document.kind == .catalog
        outputFolderMissing = false
        guard let delay = exportDelay else { return outputSet }
        let area = request.fullFrame ? defaultCrops[state.id] ?? state.maximumCrop! : state.variant["crop"]!.arrayValue!.map { $0.number! }
        let image = Self.gradient(area: area, canvas: state.canvasSize!, longEdge: request.longEdge)
        let write = { Self.writeJPEG(image, to: request.file) }
        if delay == 0 { write() } else { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: write) }
        return outputSet
    }

    static func gradient(area: [Double], canvas: [Double], longEdge: Int) -> CGImage {
        let scale = Double(longEdge) / max(area[2], area[3])
        let width = max(1, Int((area[2] * scale).rounded())), height = max(1, Int((area[3] * scale).rounded()))
        let left = area[0] - area[2] / 2, top = area[1] + area[3] / 2
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for j in 0..<height {
                let y = top - (Double(j) + 0.5) / scale
                let green = UInt8(max(0, min(255, y / canvas[1] * 255)))
                for i in 0..<width {
                    let x = left + (Double(i) + 0.5) / scale
                    let index = (j * width + i) * 4
                    buffer[index] = UInt8(max(0, min(255, x / canvas[0] * 255)))
                    buffer[index + 1] = green
                    buffer[index + 2] = 100
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func writeJPEG(_ image: CGImage, to url: URL, properties: [CFString: Any] = [:]) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties.merging([kCGImageDestinationLossyCompressionQuality: 0.95]) { $1 } as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "cannot write \(url.path)")
    }

    /// Applies `body` to a layer's adjustments, 0 being the background's.
    static func modifyAdjustments(_ state: inout VariantState, layer: Int, _ body: (inout [String: JSONValue]) -> Bool) -> Bool {
        if layer == 0 { return body(&state.adjustments) }
        guard layer < state.layers.count, case .object(var adjustments)? = state.layers[layer]["adjustments"] else { return false }
        guard body(&adjustments) else { return false }
        state.layers[layer]["adjustments"] = .object(adjustments)
        return true
    }

    /// What `make new advanced color correction` creates on 16.8.5.30.
    static let newAdvancedColor: [String: JSONValue] = [
        "enabled": .bool(true), "red": .int(0), "green": .int(0), "blue": .int(0), "hue start": .double(0), "hue end": .double(0),
        "saturation start": .double(0), "saturation end": .double(0), "smoothness": .double(20),
        "hue change": .double(0), "saturation change": .double(0), "lightness change": .double(0),
    ]

    static let identity: JSONValue = .array([.array([.double(0), .double(0)]), .array([.double(100), .double(100)])])

    /// A layer's curves and color editor as Capture One reports them untouched.
    static var editor: [String: JSONValue] {
        ["curves": .object(Dictionary(uniqueKeysWithValues: ["rgb", "luma", "red", "green", "blue"].map { ($0, identity) })),
         "colorEditor": .object([
            "basic": .array(["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink", "all"].map {
                .object(["name": .string($0), "hue change": .double(0), "saturation change": .double(0), "lightness change": .double(0)])
            }),
            "advanced": .array([]),
         ])]
    }

    static func state(_ id: String, adjustments: [String: JSONValue] = [:]) -> VariantState {
        VariantState(id: VariantID(id)!,
                     variant: ["id": .string(id), "rating": .int(0), "color tag": .int(0), "crop": .array([.int(3000), .int(2000), .int(6000), .int(4000)])],
                     adjustments: ["exposure": .double(0), "temperature": .double(5000), "rotation": .double(0)].merging(adjustments) { $1 },
                     lensCorrection: ["distortion": .double(0)],
                     layers: [["kind": .string("background"), "name": .string("Background"), "opacity": .int(100), "enabled": .bool(true)]],
                     canvasSize: [6000, 4000], maximumCrop: [3000, 2000, 6000, 4000])
    }
}

/// Where a field lives in a `VariantState`.
struct FieldPath {
    let read: FieldRead
    init(_ read: FieldRead) { self.read = read }

    var channel: String { String(read.name.dropLast(" curve".count)) }

    func get(_ state: VariantState) -> JSONValue? {
        switch read.owner {
        case .variant: return state.variant[read.name]
        case .lensCorrection: return state.lensCorrection[read.name]
        case .layer(let index): return index < state.layers.count ? state.layers[index][read.name] : nil
        case .adjustments: return field(state.adjustments)
        case .layerAdjustments(let index), .basicColor(let index, _), .advancedColor(let index, _):
            if index == 0 { return field(state.adjustments) }
            guard index < state.layers.count, case .object(let adjustments)? = state.layers[index]["adjustments"] else { return nil }
            return field(adjustments)
        }
    }

    private func field(_ adjustments: [String: JSONValue]) -> JSONValue? {
        switch read.owner {
        case .basicColor(_, let name):
            return adjustments["colorEditor"]?["basic"]?.arrayValue?.first { $0["name"] == .string(name) }?[read.name]
        case .advancedColor(_, let index):
            let corrections = adjustments["colorEditor"]?["advanced"]?.arrayValue ?? []
            return index < corrections.count ? corrections[index][read.name] : nil
        default:
            return read.kind == .curve ? adjustments["curves"]?[channel] : adjustments[read.name]
        }
    }

    func set(_ state: inout VariantState, _ value: JSONValue) -> Bool {
        switch read.owner {
        case .variant: state.variant[read.name] = value
        case .lensCorrection: state.lensCorrection[read.name] = value
        case .layer(let index):
            guard index < state.layers.count else { return false }
            state.layers[index][read.name] = value
        case .adjustments:
            return set(&state.adjustments, value)
        case .layerAdjustments(let index), .basicColor(let index, _), .advancedColor(let index, _):
            return FakeCaptureOne.modifyAdjustments(&state, layer: index) { set(&$0, value) }
        }
        return true
    }

    private func set(_ adjustments: inout [String: JSONValue], _ value: JSONValue) -> Bool {
        switch read.owner {
        case .basicColor(_, let name):
            var basic = adjustments["colorEditor"]?["basic"]?.arrayValue ?? []
            guard let index = basic.firstIndex(where: { $0["name"] == .string(name) }), case .object(var correction) = basic[index] else { return false }
            correction[read.name] = value
            basic[index] = .object(correction)
            adjustments["colorEditor"] = .object(["basic": .array(basic), "advanced": adjustments["colorEditor"]?["advanced"] ?? .array([])])
        case .advancedColor(_, let index):
            var advanced = adjustments["colorEditor"]?["advanced"]?.arrayValue ?? []
            guard index < advanced.count, case .object(var correction) = advanced[index] else { return false }
            correction[read.name] = value
            advanced[index] = .object(correction)
            adjustments["colorEditor"] = .object(["basic": adjustments["colorEditor"]?["basic"] ?? .array([]), "advanced": .array(advanced)])
        default:
            if read.kind == .curve {
                guard case .object(var curves)? = adjustments["curves"] else { return false }
                curves[channel] = value
                adjustments["curves"] = .object(curves)
            } else {
                adjustments[read.name] = value
            }
        }
        return true
    }
}
