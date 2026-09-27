import Foundation

/// One contract tool call, validated against the contract schema and decoded.
/// Every CLI command and MCP tool call enters core through `init(tool:arguments:)`,
/// so both transports accept and reject exactly the same arguments.
public struct ToolRequest {
    public let tool: String
    public let arguments: [String: Any]
    let command: Command

    enum Command {
        case doctor, documentInfo, capabilities, schema
        case readSessionBegin(collection: String?, selected: Bool)
        case readSessionEnd(workflow: String), readSessionStatus(workflow: String)
        case catalogGet(database: String, variantID: Int)
        case catalogVariants(database: String, collectionID: Int?, rating: Int?, minRating: Int?)
        case catalogInspect(database: String), catalogSnapshot(database: String, destination: String)
        case variantsList(VariantsQuery)
        case variantEdit(sourceRef: String, ifState: String, ifDocument: String, ifGeometryState: String?)
        case variantClone(sourceRef: String), variantBaseline(sourceRef: String), variantDelete(workingRef: String)
        case get(ref: String, live: Bool, readWorkflow: String?, nativeTargets: [NativeTarget]?)
        case adjust(workingRef: String, ifState: String, adjustments: Adjustments, delta: Bool, dryRun: Bool)
        case reset(workingRef: String, ifState: String, fields: [String], dryRun: Bool)
        case metadataSet(workingRef: String, ifMetadataState: String, rating: Int?, colorTag: Int?, dryRun: Bool)
        case geometrySet(workingRef: String, ifGeometryState: String, crop: CropRect?, rotation: Double?,
                         aspectRatio: Double?, keystone: KeystoneAdjustments?, dryRun: Bool)
        case geometryRestore(workingRef: String, ifGeometryState: String, dryRun: Bool)
        case nativeSet(workingRef: String, target: NativeTarget, ifNativeState: String, patch: [String: NativeValue], dryRun: Bool)
        case nativeAction(workingRef: String, target: NativeTarget, ifNativeState: String, action: String,
                          arguments: [String: NativeValue], dryRun: Bool)
        case diff(ref1: String, ref2: String?, live: Bool, readWorkflow: String?)
        case dump(collection: String?, selected: Bool, live: Bool, readWorkflow: String?, batchSize: Int)
        case preview(ref: String, outputDir: String?, timeout: Double, fullFrame: Bool)
        case operationStatus(operationId: String)
        case requestStatus(requestId: String)
        case recipe
    }

    struct VariantsQuery {
        let collection: String?, selected: Bool, live: Bool, readWorkflow: String?
        let ids: [String]?, fields: String, parentPath: String?
        let rating: Int?, minRating: Int?, batchSize: Int, deadlineSeconds: Double?
    }

