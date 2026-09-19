import Foundation
import CoreFoundation

/// Presentation only: derives evidence from retained observations, without native
/// calls, mutation tokens for later steps, journal writes or recovery decisions.
enum CompoundResultBundle {
    static func changes(_ before: [String:Any], _ after: [String:Any], prefix: String = "") -> [String:Any] {
        var result: [String:Any] = [:]
        for key in Set(before.keys).union(after.keys).sorted() {
            let name = prefix + key, a = before[key], b = after[key]
            if let a = a as? [String:Any], let b = b as? [String:Any] {
                result.merge(changes(a,b,prefix:name + ".")) { _, new in new }
                continue
            }
            if let a, let b, NSDictionary(dictionary:["value":a]).isEqual(to:["value":b]) { continue }
            var change: [String:Any] = ["before":a ?? NSNull(), "after":b ?? NSNull(),
                                      "beforePresent":a != nil, "afterPresent":b != nil]
            if let a = a as? NSNumber, let b = b as? NSNumber,
               CFGetTypeID(a) != CFBooleanGetTypeID(), CFGetTypeID(b) != CFBooleanGetTypeID() {
                change["delta"] = b.doubleValue - a.doubleValue
            }
            result[name] = change
        }
        return result
    }

    static func hashes(_ observation: [String:Any]) -> [String:Any] {
        var result = observation.filter { ["stateHash","geometryStateHash","metadataStateHash"].contains($0.key) }
        result["native"] = (observation["nativeSnapshots"] as? [[String:Any]] ?? []).map {
            ["target":$0["target"]!, "nativeStateHash":$0["nativeStateHash"]!]
        }
        return result
    }

    static func make(initial: [String:Any], observed: [String:Any], completed: [[String:Any]],
                     document: [String:Any], recipe: [String:Any], verification: [String:Any]?,
                     request: [String:Any], compoundId: String, workingRef: String) -> [String:Any] {
        let before = (initial["nativeSnapshots"] as? [[String:Any]])?.first ?? [:]
        let after = (observed["nativeSnapshots"] as? [[String:Any]])?.first ?? [:]
        let beforeValues = before["values"] as? [String:Any] ?? [:]
        let afterValues = after["values"] as? [String:Any] ?? [:]
        let comparable = Set(beforeValues.keys).intersection(afterValues.keys)
        let beforeUnavailable = before["unavailable"] as? [String:Any] ?? [:]
        let afterUnavailable = after["unavailable"] as? [String:Any] ?? [:]
        let notCompared = Set(beforeValues.keys).union(afterValues.keys)
            .union(beforeUnavailable.keys).union(afterUnavailable.keys).subtracting(comparable).sorted()
        let geometryAvailable = initial["geometry"] != nil && observed["geometry"] != nil
        let stepResults = completed.compactMap { step -> (String,[String:Any])? in
            guard let name = step["step"] as? String, let value = step["result"] as? [String:Any] else { return nil }
            return (name,value)
        }
        let operations: [[String:Any]] = stepResults.compactMap { name,value in
            guard let id = value["operationId"] as? String else { return nil }
            return ["step":name,"operationId":id]
        }
        let preview = stepResults.first(where:{ $0.0 == "preview" })?.1
        var effectiveSettings = recipe["settings"] as? [String:Any] ?? [:]
        effectiveSettings.merge(request["overrides"] as? [String:Any] ?? [:]) { _,override in override }
        let policies: [String:Any] = ["settings":effectiveSettings,"scopes":recipe["scopes"] ?? [:],
            "exposure":request["exposure"] ?? recipe["exposure"]!,
            "whiteBalance":request["whiteBalance"] ?? recipe["whiteBalance"]!,
            "cropPolicy":recipe["cropPolicy"]!,"geometry":request["geometry"] ?? NSNull()]
        let provenance: [String:Any] = ["compoundId":compoundId,"document":document,
            "sourceRef":request["sourceRef"] ?? request["workingRef"]!,
            "nativeVariantId":observed["id"]!,"parentImagePath":observed["parentImagePath"] ?? NSNull(),
            "workingRef":workingRef,"recipeId":request["recipeId"]!,"recipe":recipe,
            "referenceId":recipe["referenceId"]!,"verification":verification ?? NSNull(),
            "mode":request["sourceRef"] == nil ? "recipe-verification" : "existing-variant-edit",
            "effectivePolicy":policies,"operations":operations,
            "initialHashes":hashes(initial),"finalHashes":hashes(observed)]
        return ["version":1,"observed":observed,"provenance":provenance,"preview":preview ?? NSNull(),
            "diff":[
                "adjustments":changes(initial["adjustments"] as? [String:Any] ?? [:],observed["adjustments"] as? [String:Any] ?? [:]),
                "geometry":geometryAvailable ? changes(initial["geometry"] as! [String:Any],observed["geometry"] as! [String:Any]) : [:],
                "metadata":changes(initial["metadata"] as? [String:Any] ?? [:],observed["metadata"] as? [String:Any] ?? [:]),
                "nativeAdjustments":changes(beforeValues.filter { comparable.contains($0.key) },afterValues.filter { comparable.contains($0.key) })],
            "coverage":["geometry":geometryAvailable ? "compared" : "unavailable",
                "nativeTarget":after["target"] ?? NSNull(),"nativeComparedFields":comparable.sorted(),
                "nativeNotComparedFields":notCompared,"nativeUnavailableBefore":beforeUnavailable,"nativeUnavailableAfter":afterUnavailable,
                "profileAssets":"names-only-bytes-not-captured","skinTone":"unsupported","maskPixels":"unsupported","layerSettings":"not-compared","colorEditorElements":"not-compared",
                "nativeLensAndVariantSettings":"not-compared","atomicSnapshot":false]]
    }

