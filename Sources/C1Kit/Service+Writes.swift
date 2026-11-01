import Foundation

public enum RevertScope: String, CaseIterable, Decodable {
    case all, adjustments, geometry, metadata, layers

    func covers(_ scope: RevertScope) -> Bool { self == .all || self == scope }

    /// Which scope restores a background, variant or lens field.
    static func of(_ owner: FieldOwner, _ name: String) -> RevertScope {
        switch owner {
        case .variant: return name == "crop" ? .geometry : .metadata
        case .adjustments: return WriteSchema.geometryFields.contains(name) ? .geometry : .adjustments
        case .lensCorrection: return .adjustments
        case .layer, .layerAdjustments: return .layers
        case .basicColor(let layer, _), .advancedColor(let layer, _): return layer == 0 ? .adjustments : .layers
        }
    }
}

/// One variant's writes, with the values each read-back should show.
struct Plan {
    var steps: [Step] = []
    var readBack: [FieldRead] = []
    var sent: [FieldRead: JSONValue] = [:]
    var extra: [String: JSONValue] = [:]

    init(writes: [FieldWrite] = [], actions: [ActionStep] = [], extra: [String: JSONValue] = [:]) {
        steps = actions.map(Step.action) + writes.map(Step.write)
        readBack = writes.map(\.read)
        sent = Dictionary(writes.map { ($0.read, $0.field.value) }) { _, last in last }
        self.extra = extra
    }
}

extension Service {
    // MARK: doctor

    public func doctor() throws -> JSONValue {
        let c1: JSONValue = .object(["version": .string(C1Version.current)])
        let document: LiveDocument
        do {
            document = try queue.run { try captureOne.document() }
        } catch let failure as C1Failure where failure.code == .noDocument {
            return .object(["c1": c1, "document": .null,
                            "warnings": .array([.string(failure.message + " Open the Catalog or Session to edit.")] + termWarnings().map(JSONValue.string))])
        }
        memory.save(document)
        let database = try openDatabase(document.databasePath)
        let store = DocumentStore(home: home, documentUUID: database.documentUUID)
        return .object([
            "c1": c1,
            "captureOne": .object(["version": .string(document.appVersion), "tested": .bool(Self.testedBuilds.contains(document.appVersion))]),
            "document": .object([
                "kind": .string(document.kind.rawValue), "name": .string(document.name), "path": .string(document.folder),
                "uuid": .string(database.documentUUID),
                "lastBackup": database.lastBackup.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            ]),
            "storage": .string(store.directory.path),
            "warnings": .array((Self.warnings(document, database, now()) + termWarnings()).map(JSONValue.string)),
        ])
    }

    /// Warns when the scripting terms c1 uses differ between Capture One's sdef and the snapshot c1 was built with.
    func termWarnings() -> [String] {
        let differences: [String]
        do { differences = try liveTerms().differences(from: .snapshot) } catch {
            return ["c1 cannot read Capture One's sdef, so it cannot check its built-in scripting terms against it: \(error)"]
        }
        guard !differences.isEmpty else { return [] }
        let shown = differences.prefix(10).joined(separator: "; ")
        return ["Capture One's scripting terms differ from the 16.8.5.30 terms c1 is built with (\(differences.count) difference\(differences.count == 1 ? "" : "s")): \(shown)\(differences.count > 10 ? "; …" : ""). Reads and writes of those terms may fail or be misnamed."]
    }

    /// Warnings that never block: an untested build, and a Catalog backup missing or older than a day.
    static func warnings(_ document: LiveDocument, _ database: Database, _ now: Date) -> [String] {
        var warnings: [String] = []
        if !testedBuilds.contains(document.appVersion) {
            warnings.append("Capture One \(document.appVersion) is untested; c1 is tested on \(testedBuilds.joined(separator: ", ")). Check each result closely.")
        }
        if document.kind == .catalog {
            if let last = database.lastBackup {
                let age = now.timeIntervalSince(last)
                if age > backupAge {
                    warnings.append("The Catalog was last backed up \(Int(age / 86400)) days ago. Make File > Backup Catalog before editing.")
                }
            } else {
                warnings.append("The Catalog has never been backed up. Make File > Backup Catalog before editing.")
            }
        }
        return warnings
    }

