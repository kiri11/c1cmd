import Foundation
import CryptoKit

/// Versioned image-level recipes. Layers, masks and installed styles are excluded.
public enum Recipes {
    public static let tools = ["reference_capture", "recipe_register", "recipe_verify", "edit_apply", "edit_status"]
    public static let fields = ["brightness", "contrast", "saturation", "highlight adjustment", "shadow recovery", "white recovery", "black recovery", "clarity amount", "clarity structure", "sharpening amount", "sharpening radius", "sharpening threshold", "noise reduction luminance", "noise reduction color"]
    public static let curveFields = ["rgb curve", "luma curve", "red curve", "green curve", "blue curve"]
    public static let finishFields = ["film grain type", "film grain impact", "film grain granularity", "vignetting method", "vignetting amount"]
    public static let balanceFields = ["color balance master hue", "color balance master saturation", "color balance shadow hue", "color balance shadow saturation", "color balance shadow lightness", "color balance midtone hue", "color balance midtone saturation", "color balance midtone lightness", "color balance highlight hue", "color balance highlight saturation", "color balance highlight lightness"]
    public static var supportedFields: [String] { fields + curveFields + finishFields + balanceFields }
    static let oracleFields = ["exposure", "temperature", "tint"] + fields + curveFields + finishFields + balanceFields
    static let str = ContractSchema.string
    static let num = ContractSchema.number
    static var exposure: [String:Any] { ContractSchema.object(["mode":["type":"string", "enum":["preserve","absolute","relative"]], "value":num], required:["mode"]) }
    static var whiteBalance: [String:Any] { ContractSchema.object(["mode":["type":"string", "enum":["preserve","absolute"]], "temperature":num, "tint":num], required:["mode"]) }
    static var settings: [String:Any] { ContractSchema.object((NativeEditing.patchSchema["properties"] as! [String:Any]).filter { supportedFields.contains($0.key) }) }
    static var recipe: [String:Any] { ContractSchema.object(["version":["type":"integer","enum":[1,2]], "referenceId":str, "scopes":RecipeScopes.schema, "settings":settings, "exposure":exposure, "whiteBalance":whiteBalance, "cropPolicy":["type":"string","enum":["preserve","per-photo"]]], required:["version","referenceId","settings","exposure","whiteBalance","cropPolicy"]) }
    static var recipeSchema: [String:Any] { recipe }
    static var geometry: [String:Any] {
        var props = ContractSchema.input("geometry_set")["properties"] as! [String:Any]
        for k in ["workingRef","ifGeometryState","dryRun"] { props.removeValue(forKey:k) }
        return ContractSchema.object(props)
    }
    public static func input(_ tool: String) -> [String:Any] {
        switch tool {
        case "reference_capture": return ContractSchema.object(["ref":str, "ifDocument":str, "ifState":str], required:["ref","ifDocument","ifState"])
        case "recipe_register": return ContractSchema.object(["recipe":recipe], required:["recipe"])
        case "recipe_verify": return ContractSchema.object(["recipeId":str,"workingRef":str,"ifDocument":str,"ifState":str], required:["recipeId","workingRef","ifDocument","ifState"])
        case "edit_status": return ContractSchema.object(["compoundId":str], required:["compoundId"])
        default: return ContractSchema.object(["recipeId":str,"sourceRef":str,"ifDocument":str,"ifState":str,"ifGeometryState":str,"overrides":settings,"exposure":exposure,"whiteBalance":whiteBalance,"geometry":geometry,"preview":ContractSchema.boolean], required:["recipeId","sourceRef","ifDocument","ifState"])
        }
    }
    static func responses(_ existing: [String:Any]) -> [String:Any] {
        let object: [String:Any] = ["type":"object","additionalProperties":true]
        let strings: [String:Any] = ["type":"array","items":str]
        let report = ContractSchema.object([
            "compoundId":str,"recipeId":str,"status":["type":"string","enum":["running","succeeded","failed","outcome-unknown","interrupted"]],
            "documentToken":str,"sourceRef":str,"workingRef":str,"journalOffset":["type":"integer"],"plan":strings,
            "completed":["type":"array","items":ContractSchema.object(["step":str,"result":object],required:["step","result"])],
            "request":object,"initial":existing["get"]!,"activeStep":["type":["string","null"]],
            "scopedBefore":RecipeScopes.evidenceSchema,"scopedObserved":RecipeScopes.evidenceSchema,"resultBundle":CompoundResultBundle.schema(existing),"observed":existing["get"]!,"error":object,"unattempted":strings,"referencesExpired":ContractSchema.boolean,
            "childOperations":["type":"array","items":existing["operation_status"]!]],required:["compoundId","recipeId","status","completed","plan"])
        return ["reference_capture":ContractSchema.object(["referenceId":str,"bundle":object],required:["referenceId","bundle"]),
                "recipe_register":ContractSchema.object(["recipeId":str,"status":["enum":["unverified"]],"recipe":recipe],required:["recipeId","status","recipe"]),
                "recipe_verify":report,"edit_apply":report,"edit_status":report]
    }
    public static func validate(_ tool: String, _ args: [String:Any]) throws {
        try ContractSchema.validateValue(args, schema:input(tool), path:tool)
        func enums(_ value: Any, _ schema: [String:Any]) throws {
            if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { String(describing:$0) == String(describing:value) }) { throw C1Error.invalidRequest("Invalid recipe policy or version.") }
            if let object = value as? [String:Any], let props = schema["properties"] as? [String:[String:Any]] {
                for (k,v) in object { if let spec = props[k] { try enums(v,spec) } }
            }
        }
        try enums(args,input(tool))
        let payload = args["recipe"] as? [String:Any] ?? args
        if let scopes = payload["scopes"] as? [String:Any] {
            guard payload["version"] as? Int == 2 else { throw C1Error.invalidRequest("Explicit scopes require recipe version 2.") }
            try RecipeScopes.validate(scopes,cropPolicy:payload["cropPolicy"] as! String)
        }
        if let p = payload["exposure"] as? [String:Any] {
            let mode = p["mode"] as! String
            guard (mode == "preserve") == (p["value"] == nil) else { throw C1Error.invalidRequest("Exposure preserve omits value; absolute/relative require value.") }
            if let value = p["value"] as? Double, mode == "absolute" { _ = try ContractSchema.parseAdjustments(["exposure":value], delta:false) }
        }
        if let p = payload["whiteBalance"] as? [String:Any] {
            let preserve = p["mode"] as! String == "preserve"
            guard preserve ? p.count == 1 : p["temperature"] != nil && p["tint"] != nil else { throw C1Error.invalidRequest("White balance preserve omits values; absolute requires temperature and tint together.") }
            if !preserve { _ = try ContractSchema.parseAdjustments(["temperature":p["temperature"]!,"tint":p["tint"]!], delta:false) }
        }
        if let patch = (payload["settings"] ?? args["overrides"]) as? [String:Any], !patch.isEmpty {
            try NativeEditing.validate(NativeEditing.parseValues(JSONSerialization.data(withJSONObject:patch)), target:NativeTarget())
        }
        if let g = args["geometry"] as? [String:Any] {
            var request = g; request["workingRef"] = "validate"; request["ifGeometryState"] = "validate"
            try ContractSchema.validate(tool:"geometry_set", arguments:request)
            guard args["ifGeometryState"] != nil else { throw C1Error.invalidRequest("Geometry requires the inspected source ifGeometryState.") }
        }
        for key in ["recipeId","compoundId"] where args[key] != nil { try identifier(args[key] as! String) }
        if let id = payload["referenceId"] as? String { try identifier(id) }
    }
    static func identifier(_ id: String) throws {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw C1Error.invalidRequest("Expected a SHA-256 content identifier.") }
    }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys]) }
    public static func digest(_ value: Any) throws -> String { SHA256.hash(data:try data(value)).map { String(format:"%02x",$0) }.joined() }
    static func object<T:Encodable>(_ value: T) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any] }
    static func write(_ value: [String:Any], to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(), withIntermediateDirectories:true)
        try data(value).write(to:url, options:.atomic)
        let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.synchronize()
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY); guard fd >= 0 else { throw C1Error.invalidRequest("Cannot sync recipe directory.") }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw C1Error.invalidRequest("Cannot sync recipe directory.") }
    }
    static func load(_ url: URL) throws -> [String:Any] {
        guard let value = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else { throw C1Error.invalidRequest("Invalid recipe evidence file.") }; return value
    }
    static func root(_ doc: DocumentInfo) -> URL { URL(fileURLWithPath:doc.documentPath).appendingPathComponent(".c1") }
    static func file(_ doc: DocumentInfo, _ kind: String, _ id: String) -> URL { root(doc).appendingPathComponent(kind).appendingPathComponent(id + ".json") }
    static func loadContent(_ doc: DocumentInfo, _ kind: String, _ id: String) throws -> [String:Any] {
        try identifier(id)
        let value = try load(file(doc,kind,id))
        guard try digest(value) == id else { throw C1Error.invalidRequest("Content hash mismatch for " + kind) }
        return value
    }
    static func putContent(_ value: [String:Any], _ doc: DocumentInfo, _ kind: String) throws -> String {
        let id = try digest(value), url = file(doc,kind,id)
        if FileManager.default.fileExists(atPath:url.path) { _ = try loadContent(doc,kind,id) }
        else { try write(value,to:url) }
        return id
    }
}

