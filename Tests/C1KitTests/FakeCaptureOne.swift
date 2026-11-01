import C1Kit
import Foundation

/// An in-memory Capture One: variants are reachable only through the routes that hold them,
/// and writes change the stored state.
final class FakeCaptureOne: CaptureOne {
    enum Call: Equatable { case document, read([ReadTarget]), write([VariantWrite]), selection }

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
    /// Adjustments after `reset adjustments`.
    var resetAdjustments: [String: JSONValue] = ["exposure": .double(0)]
    private(set) var commands: [String] = []

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
            return FieldPath(write.read).set(&state, value) ? nil : "no such layer"
        case .action(let action):
            commands.append("\(action)")
            switch action {
            case .createLayer(let kind, let name):
                state.layers.append(["kind": .string(kind), "name": .string(name), "enabled": .bool(true), "opacity": .int(100),
                                     "adjustments": .object(["exposure": .double(0)])])
            case .deleteLayer(let index):
                guard index > 0, index < state.layers.count else { return "Invalid index." }
                state.layers.remove(at: index)
            case .peopleMask(_, _, let tags):
                state.layers.append(["kind": .string("adjustment"), "name": .string("People [\(tags[0])]"), "enabled": .bool(true),
                                     "opacity": .int(100), "adjustments": .object([:])])
            case .resetVariant:
                state.adjustments.merge(resetAdjustments) { $1 }
                state.layers = [state.layers[0]]
            case .layerCommand(_, let index), .maskAmount(_, let index, _), .copyMask(_, let index), .applyStyle(let index, _),
                 .createColor(let index), .deleteColor(let index, _), .pickDehaze(let index, _), .recalculateDehaze(let index):
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

    static func state(_ id: String, adjustments: [String: JSONValue] = [:]) -> VariantState {
        VariantState(id: VariantID(id)!,
                     variant: ["id": .string(id), "rating": .int(0), "color tag": .int(0), "crop": .array([.int(3000), .int(2000), .int(6000), .int(4000)])],
                     adjustments: ["exposure": .double(0), "temperature": .double(5000), "rotation": .double(0)].merging(adjustments) { $1 },
                     lensCorrection: ["distortion": .double(0)],
                     layers: [["kind": .string("background"), "name": .string("Background"), "opacity": .int(100), "enabled": .bool(true)]],
                     imageSize: [6000, 4000], maximumCrop: [3000, 2000, 6000, 4000])
    }
}

/// Where a field lives in a `VariantState`.
struct FieldPath {
    let read: FieldRead
    init(_ read: FieldRead) { self.read = read }

    func get(_ state: VariantState) -> JSONValue? {
        switch read.owner {
        case .variant: return state.variant[read.name]
        case .adjustments: return state.adjustments[read.name]
        case .lensCorrection: return state.lensCorrection[read.name]
        case .layer(let index): return index < state.layers.count ? state.layers[index][read.name] : nil
        case .layerAdjustments(let index):
            guard index < state.layers.count, case .object(let adjustments)? = state.layers[index]["adjustments"] else { return nil }
            return adjustments[read.name]
        }
    }

    func set(_ state: inout VariantState, _ value: JSONValue) -> Bool {
        switch read.owner {
        case .variant: state.variant[read.name] = value
        case .adjustments: state.adjustments[read.name] = value
        case .lensCorrection: state.lensCorrection[read.name] = value
        case .layer(let index):
            guard index < state.layers.count else { return false }
            state.layers[index][read.name] = value
        case .layerAdjustments(let index):
            guard index < state.layers.count, case .object(var adjustments)? = state.layers[index]["adjustments"] else { return false }
            adjustments[read.name] = value
            state.layers[index]["adjustments"] = .object(adjustments)
        }
        return true
    }
}
