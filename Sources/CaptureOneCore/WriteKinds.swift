import Foundation

/// Rating and color tag, verified against the native reply and an independent readback.
struct MetadataWrite: WriteKind {
    let rating: Int?
    let colorTag: Int?

    struct Reply: Decodable { let variantId: String; let ratingVal: Int; let colorTagVal: Int }

    var operationType: String { "metadata_set" }
    var pinnedBuildRequirement: String? { "Metadata writes require Capture One \(SessionController.pinnedBuild)." }
    var staleMessage: String { "Rating or color tag changed or is unavailable; read get again." }

    func read(_ observation: GetResult) -> VariantMetadata? { VariantMetadata.from(observation.metadata) }
    func token(_ state: VariantMetadata) -> String { state.stateHash }
    func plan(from before: VariantMetadata, target: WriteTarget, dryRun: Bool) -> VariantMetadata {
        VariantMetadata(rating: rating ?? before.rating, colorTag: colorTag ?? before.colorTag)
    }

    func dispatch(_ intended: VariantMetadata, before: Observed<VariantMetadata>, to target: WriteTarget) throws -> Reply {
        try target.executor.executeAndDecode(handler: "applyMetadata", args: [
            NSAppleEventDescriptor(string: target.documentId), NSAppleEventDescriptor(string: target.variantId),
            rating.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
            colorTag.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
            NSAppleEventDescriptor(int32: Int32(before.state.rating)), NSAppleEventDescriptor(int32: Int32(before.state.colorTag)),
            NSAppleEventDescriptor(string: target.parentImagePath)])
    }

    func verify(before: Observed<VariantMetadata>, intended: VariantMetadata, reply: Reply,
                after: Observed<VariantMetadata>) -> String? {
        guard reply.variantId == before.observation.id else { return "Metadata write reported a different variant." }
        guard reply.ratingVal == intended.rating, reply.colorTagVal == intended.colorTag, after.state == intended else {
            return "Metadata readback did not match: intended rating \(intended.rating) and color tag \(intended.colorTag), observed rating \(after.state.rating) and color tag \(after.state.colorTag)."
        }
        guard after.observation.stateHash == before.observation.stateHash,
              after.observation.geometryStateHash == before.observation.geometryStateHash else {
            return "Tone or geometry changed during the metadata write."
        }
        return nil
    }

    func record(_ entry: inout OperationRecord, before: VariantMetadata, intended: VariantMetadata, reply: Reply?, after: VariantMetadata?) {
        entry.beforeMetadata = before
        entry.intendedMetadata = intended
        entry.afterMetadata = after
        entry.diff = after?.changes(from: before)
    }
}

/// Exposure, contrast, saturation and white balance, verified against the native
/// reply and an independent readback.
struct TonalWrite: WriteKind {
    enum Change {
        case set(Adjustments)
        case add(Adjustments)
        /// Restores the named fields (all when empty) to the reference's saved defaults.
        case reset([String])
    }

    struct Intended {
        let target: Adjustments
        /// The fields dispatched: those requested, with white balance as a pair.
        let patch: Adjustments
    }

    let change: Change
    private var registry: FieldRegistry { .shared }

    var operationType: String {
        switch change {
        case .set: return "set"
        case .add: return "add"
        case .reset: return "reset"
        }
    }
    var staleMessage: String { "Adjustments changed since inspection; read get again." }

    func read(_ observation: GetResult) -> Adjustments? { observation.adjustments }
    func token(_ state: Adjustments) -> String { StateHash.compute(for: state).hex }

    func plan(from before: Adjustments, target: WriteTarget, dryRun: Bool) throws -> Intended {
        let requested: Adjustments
        var result = before
        switch change {
        case .add(let delta):
            requested = delta
            result = try registry.applyDelta(base: before, delta: delta)
        case .set(let values):
            requested = values
        case .reset(let fields):
            requested = try registry.computeResetValues(fields: fields, baseline: target.baselineAdjustments)
        }
        guard requested.hasAnyField else { throw C1Error.invalidRequest("Provide exactly one nonempty set or add adjustment patch.") }
        var patch = Adjustments()
        for field in registry.supportedAdjustmentFields {
            guard let value = requested.value(for: field.name) else { continue }
            if case .add = change {} else { result.setValue(value, for: field.name) }
            patch.setValue(value, for: field.name)
        }
        try registry.validateAdjustments(result)
        for field in registry.supportedAdjustmentFields where patch.value(for: field.name) != nil {
            patch.setValue(result.value(for: field.name), for: field.name)
        }
        // White balance must be written and verified as a pair.
        if patch.temperature != nil || patch.tint != nil { patch.temperature = result.temperature; patch.tint = result.tint }
        return Intended(target: result, patch: patch)
    }