    public init(tool: String, arguments a: [String: Any]) throws {
        try ContractSchema.validate(tool: tool, arguments: a)
        self.tool = tool
        self.arguments = a
        func string(_ key: String) -> String? { a[key] as? String }
        func flag(_ key: String) -> Bool { a[key] as? Bool ?? false }
        func int(_ key: String) -> Int? { (a[key] as? NSNumber)?.intValue }
        func number(_ key: String) -> Double? { (a[key] as? NSNumber)?.doubleValue }
        func decoded<T: Decodable>(_ key: String) throws -> T? {
            try a[key].map { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: $0)) }
        }
        func nativeValues(_ key: String) throws -> [String: NativeValue] {
            try NativeEditing.parseValues(JSONSerialization.data(withJSONObject: a[key] ?? [String: Any]()))
        }
        // Validation above guarantees every required key and type used below.
        switch tool {
        case "doctor": command = .doctor
        case "doc_info": command = .documentInfo
        case "capabilities": command = .capabilities
        case "schema": command = .schema
        case "read_session_begin": command = .readSessionBegin(collection: string("collection"), selected: flag("selected"))
        case "read_session_end": command = .readSessionEnd(workflow: string("readWorkflow")!)
        case "read_session_status": command = .readSessionStatus(workflow: string("readWorkflow")!)
        case "catalog_get": command = .catalogGet(database: string("database")!, variantID: int("variantID")!)
        case "catalog_variants":
            command = .catalogVariants(database: string("database")!, collectionID: int("collectionID"), rating: int("rating"), minRating: int("minRating"))
        case "catalog_inspect": command = .catalogInspect(database: string("database")!)
        case "catalog_snapshot": command = .catalogSnapshot(database: string("database")!, destination: string("destination")!)
        case "variants_list":
            command = .variantsList(VariantsQuery(collection: string("collection"), selected: flag("selected"), live: flag("live"),
                readWorkflow: string("readWorkflow"), ids: a["ids"] as? [String], fields: string("fields") ?? "minimal",
                parentPath: string("parentPath"), rating: int("rating"), minRating: int("minRating"),
                batchSize: int("batchSize") ?? 32, deadlineSeconds: number("deadlineSeconds")))
        case "variant_edit":
            command = .variantEdit(sourceRef: string("sourceRef")!, ifState: string("ifState")!, ifDocument: string("ifDocument")!,
                                   ifGeometryState: string("ifGeometryState"))
        case "variant_clone": command = .variantClone(sourceRef: string("sourceRef")!)
        case "variant_baseline": command = .variantBaseline(sourceRef: string("sourceRef")!)
        case "variant_delete": command = .variantDelete(workingRef: string("workingRef")!)
        case "get":
            let ref = string("ref")!
            command = .get(ref: ref, live: flag("live"), readWorkflow: string("readWorkflow"),
                           nativeTargets: try a["nativeTargets"].map { try NativeEditing.parseTargets($0, ref: ref) })
        case "set", "add":
            let controls: Set<String> = ["workingRef", "ifState", "dryRun", "adjustments"]
            let values = a["adjustments"] as? [String: Any] ?? a.filter { !controls.contains($0.key) }
            var adjustments = Adjustments()
            for (name, value) in values {
                adjustments.setValue((value as! NSNumber).doubleValue, for: FieldRegistry.shared.canonicalName(for: name)!)
            }
            command = .adjust(workingRef: string("workingRef")!, ifState: string("ifState")!, adjustments: adjustments,
                              delta: tool == "add", dryRun: flag("dryRun"))
        case "reset":
            command = .reset(workingRef: string("workingRef")!, ifState: string("ifState")!, fields: a["fields"] as? [String] ?? [], dryRun: flag("dryRun"))
        case "metadata_set":
            command = .metadataSet(workingRef: string("workingRef")!, ifMetadataState: string("ifMetadataState")!,
                                   rating: int("rating"), colorTag: int("colorTag"), dryRun: flag("dryRun"))
        case "geometry_set":
            command = .geometrySet(workingRef: string("workingRef")!, ifGeometryState: string("ifGeometryState")!,
                                   crop: try decoded("crop"), rotation: number("rotation"), aspectRatio: number("aspectRatio"),
                                   keystone: try decoded("keystone"), dryRun: flag("dryRun"))
        case "geometry_restore":
            command = .geometryRestore(workingRef: string("workingRef")!, ifGeometryState: string("ifGeometryState")!, dryRun: flag("dryRun"))
        case "native_set":
            let target = try NativeEditing.target(a["target"])
            command = .nativeSet(workingRef: string("workingRef")!, target: target, ifNativeState: string("ifNativeState")!,
                patch: try NativeEditing.parsePatch(JSONSerialization.data(withJSONObject: a["patch"]!), target: target), dryRun: flag("dryRun"))
        case "native_action":
            command = .nativeAction(workingRef: string("workingRef")!, target: try NativeEditing.target(a["target"]),
                ifNativeState: string("ifNativeState")!, action: string("action")!, arguments: try nativeValues("arguments"), dryRun: flag("dryRun"))
        case "diff": command = .diff(ref1: string("ref1")!, ref2: string("ref2"), live: flag("live"), readWorkflow: string("readWorkflow"))
        case "dump":
            command = .dump(collection: string("collection"), selected: flag("selected"), live: flag("live"),
                            readWorkflow: string("readWorkflow"), batchSize: int("batchSize") ?? 100)
        case "preview":
            command = .preview(ref: string("ref")!, outputDir: string("outputDir"), timeout: number("timeout") ?? 30, fullFrame: flag("fullFrame"))
        case "operation_status": command = .operationStatus(operationId: string("operationId")!)
        case "request_status": command = .requestStatus(requestId: string("requestId")!)
        default:
            guard Recipes.tools.contains(tool) else { throw C1Error.invalidRequest("Unknown tool: \(tool)") }
            command = .recipe
        }
    }

    /// Tools that never contact Capture One or take the application lock, so a
    /// transport can serve them while another request is running.
    public static let localTools: Set<String> = ["request_status", "catalog_get", "catalog_variants", "catalog_inspect", "catalog_snapshot"]

    /// Runs the request against Capture One or local state. Nothing here retries a write.
    public func dispatch() throws -> ToolResponse {
        #if DEBUG
        // Offline contract tests compare the arguments each transport produced, without executing them.
        if ProcessInfo.processInfo.environment["C1_CONTRACT_ECHO"] == "1" { return .object(["tool": tool, "arguments": arguments]) }
        #endif
        let core = SessionController.shared, browsing = ReadWorkflow.shared
        switch command {
        case .doctor: return .doctor(try core.doctor())
        case .documentInfo: return .documentInfo(try core.getDocumentInfo())
        case .capabilities: return .object(core.capabilities())
        case .schema: return .object(ContractSchema.document())
        case .readSessionBegin(let collection, let selected): return .object(try browsing.begin(collection: collection, selected: selected))
        case .readSessionEnd(let workflow): return .object(try browsing.end(workflowID: workflow))
        case .readSessionStatus(let workflow): return .object(try browsing.status(workflowID: workflow))
        case .catalogGet(let database, let id): return .object(try CatalogReader(database: database).get(variantID: id))
        case .catalogVariants(let database, let collectionID, let rating, let minRating):
            return .object(try CatalogReader(database: database).variants(collectionID: collectionID, rating: rating, minRating: minRating))
        case .catalogInspect(let database): return .object(try CatalogReader(database: database).inspect())
        case .catalogSnapshot(let database, let destination): return .object(try CatalogReader(database: database).snapshot(destination: destination))
        case .variantsList(let q):
            if let ids = q.ids {
                return .object(try core.listVariantSubset(ids: ids, collection: q.collection, selected: q.selected, rating: q.rating,
                    minRating: q.minRating, parentPath: q.parentPath, fields: q.fields, batchSize: q.batchSize, deadlineSeconds: q.deadlineSeconds))
            }
            if !q.live, q.deadlineSeconds == nil,
               let rows = try browsing.variants(collection: q.collection, selected: q.selected, rating: q.rating, minRating: q.minRating, workflowID: q.readWorkflow) {
                return .object(rows)
            }
            return .variants(try core.listVariants(collectionName: q.collection, selectedOnly: q.selected, rating: q.rating,
                                                   minRating: q.minRating, batchSize: q.batchSize, deadlineSeconds: q.deadlineSeconds))
        case .variantEdit(let sourceRef, let ifState, let ifDocument, let ifGeometryState):
            return .value(try core.editVariant(sourceRef: sourceRef, ifState: ifState, ifDocument: ifDocument, ifGeometryState: ifGeometryState))
        case .variantClone(let sourceRef): return .clone(try core.cloneVariant(sourceRef: sourceRef))
        case .variantBaseline(let sourceRef): return .clone(try core.createBaselineVariant(sourceRef: sourceRef))
        case .variantDelete(let workingRef): return .delete(try core.deleteVariant(workingRefString: workingRef))
        case .get(let ref, let live, let workflow, let targets):
            if let targets { return .get(try core.get(ref: ref, nativeTargets: targets)) }
            if !live, let result = try browsing.get(ref: ref, workflowID: workflow) { return .object(result) }
            return .get(try core.get(ref: ref))
        case .adjust(let workingRef, let ifState, let adjustments, let delta, let dryRun):
            return .mutation(try core.mutate(workingRefString: workingRef, ifState: ifState, setAdjustments: delta ? nil : adjustments,
                                             addAdjustments: delta ? adjustments : nil, isDryRun: dryRun))
        case .reset(let workingRef, let ifState, let fields, let dryRun):
            return .mutation(try core.reset(workingRefString: workingRef, ifState: ifState, fields: fields, isDryRun: dryRun))
        case .metadataSet(let workingRef, let token, let rating, let colorTag, let dryRun):
            return .value(try core.metadataSet(workingRef: workingRef, ifMetadataState: token, rating: rating, colorTag: colorTag, dryRun: dryRun))
        case .geometrySet(let workingRef, let token, let crop, let rotation, let aspectRatio, let keystone, let dryRun):
            return .value(try core.geometrySet(workingRef: workingRef, ifGeometryState: token, crop: crop, rotation: rotation,
                                               aspectRatio: aspectRatio, keystone: keystone, dryRun: dryRun))
        case .geometryRestore(let workingRef, let token, let dryRun):
            return .value(try core.geometryRestore(workingRef: workingRef, ifGeometryState: token, dryRun: dryRun))
        case .nativeSet(let workingRef, let target, let token, let patch, let dryRun):
            return .value(try core.nativeSet(workingRef: workingRef, target: target, ifNativeState: token, patch: patch, dryRun: dryRun))
        case .nativeAction(let workingRef, let target, let token, let action, let values, let dryRun):
            return .value(try core.nativeAction(workingRef: workingRef, target: target, ifNativeState: token, action: action, arguments: values, dryRun: dryRun))
        case .diff(let ref1, let ref2, let live, let workflow):
            if !live, let result = try browsing.diff(ref1: ref1, ref2: ref2, workflowID: workflow) { return .object(result) }
            return .diff(try core.diff(ref1: ref1, ref2: ref2))
        case .dump(let collection, let selected, let live, let workflow, let batchSize):
            if !live, let rows = try browsing.dump(collection: collection, selected: selected, workflowID: workflow) { return .object(rows) }
            return .dump(try core.dump(collectionName: collection, selectedOnly: selected, batchSize: batchSize))
        case .preview(let ref, let outputDir, let timeout, let fullFrame):
            return .preview(try core.preview(ref: ref, outputDirOverride: outputDir, timeout: timeout, fullFrame: fullFrame))
        case .operationStatus(let id): return .operation(try core.operationStatus(operationId: id))
        case .requestStatus(let id): return .value(try RequestContext.status(requestId: id))
        case .recipe: return .compound(try RecipeWorkflow(core: core).run(tool, arguments: arguments))
        }
    }
}