/// One bounded photo per lock. Only the existing mutation primitives dispatch writes.
/// Parent reports are evidence; child operation journals remain recovery authority.
public final class RecipeWorkflow {
    let core: SessionController
    public init(core: SessionController = .shared) { self.core = core }
    public func run(_ tool: String, arguments args: [String:Any]) throws -> [String:Any] {
        try Recipes.validate(tool,args)
        return try CaptureOneLock.shared.withLock {
            let doc = try core.getDocumentInfo()
            guard doc.appVersion == SessionController.pinnedBuild else { throw C1Error.unsupportedVersion("Recipes require the qualified Capture One build.") }
            if let token = args["ifDocument"] as? String, token != doc.openToken { throw C1Error.documentChanged("Recipe document changed.") }
            switch tool {
            case "reference_capture": return try capture(doc,args)
            case "recipe_register":
                let recipe = args["recipe"] as! [String:Any]
                _ = try Recipes.loadContent(doc,"references",recipe["referenceId"] as! String)
                let id = try Recipes.putContent(recipe,doc,"recipes")
                return ["recipeId":id,"status":"unverified","recipe":recipe]
            case "edit_status": return try status(doc,args["compoundId"] as! String)
            case "recipe_verify", "edit_apply": return try apply(doc,args,verify:tool == "recipe_verify")
            default: throw C1Error.invalidRequest("Unknown recipe operation.")
            }
        }
    }
    private func capture(_ doc: DocumentInfo, _ args: [String:Any]) throws -> [String:Any] {
        let ref = args["ref"] as! String
        let before = try core.get(ref:ref, nativeTargets:[NativeTarget(),NativeTarget(scope:"lens"),NativeTarget(scope:"variant")])
        guard before.stateHash == args["ifState"] as? String else { throw C1Error.stateChanged("Reference changed since inspection.") }
        let scopeBefore = try core.recipeScopesOracle(ref:ref)
        let preview = try core.preview(ref:ref)
        let after = try core.get(ref:ref, nativeTargets:[NativeTarget(),NativeTarget(scope:"lens"),NativeTarget(scope:"variant")])
        let scopeAfter = try core.recipeScopesOracle(ref:ref)
        guard scopeBefore == scopeAfter else { throw C1Error.stateChanged("Scoped reference values changed during capture.") }
        // Preview adds journal revisions to native tokens; compare observed values instead.
        guard before.adjustments == after.adjustments, before.geometry == after.geometry,
              before.metadata == after.metadata, before.parentImagePath == after.parentImagePath,
              zip(before.nativeSnapshots!,after.nativeSnapshots!).allSatisfy({ $0.values == $1.values && $0.layers == $1.layers && $0.unavailable == $1.unavailable }),
              try core.getDocumentInfo().openToken == doc.openToken else { throw C1Error.stateChanged("Reference changed while exporting preview.") }
        let bytes = try Data(contentsOf:URL(fileURLWithPath:preview.outputPath))
        let checksum = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        let bundle: [String:Any] = ["version":2,"scopedNative":try scopeAfter.evidence(),"document":try Recipes.object(doc),"observed":try Recipes.object(after),"preview":try Recipes.object(preview),"previewFileSha256":checksum,
            "coverage":["capturedScopes":["adjustments","lens","variant","basicColor","advancedColor"],"maskPixels":"unsupported","skinTone":"unsupported","layerSettings":"not-captured","colorEditorElements":"captured-image-scope","rawBytes":"not-included","profileAssets":"names-only-bytes-not-captured","atomicSnapshot":false],"createdAt":ISO8601DateFormatter().string(from:Date())]
        let id = try Recipes.putContent(bundle,doc,"references")
        return ["referenceId":id,"bundle":bundle]
    }
    private func status(_ doc: DocumentInfo, _ id: String) throws -> [String:Any] {
        var report = try Recipes.load(Recipes.file(doc,"compounds",id))
        guard report["compoundId"] as? String == id else { throw C1Error.invalidRequest("Compound identity mismatch.") }
        let entries = try OperationJournal(sessionDirectory:URL(fileURLWithPath:doc.documentPath)).validatedEntries()
        let token = report["documentToken"] as? String
        // For interrupted parents, expose linked child records as observations,
        // never claim success or automatically resume/reconcile.
        if report["status"] as? String == "running" {
            report["status"] = "interrupted"
            report["childOperations"] = try entries.filter { $0.compoundId == id }.map { try Recipes.object($0) }
            report["referencesExpired"] = token != doc.openToken
        }
        return report
    }
    private func apply(_ doc: DocumentInfo, _ args: [String:Any], verify: Bool) throws -> [String:Any] {
        let id = args["recipeId"] as! String
        let recipe = try Recipes.loadContent(doc,"recipes",id)
        try Recipes.validate("recipe_register",["recipe":recipe])
        _ = try Recipes.loadContent(doc,"references",recipe["referenceId"] as! String)
        var verificationEvidence: [String:Any]?
        if !verify {
            let evidence = try Recipes.load(Recipes.file(doc,"verified-recipes",id))
            guard evidence["recipeId"] as? String == id, evidence["build"] as? String == doc.appVersion,
                  evidence["status"] as? String == "verified" else { throw C1Error.invalidRequest("Recipe lacks matching verification evidence.") }
            guard let verificationID = evidence["compoundId"] as? String else { throw C1Error.invalidRequest("Missing verification report.") }
            try Recipes.identifier(verificationID)
            let verification = try Recipes.load(Recipes.file(doc,"compounds",verificationID))
            guard try Recipes.digest(verification) == evidence["reportHash"] as? String, verification["status"] as? String == "succeeded", verification["recipeId"] as? String == id else { throw C1Error.invalidRequest("Verification report was changed.") }
            verificationEvidence = evidence
        }
        if args["geometry"] != nil, recipe["cropPolicy"] as? String != "per-photo" { throw C1Error.invalidRequest("Recipe crop policy preserves geometry.") }
        let sourceRef = args[verify ? "workingRef" : "sourceRef"] as! String
        if verify, !WorkingRef.isWorkingRefString(sourceRef) { throw C1Error.invalidRequest("Verification requires an explicitly created managed clone.") }
        let initial = try core.get(ref:sourceRef,nativeTargets:[NativeTarget()])
        guard initial.stateHash == args["ifState"] as? String,
              args["ifGeometryState"] == nil || initial.geometryStateHash == args["ifGeometryState"] as? String else { throw C1Error.stateChanged("Compound source changed since inspection.") }
        let scopes = recipe["scopes"] as? [String:Any] ?? [:]
        let scoped = recipe["version"] as? Int == 2
        try RecipeScopes.compatibility(scopes,source:initial)
        if !verify, scopes["lens"] != nil, args["ifGeometryState"] == nil { throw C1Error.invalidRequest("Lens scopes require the inspected ifGeometryState.") }
        let scopeBefore = scoped ? try core.recipeScopesOracle(ref:sourceRef) : nil
        let scopeSteps = try scopeBefore.map { try RecipeScopes.steps(scopes,before:$0) } ?? []
        var patch = recipe["settings"] as! [String:Any]
        for (key,value) in args["overrides"] as? [String:Any] ?? [:] { patch[key] = value }
        let exposure = (args["exposure"] ?? recipe["exposure"]) as! [String:Any]
        let wb = (args["whiteBalance"] ?? recipe["whiteBalance"]) as! [String:Any]
        var tonal: [String:Any] = [:]
        if exposure["mode"] as? String != "preserve" {
            let value = (exposure["value"] as! NSNumber).doubleValue
            tonal["exposure"] = exposure["mode"] as? String == "relative" ? initial.adjustments.exposure! + value : value
        }
        if wb["mode"] as? String == "absolute" { tonal["temperature"] = wb["temperature"]; tonal["tint"] = wb["tint"] }
        let adjustments = tonal.isEmpty ? nil : try ContractSchema.parseAdjustments(tonal,delta:false)
        let nativePatch = try NativeEditing.parseValues(Recipes.data(patch))
        if !nativePatch.isEmpty { try NativeEditing.validate(nativePatch,target:NativeTarget()) }
        let journal = OperationJournal(sessionDirectory:URL(fileURLWithPath:doc.documentPath))
        try core.assertSessionWritable(docInfo:doc,operation:"compound edit")
        try journal.assertReady()
        let journalOffset = try journal.validatedEntries().count
        let compoundId = try Recipes.digest(["nonce":UUID().uuidString])
        let path = Recipes.file(doc,"compounds",compoundId)
        var plan: [String] = ["prepare"]
        plan += scopeSteps.map(\.name)
        if !patch.isEmpty { plan.append("settings") }
        if !tonal.isEmpty { plan.append("tonal") }
        if args["geometry"] != nil { plan.append("geometry") }
        if verify || scoped { plan.append("verify") }
        if verify || args["preview"] as? Bool == true { plan.append("preview") }
        plan.append("observe")
        var report: [String:Any] = ["compoundId":compoundId,"recipeId":id,"status":"running","documentToken":doc.openToken,"sourceRef":sourceRef,"journalOffset":journalOffset,"plan":plan,"completed":[],"request":args,"initial":try Recipes.object(initial)]
        if let scopeBefore { report["scopedBefore"] = try scopeBefore.evidence() }
        var completed: [[String:Any]] = [], ref = sourceRef, step = "prepare"
        try Recipes.write(report,to:path)
        Thread.current.threadDictionary["c1.compoundId"] = compoundId
        defer { Thread.current.threadDictionary.removeObject(forKey:"c1.compoundId") }
        func save() throws { try RequestContext.current?.checkCompoundCancellation(); report["completed"] = completed; report["activeStep"] = step; try Recipes.write(report,to:path) }
        func finish(_ result: [String:Any]) throws { completed.append(["step":step,"result":result]); try save() }
        do {
            let oracleBefore = (verify || scoped) ? try core.recipeOracle(ref:sourceRef) : [:]
            let nativeBefore = (verify || scoped) ? try core.get(ref:sourceRef,nativeTargets:[NativeTarget()]).nativeSnapshots![0] : nil
            if verify {
                // Existing mutation guards validate clone provenance before dispatch.
                let snapshot = try core.get(ref:ref,nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                guard let contrast = snapshot.values["contrast"], contrast != .unset else { throw C1Error.invalidRequest("Verification target has no readable contrast.") }
                _ = try core.nativeSet(workingRef:ref,target:NativeTarget(),ifNativeState:snapshot.nativeStateHash,patch:["contrast":contrast],dryRun:true)
                try finish(["workingRef":ref])
            } else {
                let edit = try core.editVariant(sourceRef:sourceRef,ifState:initial.stateHash,ifDocument:doc.openToken,ifGeometryState:args["ifGeometryState"] as? String)
                ref = edit.workingRef; report["workingRef"] = ref; try finish(Recipes.object(edit))
            }
            report["workingRef"] = ref
            for scopedStep in scopeSteps {
                step = scopedStep.name; try save()
                let fresh = try core.get(ref:ref,nativeTargets:[scopedStep.target]).nativeSnapshots![0]
                let result: NativeMutationResult
                if let action = scopedStep.action {
                    result = try core.nativeAction(workingRef:ref,target:scopedStep.target,ifNativeState:fresh.nativeStateHash,action:action)
                } else {
                    result = try core.nativeSet(workingRef:ref,target:scopedStep.target,ifNativeState:fresh.nativeStateHash,patch:scopedStep.patch)
                }
                try finish(Recipes.object(result))
            }
            if !patch.isEmpty {
                step = "settings"; try save()
                let fresh = try core.get(ref:ref,nativeTargets:[NativeTarget()]).nativeSnapshots![0]
                try finish(Recipes.object(core.nativeSet(workingRef:ref,target:NativeTarget(),ifNativeState:fresh.nativeStateHash,patch:nativePatch)))
            }
            if let adjustments {
                step = "tonal"; try save()
                let fresh = try core.get(ref:ref)
                // Relative exposure is computed again from the immediately observed state.
                var actual = adjustments
                if exposure["mode"] as? String == "relative" { actual.exposure = fresh.adjustments.exposure! + (exposure["value"] as! NSNumber).doubleValue }
                try finish(Recipes.object(core.mutate(workingRefString:ref,ifState:fresh.stateHash,setAdjustments:actual,addAdjustments:nil)))
            }
            if let geometry = args["geometry"] as? [String:Any] {
                step = "geometry"; try save()
                let fresh = try core.get(ref:ref)
                guard let token = fresh.geometryStateHash else { throw C1Error.invalidRequest("Geometry unavailable.") }
                let crop = try geometry["crop"].map { try JSONDecoder().decode(CropRect.self,from:Recipes.data($0)) }
                let keystone = try geometry["keystone"].map { try JSONDecoder().decode(KeystoneAdjustments.self,from:Recipes.data($0)) }
                try finish(Recipes.object(core.geometrySet(workingRef:ref,ifGeometryState:token,crop:crop,rotation:geometry["rotation"] as? Double,aspectRatio:geometry["aspectRatio"] as? Double,keystone:keystone)))
            }
            if verify || scoped {
                step = "verify"; try save()
                var expected = oracleBefore
                for (key,value) in nativePatch { expected[key] = value }
                for (key,value) in tonal { expected[key] = .number((value as! NSNumber).doubleValue) }
                let observed = try core.recipeOracle(ref:ref)
                for key in Recipes.oracleFields {
                    let tolerance = key == "temperature" ? 1.0 : (key == "tint" ? 0.05 : 0.0001)
                    guard let a = observed[key], let b = expected[key], (key.hasPrefix("color balance") ? NativeEditing.matchesReadback(field:key,expected:b,actual:a) : a.matches(b, tolerance:tolerance)) else { throw C1Error.readbackMismatch("Independent recipe verification failed: " + key) }
                }
                let fullAfter = try core.get(ref:ref,nativeTargets:[NativeTarget()])
                let nativeAfter = fullAfter.nativeSnapshots![0]
                var changedKeys = Set(patch.keys).union(tonal.keys).union(wb["mode"] as? String == "absolute" ? ["white balance preset"] : [])
                if let camera = scopes["camera"] as? [String:Any] { changedKeys.formUnion((camera["settings"] as! [String:Any]).keys) }
                if let geometry = args["geometry"] as? [String:Any] {
                    if geometry["rotation"] != nil { changedKeys.insert("rotation") }
                    if let keystone = geometry["keystone"] as? [String:Any] { changedKeys.formUnion(keystone.keys.map { "keystone " + $0 }) }
                }
                // Capture One exposes the same highlight control with opposite signs.
                if let highlight = patch["highlight adjustment"] as? Double {
                    guard nativeAfter.values["highlight recovery"] == .number(-highlight) else { throw C1Error.readbackMismatch("Coupled highlight recovery differs from adjustment.") }
                    changedKeys.insert("highlight recovery")
                }
                guard nativeBefore!.layers == nativeAfter.layers, nativeBefore!.unavailable == nativeAfter.unavailable else { throw C1Error.readbackMismatch("Recipe changed native coverage or layers.") }
                for (key,value) in nativeBefore!.values where !changedKeys.contains(key) {
                    guard let actual = nativeAfter.values[key], NativeEditing.matchesReadback(field:key,expected:value,actual:actual) else { throw C1Error.readbackMismatch("Recipe changed omitted field: " + key) }
                }
                let after = fullAfter
                guard after.metadata == initial.metadata else { throw C1Error.readbackMismatch("Recipe changed metadata.") }
                if args["geometry"] == nil {
                    if let lens = scopes["lens"] as? [String:Any] {
                        let beforeGeometry = (try Recipes.object(initial))["geometry"] as? [String:Any] ?? [:]
                        let afterGeometry = (try Recipes.object(after))["geometry"] as? [String:Any] ?? [:]
                        let keys = ["rotation","orientation","flip","keystone","cropOutsideImage"] + (lens["geometryPolicy"] as? String == "preserve-crop" ? ["crop"] : [])
                        guard NSDictionary(dictionary:beforeGeometry.filter { keys.contains($0.key) }).isEqual(to:afterGeometry.filter { keys.contains($0.key) }) else { throw C1Error.readbackMismatch("Lens scope changed protected composition.") }
                    } else {
                        guard after.geometry == initial.geometry else { throw C1Error.readbackMismatch("Recipe changed geometry.") }
                    }
                }
                if let scopeBefore {
                    let scopeAfter = try core.recipeScopesOracle(ref:ref)
                    report["scopedObserved"] = try scopeAfter.evidence()
                    try scopeAfter.assertMatches(scopeBefore.expected(scopes))
                }
                try finish(["independentBefore":try Recipes.object(oracleBefore),"independentAfter":try Recipes.object(observed),"coverage":Recipes.oracleFields])
            }
            if verify || args["preview"] as? Bool == true { step = "preview"; try save(); try finish(Recipes.object(core.preview(ref:ref))) }
            step = "observe"; try save()
            let observed = try core.get(ref:ref,nativeTargets:[NativeTarget()])
            try finish(Recipes.object(observed))
            if let scopeBefore {
                let finalScopes = try core.recipeScopesOracle(ref:ref)
                report["scopedObserved"] = try finalScopes.evidence()
                try finalScopes.assertMatches(scopeBefore.expected(scopes))
            }
            guard try core.getDocumentInfo().openToken == doc.openToken else { throw C1Error.documentChanged("Compound document changed.") }
            report["resultBundle"] = CompoundResultBundle.make(initial:try Recipes.object(initial), observed:try Recipes.object(observed), completed:completed,
                document:try Recipes.object(doc), recipe:recipe, verification:verificationEvidence, request:args, compoundId:compoundId, workingRef:ref)
            if let before = report["scopedBefore"], let after = report["scopedObserved"] {
                var bundle = report["resultBundle"] as! [String:Any]
                bundle["scopedNative"] = ["before":before,"observed":after,"diff":CompoundResultBundle.changes(before as! [String:Any],after as! [String:Any])]
                var coverage = bundle["coverage"] as! [String:Any]
                coverage["colorEditorElements"] = "compared-image-scope"
                coverage["nativeLensAndVariantSettings"] = "lens-compared-variant-not-compared"
                bundle["coverage"] = coverage
                report["resultBundle"] = bundle
            }
            report["status"] = "succeeded"; report["observed"] = try Recipes.object(observed); report["activeStep"] = NSNull(); try Recipes.write(report,to:path)
            if verify {
                try Recipes.write(["recipeId":id,"build":doc.appVersion,"status":"verified","compoundId":compoundId,"reportHash":try Recipes.digest(report),"coverage":Recipes.oracleFields,"scopedCoverage":scoped ? ["camera","lens","basicColor","advancedColor"] : [],"maskPixels":"excluded","visualReview":"required"],to:Recipes.file(doc,"verified-recipes",id))
            }
            return report
        } catch {
            report.removeValue(forKey:"resultBundle")
            report["status"] = error is OperationFailure ? "outcome-unknown" : "failed"
            report["error"] = ErrorResponse.payload(error)["error"]
            report["completed"] = completed; report["activeStep"] = step
            report["unattempted"] = Array(plan.drop(while:{ $0 != step }).dropFirst())
            // If persistence fails, the last durable running report and child journals
            // remain authoritative; return parent and available child IDs in the error.
            let originalError = error
            do { try Recipes.write(report,to:path) } catch {
                throw CompoundFailure(compoundId:compoundId,cause:originalError,persistenceError:String(describing:error))
            }
            return report
        }
    }
}