    func dispatch(_ intended: Intended, before: Observed<Adjustments>, to target: WriteTarget) throws -> ApplyAdjustmentsResult {
        let patch = intended.patch
        return try target.executor.executeAndDecode(handler: "applyAdjustments", args: [
            NSAppleEventDescriptor(string: target.documentId), NSAppleEventDescriptor(string: target.variantId)]
            + [patch.exposure, patch.contrast, patch.saturation, patch.temperature, patch.tint].map {
                $0.map { NSAppleEventDescriptor(double: $0) } ?? .missingValue()
            }
            + [NSAppleEventDescriptor(list: registry.supportedAdjustmentFields.map { NSAppleEventDescriptor(double: before.state.value(for: $0.name)!) }),
               NSAppleEventDescriptor(string: target.parentImagePath)])
    }

    func verify(before: Observed<Adjustments>, intended: Intended, reply: ApplyAdjustmentsResult,
                after: Observed<Adjustments>) -> String? {
        let replied = Adjustments(exposure: reply.afterExposureVal, contrast: reply.afterContrastVal,
                                  saturation: reply.afterSaturationVal, temperature: reply.afterTemperatureVal, tint: reply.afterTintVal)
        var mismatches: [String] = []
        for field in registry.supportedAdjustmentFields {
            guard let expected = intended.target.value(for: field.name) else { continue }
            for (source, observed) in [("reply", replied), ("readback", after.state)] {
                let actual = observed.value(for: field.name) ?? 0
                if !registry.valuesMatchWithinTolerance(field: field.name, expected: expected, actual: actual) {
                    mismatches.append("\(field.name) \(source) (expected \(expected), got \(actual))")
                }
            }
        }
        return mismatches.isEmpty ? nil : "Readback mismatch after mutation: " + mismatches.joined(separator: ", ")
    }

    func record(_ entry: inout OperationRecord, before: Adjustments, intended: Intended, reply: ApplyAdjustmentsResult?, after: Adjustments?) {
        entry.intendedAdjustments = intended.target
        entry.diff = after?.changes(from: before)
    }
}

extension Adjustments {
    /// Fields that differ, keyed by field name.
    func changes(from before: Adjustments) -> [String: DoubleDiff] {
        var diff: [String: DoubleDiff] = [:]
        for field in FieldRegistry.shared.supportedAdjustmentFields {
            if let b = before.value(for: field.name), let a = value(for: field.name), b != a {
                diff[field.name] = DoubleDiff(before: b, after: a)
            }
        }
        return diff
    }
}

/// Crop, rotation and keystone. The native reply resolves the final crop when
/// Capture One supplies bounds only after its own rotation or keystone setter runs.
struct GeometryWrite: WriteKind {
    struct State {
        let geometry: Geometry
        let hash: String
    }

    struct Intended {
        /// The exact target, or nil until native bounds are known.
        let target: Geometry?
        /// Set when the crop depends on bounds Capture One computes during the write.
        let request: GeometryRequest?
        /// The current geometry with the requested keystone controls applied.
        let context: Geometry
    }

    let crop: CropRect?
    let rotation: Double?
    let aspectRatio: Double?
    let keystone: KeystoneAdjustments?
    let restore: Bool
    private var registry: FieldRegistry { .shared }

    var operationType: String { restore ? "geometry_restore" : "geometry_set" }
    var pinnedBuildRequirement: String? { "Geometry requires Capture One \(SessionController.pinnedBuild)." }
    var staleMessage: String { "Geometry precondition no longer matches; read get again." }

    func read(_ observation: GetResult) -> State? {
        guard let geometry = observation.geometry, let hash = observation.geometryStateHash else { return nil }
        return State(geometry: geometry, hash: hash)
    }
    func unavailable(_ observation: GetResult) -> C1Error {
        .invalidRequest(observation.geometryUnavailableReason ?? "Geometry unavailable.")
    }
    func token(_ state: State) -> String { state.hash }

