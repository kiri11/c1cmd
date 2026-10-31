import C1Kit
import Foundation

/// An in-memory Capture One: variants are reachable only through the routes that hold them.
final class FakeCaptureOne: CaptureOne {
    enum Call: Equatable { case document, read([ReadTarget]), selection }

    var liveDocument = LiveDocument(kind: .catalog, name: "fixture", folder: "/fixture.cocatalog", appVersion: "16.8.5.30")
    var variants: [Route: [VariantID: VariantState]] = [:]
    var selected: [VariantID] = []
    /// Routes that answer not-found for every variant, as when SQLite still names an old folder.
    var notFoundRoutes: Set<Route> = []
    var delay: TimeInterval = 0
    var failure: C1Failure?

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var running = 0
    private(set) var maxConcurrent = 0

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    private func enter(_ call: Call) throws {
        lock.lock()
        recorded.append(call); running += 1; maxConcurrent = max(maxConcurrent, running)
        lock.unlock()
        defer { lock.lock(); running -= 1; lock.unlock() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let failure { throw failure }
    }

    func document() throws -> LiveDocument {
        try enter(.document)
        return liveDocument
    }

    func read(_ targets: [ReadTarget]) throws -> [VariantID: ReadResult] {
        try enter(.read(targets))
        var output: [VariantID: ReadResult] = [:]
        for target in targets {
            let candidates: [Route] = target.route == .favoritesScan
                ? variants.keys.filter { if case .collection = $0 { return true }; return false }
                : [target.route]
            let state = candidates.lazy.filter { !self.notFoundRoutes.contains($0) }.compactMap { self.variants[$0]?[target.id] }.first
            output[target.id] = state.map(ReadResult.state) ?? .notFound
        }
        return output
    }

    func selection() throws -> [VariantID] {
        try enter(.selection)
        return selected
    }

    static func state(_ id: String, adjustments: [String: JSONValue] = [:]) -> VariantState {
        VariantState(id: VariantID(id)!, variant: ["id": .string(id), "rating": .int(0)],
                     adjustments: ["exposure": .double(0), "temperature": .double(5000)].merging(adjustments) { $1 },
                     lensCorrection: ["distortion": .double(0)],
                     layers: [["kind": .string("background"), "name": .string("Background"), "opacity": .int(100)]])
    }
}