    // MARK: set

    public func set(_ arguments: SetArguments) throws -> JSONValue {
        let ids = try Self.unique(arguments.ids, command: "set")
        let patch = try Patch(arguments, schema: try schema())
        return try perform("set", arguments: try JSONValue.from(SetLog(arguments)), ids: ids, snapshot: true) { state, _ in
            if let crop = patch.crop {
                guard let bounds = state.cropBounds else { return .failure("Capture One reported no image size, so c1 cannot check the crop.") }
                let crossings = bounds.crossings(crop)
                if !crossings.isEmpty {
                    let detail = crossings.map { "the \($0.corner) corner by \(Int($0.distance.rounded(.up))) px" }.joined(separator: ", ")
                    return .failure("The crop lies outside cropBounds (\(bounds.source.rawValue)): \(detail). Read cropBounds with get and choose a crop inside it.")
                }
            }
            return patch.writes(for: state).map { Plan(writes: $0) }
        }
    }

    // MARK: action

    public func action(_ name: String, ids requested: [VariantID], arguments: [String: JSONValue]) throws -> JSONValue {
        guard let action = Action(rawValue: name) else {
            throw C1Failure(.invalidArguments, "No action \"\(name)\"; actions: \(Action.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let ids = try Self.unique(requested, command: "action")
        let request = try action.request(arguments)
        // One tag per call, so the agent can name the new layer the same way on every variant.
        let tags = (0..<Action.peopleAreas.count).map { _ in LayerTag.make() }
        var logged = arguments
        logged["action"] = .string(name)
        return try perform("action", arguments: .object(logged), ids: ids, snapshot: true) { state, _ in
            request.step(for: state, tags: tags).map { step in
                var extra: [String: JSONValue] = [:]
                if action == .layerCreate { extra["layer"] = .string(tags[0]) }
                return Plan(actions: [step], extra: extra)
            }
        }
    }

    // MARK: revert

    public func revert(ids requested: [VariantID], scope: RevertScope) throws -> JSONValue {
        let ids = try Self.unique(requested, command: "revert")
        let schema = try schema()
        return try perform("revert", arguments: .object(["ids": .array(ids.map { .string($0.description) }), "scope": .string(scope.rawValue)]),
                           ids: ids, snapshot: false) { current, store in
            guard let snapshot = try store.snapshot(current.id) else {
                return .failure("c1 holds no snapshot of this variant: it has not written to it since its last full revert.")
            }
            guard let saved = VariantState(json: snapshot.state) else {
                return .failure("The snapshot of this variant is malformed; c1 keeps it as it is.")
            }
            return .success(Self.revertPlan(from: saved, to: current, scope: scope, schema: schema))
        } finish: { id, ok, store in
            if ok, scope == .all { try store.deleteSnapshot(id) }
        }
    }

    /// Deletes c1's layers created since the snapshot, then restores every differing field in scope.
    static func revertPlan(from saved: VariantState, to current: VariantState, scope: RevertScope, schema: WriteSchema) -> Plan {
        func name(_ layer: [String: JSONValue]) -> String { layer["name"]?.string ?? "" }
        func differs(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
            guard let a, a != .null else { return false }
            return !(b.map { a.approximatelyEquals($0) } ?? false)
        }
        var notRestored: [String] = []
        var deletions: [Int] = []
        var colorActions: [ActionStep] = []
        if scope.covers(.layers) {
            let savedTags = Set(saved.layers.compactMap { LayerTag.of(name($0)) })
            deletions = current.layers.indices.dropFirst().filter { LayerTag.of(name(current.layers[$0])).map { !savedTags.contains($0) } ?? false }
        }
        let remaining = current.layers.indices.filter { !deletions.contains($0) }
        var writes: [FieldWrite] = []
        let sections: [(Section, FieldOwner, [String: JSONValue], [String: JSONValue])] = [
            (.variant, .variant, saved.variant, current.variant),
            (.adjustments, .adjustments, saved.adjustments, current.adjustments),
            (.lensCorrection, .lensCorrection, saved.lensCorrection, current.lensCorrection),
        ]
        func restoreEditor(layer: Int, _ before: [String: JSONValue], _ now: [String: JSONValue]) {
            let restored = editorPlan(layer: layer, from: before, to: now, schema: schema)
            writes += restored.writes; colorActions += restored.actions; notRestored += restored.notRestored
        }
        if scope.covers(.adjustments) { restoreEditor(layer: 0, saved.adjustments, current.adjustments) }
        for (section, owner, before, now) in sections {
            for (name, value) in before.sorted(by: { $0.key < $1.key }) where !Self.editorKeys.contains(name) && differs(value, now[name]) {
                if let spec = schema.fields[section]?[name] {
                    if scope.covers(RevertScope.of(owner, name)) { writes.append(FieldWrite(owner, FieldValue(spec, value))) }
                } else if scope == .all, schema.sdefWritable[section]?.contains(name) == true,
                          !name.hasPrefix("crop "), name != "current layer" {
                    notRestored.append("\(section.rawValue).\(name)")
                }
            }
        }
        if scope.covers(.layers) {
            var used = Set<Int>()
            for layer in saved.layers.dropFirst() {
                guard let index = remaining.dropFirst().first(where: { !used.contains($0) && name(current.layers[$0]) == name(layer) }) else {
                    notRestored.append("layer \"\(name(layer))\", which no longer exists")
                    continue
                }
                used.insert(index)
                let shifted = index - deletions.filter { $0 < index }.count
                let now = current.layers[index]
                for (field, value) in layer.sorted(by: { $0.key < $1.key }) where differs(value, now[field]) {
                    if let spec = schema.fields[.layer]?[field] {
                        writes.append(FieldWrite(.layer(shifted), FieldValue(spec, value)))
                    } else if field != "adjustments", field != "name", schema.sdefWritable[.layer]?.contains(field) == true {
                        notRestored.append("layers.\(shifted).\(field)")
                    }
                }
                let savedAdjustments: [String: JSONValue] = layer["adjustments"]?.object ?? [:]
                let nowAdjustments: [String: JSONValue] = now["adjustments"]?.object ?? [:]
                for (field, value) in savedAdjustments.sorted(by: { $0.key < $1.key }) where !Self.editorKeys.contains(field) && differs(value, nowAdjustments[field]) {
                    if let spec = schema.fields[.adjustments]?[field], !WriteSchema.geometryFields.contains(field) {
                        writes.append(FieldWrite(.layerAdjustments(shifted), FieldValue(spec, value)))
                    }
                }
                restoreEditor(layer: shifted, savedAdjustments, nowAdjustments)
            }
        }
        var plan = Plan(writes: Patch.ordered(writes), actions: deletions.sorted(by: >).map(ActionStep.deleteLayer) + colorActions)
        if !notRestored.isEmpty { plan.extra["notRestored"] = .array(notRestored.map(JSONValue.string)) }
        return plan
    }

    static let editorKeys: Set<String> = ["curves", "colorEditor"]

    /// Restores one layer's curves and color corrections: curves whole and basic corrections by name, where
    /// they differ. Advanced corrections first match the snapshot's count, deleting from the end or creating
    /// new ones; then every field of each new or differing correction is written, because setting a color
    /// moves the ranges around it. A snapshot without these keys predates them and restores nothing here.
    static func editorPlan(layer: Int, from saved: [String: JSONValue], to current: [String: JSONValue],
                           schema: WriteSchema) -> (writes: [FieldWrite], actions: [ActionStep], notRestored: [String]) {
        let place = layer == 0 ? "adjustments" : "layers.\(layer).adjustments"
        let owner: FieldOwner = layer == 0 ? .adjustments : .layerAdjustments(layer)
        var writes: [FieldWrite] = [], actions: [ActionStep] = [], notRestored: [String] = []
        for (channel, points) in (saved["curves"]?.object ?? [:]).sorted(by: { $0.key < $1.key })
        where current["curves"]?[channel].map({ !points.approximatelyEquals($0) }) ?? true {
            guard let spec = schema.fields[.adjustments]?[WriteSchema.curveField(channel)],
                  let value = try? schema.validate(.adjustments, spec.name, points) else {
                notRestored.append("\(place).curves.\(channel)")
                continue
            }
            writes.append(FieldWrite(owner, value))
        }
        let savedBasic = saved["colorEditor"]?["basic"]?.array ?? []
        let currentBasic = current["colorEditor"]?["basic"]?.array ?? []
        for correction in savedBasic {
            guard let name = correction["name"]?.string else { continue }
            guard let now = currentBasic.first(where: { $0["name"]?.string == name }) else {
                notRestored.append("\(place).colorEditor.basic.\(name)")
                continue
            }
            for (field, value) in (correction.object ?? [:]).sorted(by: { $0.key < $1.key }) where field != "name" && !(now[field].map { value.approximatelyEquals($0) } ?? false) {
                guard let spec = schema.fields[.basicColor]?[field] else { notRestored.append("\(place).colorEditor.basic.\(name).\(field)"); continue }
                writes.append(FieldWrite(.basicColor(layer: layer, name: name), FieldValue(spec, value)))
            }
        }
        guard case .array(let savedAdvanced)? = saved["colorEditor"]?["advanced"] else { return (writes, actions, notRestored) }
        let currentAdvanced = current["colorEditor"]?["advanced"]?.array ?? []
        if currentAdvanced.count > savedAdvanced.count {
            actions += (savedAdvanced.count..<currentAdvanced.count).reversed().map { ActionStep.deleteColor(layer: layer, index: $0) }
        } else {
            actions += Array(repeating: ActionStep.createColor(layer: layer), count: savedAdvanced.count - currentAdvanced.count)
        }
        for (index, correction) in savedAdvanced.enumerated()
        where index >= currentAdvanced.count || !correction.approximatelyEquals(currentAdvanced[index]) {
            let fields = correction.object ?? [:]
            for field in WriteSchema.advancedColorOrder {
                guard let value = fields[field] else { continue }
                guard let spec = schema.fields[.advancedColor]?[field] else { notRestored.append("\(place).colorEditor.advanced.\(index).\(field)"); continue }
                writes.append(FieldWrite(.advancedColor(layer: layer, index: index), FieldValue(spec, value)))
            }
        }
        return (writes, actions, notRestored)
    }

    // MARK: the write pipeline

    /// Reads each variant, plans its steps, saves snapshots before the first write, runs every variant
    /// in one script, then compares read-backs and logs the call. A refused variant does not stop the others.
    func perform(_ command: String, arguments: JSONValue, ids: [VariantID], snapshot: Bool,
                 plan: (VariantState, DocumentStore) throws -> Result<Plan, Refusal>,
                 finish: ((VariantID, Bool, DocumentStore) throws -> Void)? = nil) throws -> JSONValue {
        try queue.run {
            let read = try liveRead(ids)
            let uuid = read.database.documentUUID
            let store = DocumentStore(home: home, documentUUID: uuid)
            let warnings = Self.warnings(read.document, read.database, now())
            var results: [VariantID: JSONValue] = [:]
            var planned: [VariantID: (state: VariantState, plan: Plan)] = [:]
            for id in ids {
                switch read.results[id] ?? .failed("Capture One returned no result for this id.") {
                case .state(let state):
                    switch try plan(state, store) {
                    case .failure(let refusal):
                        results[id] = Self.variantError(id, "refused", refusal.message)
                    case .success(let plan) where plan.steps.isEmpty:
                        try finish?(id, true, store)
                        results[id] = .object(["id": .string(id.description), "outcome": .string("ok"), "before": .object([:]), "after": .object([:])]
                                              .merging(plan.extra) { $1 })
                    case .success(let plan):
                        planned[id] = (state, plan)
                    }
                case .notFound:
                    results[id] = Self.variantError(id, "not-found", "Capture One has no variant \(id) in this document.")
                case .failed(let reason):
                    results[id] = Self.variantError(id, "read-failed", reason)
                }
            }
            let order = ids.filter { planned[$0] != nil }
            if snapshot {
                for id in order where try store.snapshot(id) == nil {
                    try store.save(Snapshot(taken: now(), document: uuid, state: planned[id]!.state), for: id)
                }
            }
            var line: [String: JSONValue] = [
                "time": .string(ISO8601DateFormatter().string(from: now())), "document": .string(uuid),
                "command": .string(command), "arguments": arguments,
            ]
            func before(_ id: VariantID) -> JSONValue {
                let (state, plan) = planned[id]!
                return nest(plan.readBack.map { ($0, state.value($0)) })
            }
            if !order.isEmpty {
                let writes = order.map { VariantWrite(target: ReadTarget($0, read.routes[$0]!), steps: planned[$0]!.plan.steps, readBack: planned[$0]!.plan.readBack) }
                let outcomes: [VariantID: WriteResult]
                do {
                    outcomes = try captureOne.write(writes, in: read.document)
                } catch var failure as C1Failure {
                    // Only a changed document or a refused permission stops the script before its first write.
                    let definite = failure.code == .documentChanged || failure.code == .permissionDenied
                    failure.outcomeUnknown = !definite
                    line["outcome"] = .string(definite ? "failed" : "unknown")
                    line["error"] = failure.json["error"]
                    line["variants"] = .array(order.map { .object(["id": .string($0.description), "before": before($0)]) })
                    try store.append(.object(line))
                    throw failure
                }
                var logged: [JSONValue] = []
                for id in order {
                    let (state, plan) = planned[id]!
                    var entry: [String: JSONValue] = ["id": .string(id.description)]
                    var ok = false
                    switch outcomes[id] ?? .failed("Capture One returned no result for this id.") {
                    case .done(let errors, let values, let layerNames):
                        ok = errors.isEmpty
                        entry["outcome"] = .string(ok ? "ok" : "failed")
                        entry["before"] = before(id)
                        entry["after"] = nest(Array(zip(plan.readBack, values)))
                        let mismatches = zip(plan.readBack, values).compactMap { read, stored -> JSONValue? in
                            guard let sent = plan.sent[read], !(stored.map { sent.approximatelyEquals($0) } ?? false) else { return nil }
                            return .object(["field": .string(read.path), "sent": sent, "stored": stored ?? .null])
                        }
                        if !mismatches.isEmpty { entry["warnings"] = .array(mismatches) }
                        if !errors.isEmpty {
                            entry["errors"] = .array(errors.map { error in
                                .object(["step": .string(Self.describe(plan.steps[error.step])), "message": .string(error.message)])
                            })
                        }
                        let namesBefore = state.layers.map { $0["name"]?.string ?? "" }
                        if namesBefore != layerNames {
                            entry["layers"] = .object(["before": .array(namesBefore.map(JSONValue.string)), "after": .array(layerNames.map(JSONValue.string))])
                        }
                    case .notFound:
                        entry["outcome"] = .string("failed")
                        entry["error"] = .object(["code": .string("not-found"), "message": .string("Capture One no longer finds variant \(id).")])
                    case .failed(let reason):
                        entry["outcome"] = .string("failed")
                        entry["error"] = .object(["code": .string("write-failed"), "message": .string(reason)])
                    }
                    logged.append(.object(entry))
                    results[id] = .object(entry.merging(plan.extra) { $1 })
                    try finish?(id, ok, store)
                }
                line["outcome"] = .string(logged.allSatisfy { $0["outcome"] == .string("ok") } ? "ok" : "failed")
                line["variants"] = .array(logged)
                try store.append(.object(line))
            }
            var output: [String: JSONValue] = ["variants": .array(ids.map { results[$0]! })]
            if !warnings.isEmpty { output["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(output)
        }
    }

    static func describe(_ step: Step) -> String {
        switch step {
        case .write(let write): return "set \(write.read.path)"
        case .action(let action): return "\(action)"
        }
    }
}

/// `set`'s arguments as the log records them.
struct SetLog: Encodable {
    let ids: [VariantID]
    let variant, adjustments, lensCorrection: [String: JSONValue]?
    let layers: [JSONValue]?

    init(_ arguments: SetArguments) {
        ids = arguments.ids; variant = arguments.variant; adjustments = arguments.adjustments; lensCorrection = arguments.lensCorrection
        layers = arguments.layers?.map { patch in
            var fields: [String: JSONValue] = ["layer": {
                switch patch.layer {
                case .index(let index): return .int(Int64(index))
                case .name(let name), .tag(let name): return .string(name)
                }
            }()]
            if let enabled = patch.enabled { fields["enabled"] = .bool(enabled) }
            if let opacity = patch.opacity { fields["opacity"] = .int(Int64(opacity)) }
            if let adjustments = patch.adjustments { fields["adjustments"] = .object(adjustments) }
            return .object(fields)
        }
    }
}

extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}