    func plan(from state: State, target: WriteTarget, dryRun: Bool) throws -> Intended {
        let before = state.geometry
        var context = before
        if let keystone { context.keystone = try keystone.applying(to: before.keystone) }
        let keystoneChanged = context.keystone != before.keystone
        if restore {
            guard let baseline = target.baselineGeometry, baseline.unsupportedReason == nil, before.unsupportedReason == nil,
                  before.sameContext(as: baseline, includingKeystone: false) else {
                throw C1Error.stateChanged("Geometry context changed since the baseline; review before restoring crop/rotation/keystone.")
            }
            // This exact crop was observed on this image with the same lens/orientation
            // context. It may legitimately exceed the conservative bounds for NEW crops.
            var restored = before
            restored.crop = baseline.crop; restored.rotation = baseline.rotation; restored.keystone = baseline.keystone
            return Intended(target: restored, request: nil, context: context)
        }
        guard before.requiresNativeBounds || keystone != nil else {
            return Intended(target: try before.target(crop: crop, rotation: rotation, aspectRatio: aspectRatio), request: nil, context: context)
        }
        if let reason = before.unsupportedReason { throw C1Error.invalidRequest(reason) }
        guard crop != nil || rotation != nil || aspectRatio != nil || keystone != nil else { throw C1Error.invalidRequest("Provide crop, rotation, or aspectRatio.") }
        if dryRun && keystoneChanged {
            throw C1Error.invalidRequest("Keystone changes require native execution; dry runs cannot predict the final crop.")
        }
        if dryRun && before.hasPerspectiveOrMovements && aspectRatio != nil {
            throw C1Error.invalidRequest("Perspective and movement ratio fits require native crop normalization; dry runs cannot predict the final crop.")
        }
        let request = try GeometryRequest(crop: crop, rotation: rotation ?? before.rotation, aspectRatio: aspectRatio, keystone: keystone)
        // Validate all knowable bounds before dispatch. At a new rotation,
        // Capture One supplies bounds after its rotation setter executes.
        let known = !keystoneChanged && (request.rotation == before.rotation || dryRun)
        return Intended(target: known ? try before.target(crop: crop, rotation: rotation ?? before.rotation, aspectRatio: aspectRatio) : nil,
                        request: request, context: context)
    }

    /// Returns the resolved target. A reply outside the native bounds leaves the outcome unknown.
    func dispatch(_ intended: Intended, before: Observed<State>, to target: WriteTarget) throws -> Geometry {
        let geometry = before.state.geometry
        let arguments = [
            NSAppleEventDescriptor(string: target.documentId), NSAppleEventDescriptor(string: target.variantId),
            NSAppleEventDescriptor(string: target.parentImagePath), geometry.eventSnapshot,
            NSAppleEventDescriptor(list: registry.supportedAdjustmentFields.map { NSAppleEventDescriptor(double: before.observation.adjustments.value(for: $0.name)!) })]
        guard let request = intended.request else {
            guard let exact = intended.target else { throw C1Error.invalidRequest("Geometry target is unavailable.") }
            let _: GeometryRecord = try target.executor.executeAndDecode(handler: "applyGeometry", args: arguments + [
                NSAppleEventDescriptor(list: exact.crop.values.map { NSAppleEventDescriptor(double: $0) }), NSAppleEventDescriptor(double: exact.rotation),
                NSAppleEventDescriptor(list: exact.keystone.map { NSAppleEventDescriptor(double: $0) })])
            return exact
        }
        let context = intended.context
        let applied: CorrectedGeometryResult = try target.executor.executeAndDecode(handler: "applyCorrectedGeometry", args: arguments + [
            request.crop.map { NSAppleEventDescriptor(list: $0.values.map { NSAppleEventDescriptor(double: $0) }) } ?? .missingValue(),
            NSAppleEventDescriptor(double: request.rotation), request.aspectRatio.map { NSAppleEventDescriptor(double: $0) } ?? .missingValue(),
            NSAppleEventDescriptor(list: context.keystone.map { NSAppleEventDescriptor(double: $0) })])
        guard applied.targetCropValues.count == 4, applied.boundsValues.count == 4,
              applied.targetCropValues.allSatisfy({ $0.isFinite }), applied.boundsValues.allSatisfy({ $0.isFinite }) else {
            throw C1Error.readbackMismatch("Corrected geometry native target or bounds are malformed.")
        }
        let c = applied.targetCropValues, b = applied.boundsValues
        let nativeCropUnchangedByCaller = request.crop == nil && request.aspectRatio == nil
        guard c[2] >= 1, c[3] >= 1, b[2] > 0, b[3] > 0,
              nativeCropUnchangedByCaller || (abs(c[0]-b[0])+c[2]/2 <= b[2]/2+2 && abs(c[1]-b[1])+c[3]/2 <= b[3]/2+2) else {
            throw C1Error.readbackMismatch("Corrected geometry target exceeds the native bounds.")
        }
        var resolved = context
        resolved.rotation = request.rotation
        resolved.crop = CropRect(centerX: c[0], centerY: c[1], width: c[2], height: c[3])
        if let crop = request.crop, resolved.crop != crop { throw C1Error.readbackMismatch("Native crop differs from the explicit request.") }
        if let ratio = request.aspectRatio, abs(c[2] - c[3]*ratio) > max(2, ratio*2) {
            throw C1Error.readbackMismatch("Native crop does not match the requested aspect ratio.")
        }
        let keystoneChanged = context.keystone != geometry.keystone
        if (geometry.hasPerspectiveOrMovements || context.hasPerspectiveOrMovements || keystoneChanged), let ratio = request.aspectRatio {
            guard let fit = applied.fittedCropValues, fit.count == 4,
                  fit.allSatisfy({ $0.isFinite }), fit[2] >= 1, fit[3] >= 1,
                  abs(fit[0]-c[0])+fit[2]/2 <= c[2]/2+2,
                  abs(fit[1]-c[1])+fit[3]/2 <= c[3]/2+2,
                  abs(fit[2]-fit[3]*ratio) <= max(2,ratio*2) else {
                throw C1Error.readbackMismatch("Native perspective fit must preserve the requested ratio inside the target rectangle.")
            }
            resolved.crop = CropRect(centerX:fit[0],centerY:fit[1],width:fit[2],height:fit[3])
        }
        return resolved
    }