    static func schema(_ existing: [String:Any]) -> [String:Any] {
        let string = ContractSchema.string
        let object: [String:Any] = ["type":"object","additionalProperties":true]
        let nullableObject: [String:Any] = ["type":["object","null"],"additionalProperties":true]
        let strings: [String:Any] = ["type":"array","items":string]
        let delta = ContractSchema.object(["before":[:],"after":[:],"beforePresent":ContractSchema.boolean,
                                          "afterPresent":ContractSchema.boolean,"delta":ContractSchema.number],
                                         required:["before","after","beforePresent","afterPresent"])
        let changes: [String:Any] = ["type":"object","additionalProperties":delta]
        let hashes = ContractSchema.object(["stateHash":string,"geometryStateHash":string,"metadataStateHash":string,
            "native":["type":"array","items":ContractSchema.object(["target":NativeEditing.targetSchema,"nativeStateHash":string],required:["target","nativeStateHash"])]],required:["stateHash","native"])
        let provenance = ContractSchema.object(["compoundId":string,"document":existing["doc_info"]!,
            "sourceRef":string,"nativeVariantId":string,"parentImagePath":["type":["string","null"]],"workingRef":string,
            "recipeId":string,"recipe":Recipes.recipeSchema,"referenceId":string,"verification":nullableObject,
            "mode":["enum":["recipe-verification","existing-variant-edit"]],"effectivePolicy":object,
            "operations":["type":"array","items":ContractSchema.object(["step":string,"operationId":string],required:["step","operationId"])],
            "initialHashes":hashes,"finalHashes":hashes],required:["compoundId","document","sourceRef","nativeVariantId","parentImagePath","workingRef","recipeId","recipe","referenceId","verification","mode","effectivePolicy","operations","initialHashes","finalHashes"])
        var preview = existing["preview"] as! [String:Any]; preview["type"] = ["object","null"]
        return ContractSchema.object(["scopedNative":ContractSchema.object(["before":RecipeScopes.evidenceSchema,"observed":RecipeScopes.evidenceSchema,"diff":object],required:["before","observed","diff"]),"version":["enum":[1]],"observed":existing["get"]!,"diff":ContractSchema.object(
            ["adjustments":changes,"geometry":changes,"metadata":changes,"nativeAdjustments":changes],required:["adjustments","geometry","metadata","nativeAdjustments"]),
            "provenance":provenance,"preview":preview,"coverage":ContractSchema.object([
                "geometry":["enum":["compared","unavailable"]],"nativeTarget":nullableObject,
                "nativeComparedFields":strings,"nativeNotComparedFields":strings,"nativeUnavailableBefore":object,"nativeUnavailableAfter":object,
                "profileAssets":["enum":["names-only-bytes-not-captured"]],"skinTone":["enum":["unsupported"]],"maskPixels":["enum":["unsupported"]],"layerSettings":["enum":["not-compared"]],"colorEditorElements":["enum":["not-compared","compared-image-scope"]],
                "nativeLensAndVariantSettings":["enum":["not-compared","lens-compared-variant-not-compared"]],"atomicSnapshot":["const":false]],
                required:["geometry","nativeTarget","nativeComparedFields","nativeNotComparedFields","nativeUnavailableBefore","nativeUnavailableAfter","maskPixels","layerSettings","colorEditorElements","nativeLensAndVariantSettings","atomicSnapshot"])],required:["version","observed","diff","provenance","preview","coverage"])
    }
}