/// The result of one dispatched tool call. Transports choose how to present it.
public enum ToolResponse {
    case doctor(DoctorReport)
    case documentInfo(DocumentInfo)
    /// A fresh native inventory; browsing-workflow and subset rows are `object`.
    case variants([VariantSummary])
    case get(GetResult)
    case mutation(MutationResult)
    case diff(DiffResult)
    case dump([DumpRecord])
    case preview(PreviewResult)
    case operation(OperationRecord)
    case clone(CloneResult)
    case delete(DeleteResult)
    case value(any Encodable)
    /// A recipe or compound edit report, which can describe an unfinished edit.
    case compound([String: Any])
    /// A JSON object or array.
    case object(Any)

    public var json: String {
        switch self {
        case .doctor(let v): return OutputFormatter.formatJson(v)
        case .documentInfo(let v): return OutputFormatter.formatJson(v)
        case .variants(let v): return OutputFormatter.formatJson(v)
        case .get(let v): return OutputFormatter.formatJson(v)
        case .mutation(let v): return OutputFormatter.formatJson(v)
        case .diff(let v): return OutputFormatter.formatJson(v)
        case .dump(let v): return OutputFormatter.formatJson(v)
        case .preview(let v): return OutputFormatter.formatJson(v)
        case .operation(let v): return OutputFormatter.formatJson(v)
        case .clone(let v): return OutputFormatter.formatJson(v)
        case .delete(let v): return OutputFormatter.formatJson(v)
        case .value(let v): return OutputFormatter.formatJson(v)
        case .compound(let v): return (try? ReadWorkflow.json(v)) ?? "{}"
        case .object(let v): return (try? ReadWorkflow.json(v)) ?? "{}"
        }
    }

    /// The call completed but reports a failed check or an unfinished compound edit.
    public var reportsFailure: Bool {
        switch self {
        case .doctor(let report): return !report.allChecksPassed
        case .compound(let report): return ["failed", "outcome-unknown", "interrupted"].contains(report["status"] as? String ?? "")
        default: return false
        }
    }
}