    func verify(before: Observed<State>, intended: Intended, reply resolved: Geometry, after: Observed<State>) -> String? {
        guard after.state.geometry.matchesTarget(resolved),
              after.state.geometry.sameContext(as: before.state.geometry, includingKeystone: false),
              after.observation.stateHash == before.observation.stateHash else {
            return "Crop/rotation/keystone or preserved settings did not match; inspect operation status."
        }
        return nil
    }

    func record(_ entry: inout OperationRecord, before: State, intended: Intended, reply resolved: Geometry?, after: State?) {
        // The pending entry keeps the caller's request; the concrete target replaces
        // the intent once native bounds are known.
        entry.intendedGeometry = resolved ?? intended.target
        entry.requestedGeometry = intended.request
        entry.diff = after?.geometry.changes(from: before.geometry)
    }
}

/// One native property patch or native action on one target, verified against a
/// fresh native snapshot. Deleted targets are verified through their parent scope.
struct NativeWrite: WriteKind {
    let target: NativeTarget
    let patch: [String: NativeValue]
    let action: String?
    let arguments: [String: NativeValue]

    var operationType: String { "native" }
    var pinnedBuildRequirement: String? { "Native editing requires Capture One \(SessionController.pinnedBuild)." }
    var staleMessage: String { "Native editing state changed. Read get with nativeTargets again." }

    /// Deleted targets no longer exist; inspect the image scope and layer inventory instead.
    private var readbackTarget: NativeTarget {
        action == "color.delete" ? NativeTarget(layer: target.layer) : action == "layer.delete" ? NativeTarget() : target
    }

    // One fresh, operation-local observation supplies both the native precondition
    // and the durable before-state. readNative validates reference/parent identity
    // and checks the document after the native read.
    func observe(_ ref: String, afterDispatch: Bool, with core: SessionController) throws -> GetResult {
        try core.readNative(ref: ref, target: afterDispatch ? readbackTarget : target)
    }
    func read(_ observation: GetResult) -> NativeSnapshot? { observation.nativeSnapshots?.first }
    func token(_ state: NativeSnapshot) -> String { state.nativeStateHash }

    func plan(from before: NativeSnapshot, target _: WriteTarget, dryRun: Bool) throws -> [String: NativeValue] {
        for key in patch.keys where before.values[key] == nil { throw C1Error.invalidRequest("Native field unavailable on this target: " + key) }
        if target.layer > before.layers.count { throw C1Error.invalidRequest("Layer no longer exists.") }
        if (action?.hasPrefix("mask.") == true && action != "mask.people") || action == "layer.delete" {
            guard target.layer > 0, before.layers[target.layer-1].nativeKind != "background" else { throw C1Error.invalidRequest("The image layer cannot be deleted or masked.") }
        }
        if case .number(let sourceLayer) = arguments["sourceLayer"], Int(sourceLayer) > before.layers.count { throw C1Error.invalidRequest("Source mask layer does not exist.") }
        return action == nil ? patch : arguments
    }

    func dispatch(_ values: [String: NativeValue], before: Observed<NativeSnapshot>, to destination: WriteTarget) throws -> Bool {
        let snapshot = before.state
        let fields = snapshot.values.keys.sorted(), keys = action == nil ? NativeEditing.orderedPatchKeys(patch, target: target) : arguments.keys.sorted()
        var args = [NSAppleEventDescriptor(string: destination.documentId), .init(string: destination.variantId)] + target.descriptors + [
            .init(string: destination.parentImagePath), .init(list: fields.map { .init(string: $0) }),
            .init(list: fields.map { snapshot.values[$0]!.descriptor }), .init(list: snapshot.layers.map { .init(list:[.init(string:$0.nativeName), .init(string:$0.nativeKind), .init(int32:Int32($0.nativeOpacity)), .init(boolean:$0.nativeEnabled)]) })]
        if let action { args.append(.init(string: action)) }
        args += [.init(list: keys.map { .init(string: $0) }), .init(list: keys.map { values[$0]!.descriptor })]
        return try destination.executor.executeAndDecode(handler: action == nil ? "nativeApply" : "nativeAction", args: args)
    }

    func verify(before: Observed<NativeSnapshot>, intended: [String: NativeValue], reply: Bool, after: Observed<NativeSnapshot>) -> String? {
        let before = before.state, after = after.state
        if let action {
            let change = after.layers.count - before.layers.count
            if action == "layer.create", change != 1 { return "Layer creation did not add exactly one layer." }
            if action == "layer.delete", change != -1 { return "Layer deletion did not remove exactly one layer." }
            if action == "color.create", after.advancedColorCount != before.advancedColorCount + 1 { return "Color correction creation readback differs." }
            if action == "color.delete", after.advancedColorCount != before.advancedColorCount - 1 { return "Color correction deletion readback differs." }
            if action == "mask.people" {
                // Qualified on 16.8.5.30: existing layers stay; one adjustment layer is appended,
                // or up to one per area with separate layers (an unmatched area may add none).
                var limit = 1
                if arguments["separateLayers"] == .boolean(true), case .texts(let areas)? = arguments["areas"] { limit = max(1, areas.count) }
                let added = after.layers.dropFirst(before.layers.count)
                guard Array(after.layers.prefix(before.layers.count)) == before.layers, (1...limit).contains(added.count),
                      added.allSatisfy({ $0.nativeKind == "adjustment" }) else { return "People mask did not append its mask layers." }
            }
        }
        for (key, value) in patch.sorted(by: { $0.key < $1.key }) {
            guard let actual = after.values[key], NativeEditing.matchesReadback(field: key, expected: value, actual: actual) else {
                return "Native readback mismatch: " + key
            }
        }
        return nil
    }

    /// Qualified on 16.8.5.30: without people in the photo, Capture One raises -1728
    /// and leaves native values, layers and existing mask pixels unchanged.
    func refusal(_ error: Error) -> C1Error? {
        guard action == "mask.people", case .scriptError(let message, -1728)? = error as? C1Error,
              message.contains("No people detected") else { return nil }
        return .noPeopleDetected("Capture One detected no people in this photo; nothing was changed.")
    }

    // The native token also covers the journal revision, which the pending entry changes.
    func unchanged(before: Observed<NativeSnapshot>, after: Observed<NativeSnapshot>) -> Bool {
        let b = before.state, a = after.state, bo = before.observation, ao = after.observation
        return a.target == b.target && a.values == b.values && a.unavailable == b.unavailable && a.layers == b.layers
            && a.basicColorCount == b.basicColorCount && a.advancedColorCount == b.advancedColorCount
            && ao.stateHash == bo.stateHash && ao.geometryStateHash == bo.geometryStateHash && ao.metadataStateHash == bo.metadataStateHash
    }

    func record(_ entry: inout OperationRecord, before: NativeSnapshot, intended: [String: NativeValue], reply: Bool?, after: NativeSnapshot?) {
        entry.beforeNative = before
        entry.nativePatch = intended
        entry.nativeAction = action
        entry.afterNative = after
    }
}
