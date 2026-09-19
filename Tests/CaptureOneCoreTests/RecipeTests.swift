import Foundation
import CaptureOneCore

private final class RecipeFake: ScriptExecuting {
    let geometry: GeometryFake
    var properties: [String:Any] = [:]
    var lens: [String:Any] = Dictionary(uniqueKeysWithValues:NativeEditing.fields["lens"]!.map { ($0.name, $0.type == "text" ? "fixture" as Any : $0.type == "boolean" ? false as Any : 0.0 as Any) })
    var basic: [[String:Any]] = (1...9).map { ["name":"band-\($0)","hue change":0.0,"saturation change":0.0,"lightness change":0.0] }
    var advanced: [[String:Any]] = []
    var corruptScope = false
    var ignoreDelete = false
    var fault: String?
    var corruptOracle = false
    var corruptField = "clarity amount"
    var corruptAfterWrites = 0
    var writes = 0
    init(_ directory: URL) { geometry = GeometryFake(directory:directory) }
    var fields: [String] { ["exposure","temperature","tint"] + Recipes.supportedFields }
    func values(_ id: String) -> [String:Any] {
        var v = Dictionary(uniqueKeysWithValues:fields.map { ($0,properties[$0] ?? 0) })
        for key in Recipes.curveFields { v[key] = properties[key] ?? [0.0,0,100,100] }
        v["film grain type"] = properties["film grain type"] ?? "fine"
        v["vignetting method"] = properties["vignetting method"] ?? "elliptic on crop"
        v["color profile"] = properties["color profile"] ?? "fixture"
        v["film curve"] = properties["film curve"] ?? "Auto"
        let a = geometry.base.values[id]!
        v["exposure"] = a[0]; v["contrast"] = a[1]; v["saturation"] = a[2]; v["temperature"] = a[3]; v["tint"] = a[4]
        return v
    }
    func executeAndDecode<T:Decodable>(handler: String,args: [NSAppleEventDescriptor]) throws -> T {
        let result: Any
        if handler == "nativeRead" {
            let scope = args[2].stringValue!, index = Int(args[4].int32Value) - 1
            let v: [String:Any]
            switch scope {
            case "adjustments": v = values(args[1].stringValue!)
            case "lens": v = lens
            case "basicColor": v = basic[index]
            case "advancedColor": v = advanced[index]
            default: v = [:]
            }
            result = ["nativeRows":v.keys.sorted().map { key -> [String:Any] in
                if NativeEditing.fields[scope]?.first(where: { $0.name == key })?.type == "boolean" { return ["fieldName":key,"boolVal":v[key]!] }
                if let text = v[key] as? String { return ["fieldName":key,"textVal":text] }
                return ["fieldName":key,"numbersVal":v[key] as? [Double] ?? [(v[key] as! NSNumber).doubleValue]]
            },"nativeLayers":[],"basicColorCount":basic.count,"advancedColorCount":advanced.count] as [String:Any]
        } else if handler == "nativeRecipeScopesOracle" {
            var observedLens = lens
            if corruptScope, writes > corruptAfterWrites { observedLens["light falloff"] = 99.0 }
            result = ["recipeCameraValues":[values(args[1].stringValue!)["color profile"]!,values(args[1].stringValue!)["film curve"]!],
                "recipeLensValues":NativeEditing.fields["lens"]!.map { observedLens[$0.name]! },
                "recipeBasicValues":basic.map { row in ["name","hue change","saturation change","lightness change"].map { row[$0]! } },
                "recipeAdvancedValues":advanced.map { row in NativeEditing.fields["advancedColor"]!.map { row[$0.name]! } }]
        } else if handler == "nativeAction" {
            writes += 1
            if fault == "native-action" { throw C1Error.timeout("recipe injected action timeout") }
            if args[9].stringValue == "color.delete", !ignoreDelete { advanced.remove(at:Int(args[4].int32Value)-1) }
            if args[9].stringValue == "color.create" { advanced.append(Dictionary(uniqueKeysWithValues:NativeEditing.fields["advancedColor"]!.map { ($0.name,$0.type == "boolean" ? true as Any : 0.0 as Any) })) }
            result = true
        } else if handler == "nativeRecipeOracle" {
            var v = values(args[1].stringValue!)
            if corruptOracle, writes > corruptAfterWrites { if Recipes.curveFields.contains(corruptField) { v[corruptField] = [0.0,0,50,70,100,100] }
                else if corruptField == "film grain type" { v[corruptField] = "harsh" }
                else { v[corruptField] = (v[corruptField] as! NSNumber).doubleValue + 1 } }
            result = fields.map { v[$0]! }
        } else if handler == "nativeApply" {
            writes += 1
            if fault == "native" { throw C1Error.timeout("recipe injected timeout") }
            let id = args[1].stringValue!
            for i in 1...args[9].numberOfItems {
                let key = args[9].atIndex(i)!.stringValue!, descriptor = args[10].atIndex(i)!
                let value: Any
                if Recipes.curveFields.contains(key) { value = (1...descriptor.numberOfItems).map { descriptor.atIndex($0)!.doubleValue } }
                else if NativeEditing.fields[args[2].stringValue!]?.first(where: { $0.name == key })?.type == "boolean" { value = descriptor.booleanValue }
                else if ["film grain type","vignetting method","film curve","color profile","lens profile"].contains(key) { value = descriptor.stringValue! }
                else { value = descriptor.doubleValue }
                switch args[2].stringValue! {
                case "lens": lens[key] = value
                case "basicColor": basic[Int(args[4].int32Value)-1][key] = value
                case "advancedColor": advanced[Int(args[4].int32Value)-1][key] = value
                default: properties[key] = value
                }
                if let index = ["exposure","contrast","saturation","temperature","tint"].firstIndex(of:key) { geometry.base.values[id]![index] = value as! Double }
            }
            result = true
        } else { return try geometry.executeAndDecode(handler:handler,args:args) }
        return try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:result,options:[.fragmentsAllowed]))
    }
}

struct RecipeTests {
    static func run() {
        print("Running RecipeTests...")
        let sha = String(repeating:"a",count:64)
        let policy: [String:Any] = ["version":1,"referenceId":sha,"settings":["clarity amount":5],"exposure":["mode":"preserve"],"whiteBalance":["mode":"preserve"],"cropPolicy":"preserve"]
        XCTAssertNoThrow(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":policy]))
        for (key,value) in [("version",3 as Any),("cropPolicy","magic"),("settings",["film curve":"Auto"]),("exposure",["mode":"absolute"]),("whiteBalance",["mode":"absolute","temperature":5000])] {
            var bad = policy; bad[key] = value
            XCTAssertThrowsError(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":bad]))
        }
        for settings: [String:Any] in [
            ["rgb curve":[0,0,50]], ["rgb curve":[0,0,0,50]], ["rgb curve":[0,0,100,101]],
            ["film grain type":"unknown"], ["vignetting method":2], ["film grain impact":true],
            ["temperature":5000], ["rotation":1], ["rgb curve":NSNull()]] {
            var bad = policy; bad["settings"] = settings
            XCTAssertThrowsError(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":bad]))
        }
        for scopes: [String:Any] in [
            ["camera":["cameraModel":"camera","settings":["exposure":1]]],
            ["camera":["cameraModel":"camera","settings":["film curve":""]]],
            ["lens":["cameraModel":"camera","lensModel":"lens","geometryPolicy":"allow-native-crop","settings":["distortion":10]]],
            ["basicColor":[["index":1,"name":"red","settings":["hue change":1]],["index":1,"name":"red","settings":["hue change":2]]]],
            ["advancedColor":["mode":"merge","bands":[]]],
            ["advancedColor":["mode":"replace","bands":[["hue change":3]]]]
        ] {
            var bad = policy; bad["version"] = 2; bad["scopes"] = scopes
            XCTAssertThrowsError(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":bad]))
        }
        var wrongVersion = policy; wrongVersion["scopes"] = ["advancedColor":["mode":"replace","bands":[]]]
        XCTAssertThrowsError(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":wrongVersion]))
        XCTAssertThrowsError(try ContractSchema.validate(tool:"edit_status",arguments:["compoundId":"../../oops"]))
        XCTAssertThrowsError(try ContractSchema.validate(tool:"edit_apply",arguments:["recipeId":sha,"sourceRef":"1","ifDocument":"d","ifState":"s","geometry":["rotation":1]]))
        XCTAssertNoThrowBlock {
            let a = try Recipes.digest(["a":1,"b":2]), b = try Recipes.digest(["b":2,"a":1]); XCTAssertEqual(a,b)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = RecipeFake(directory), base = fake.geometry.base
        let core = SessionController(executor:fake,appInstance:{ base.generation },databaseIdentity:{ _ in "db" },imageDimensions:{ _ in [6000,4000] })
        let workflow = RecipeWorkflow(core:core)
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), initial = try core.get(ref:"1")
            let capture = try workflow.run("reference_capture",arguments:["ref":"1","ifDocument":doc.openToken,"ifState":initial.stateHash])
            var recipe = policy; recipe["referenceId"] = capture["referenceId"]
            var settings: [String:Any] = ["clarity amount":5,"film grain type":"silver rich","film grain impact":25,"film grain granularity":30,"vignetting method":"circular","vignetting amount":-0.5]
            for key in Recipes.curveFields { settings[key] = [0,0,50,55,100,100] }
            recipe["settings"] = settings
            let registered = try workflow.run("recipe_register",arguments:["recipe":recipe]), id = registered["recipeId"] as! String
            let request: [String:Any] = ["sourceRef":"1","ifState":initial.stateHash,"ifDocument":doc.openToken,"recipeId":id]
            XCTAssertThrowsError(try workflow.run("edit_apply",arguments:request),"Unverified payload must never dispatch")
            XCTAssertEqual(fake.writes,0)
            XCTAssertThrowsError(try workflow.run("recipe_verify",arguments:["workingRef":"1","ifState":initial.stateHash,"ifDocument":doc.openToken,"recipeId":id]))
            let clone = try core.cloneVariant(sourceRef:"1")
            let verification = try workflow.run("recipe_verify",arguments:["workingRef":clone.workingRef,"ifState":try core.get(ref:clone.workingRef).stateHash,"ifDocument":doc.openToken,"recipeId":id])
            XCTAssertEqual(verification["status"] as? String,"succeeded")
            fake.properties["clarity amount"] = 1
            fake.properties["rgb curve"] = [0.0,0,100,100]
            fake.properties["film grain type"] = "fine"
            let result = try workflow.run("edit_apply",arguments:request)
            XCTAssertEqual(result["status"] as? String,"succeeded")
            XCTAssertNotNil(result["observed"])
            let bundle = result["resultBundle"] as! [String:Any]
            let diff = bundle["diff"] as! [String:[String:Any]]
            let clarity = diff["nativeAdjustments"]!["clarity amount"] as! [String:Any]
            XCTAssertEqual(clarity["before"] as? Double,1)
            XCTAssertEqual(clarity["after"] as? Double,5)
            XCTAssertEqual(clarity["delta"] as? Double,4)
            XCTAssertNotNil(diff["nativeAdjustments"]!["rgb curve"])
            XCTAssertEqual((diff["nativeAdjustments"]!["film grain type"] as! [String:Any])["after"] as? String,"silver rich")
            XCTAssertTrue(diff["adjustments"]!.isEmpty)
            XCTAssertTrue(diff["geometry"]!.isEmpty)
            XCTAssertTrue(bundle["preview"] is NSNull)
            let provenance = bundle["provenance"] as! [String:Any]
            XCTAssertEqual(provenance["recipeId"] as? String,id)
            XCTAssertEqual(provenance["referenceId"] as? String,capture["referenceId"] as? String)
            XCTAssertEqual(provenance["nativeVariantId"] as? String,"1")
            XCTAssertEqual((provenance["verification"] as? [String:Any])?["compoundId"] as? String,verification["compoundId"] as? String)
            let savedStatus = try workflow.run("edit_status",arguments:["compoundId":result["compoundId"]!])
            let returnedHash = try Recipes.digest(bundle), savedHash = try Recipes.digest(savedStatus["resultBundle"]!)
            XCTAssertEqual(returnedHash,savedHash)
            let verifiedBundle = verification["resultBundle"] as! [String:Any]
            XCTAssertNotNil(verifiedBundle["preview"] as? [String:Any])
            XCTAssertTrue((verifiedBundle["provenance"] as! [String:Any])["verification"] is NSNull)
            let compound = result["compoundId"] as! String
            let child = try OperationJournal(sessionDirectory:directory).validatedEntries().filter { $0.compoundId == compound }
            XCTAssertEqual(child.count,1)
            XCTAssertEqual(child.first?.status,"succeeded")
            XCTAssertEqual(((provenance["operations"] as? [[String:Any]])?.first)?["operationId"] as? String,child.first?.operationId)
            // An independent oracle disagreement must never qualify a payload.
            var other = recipe; other["settings"] = ["clarity amount":6]
            let otherID = try workflow.run("recipe_register",arguments:["recipe":other])["recipeId"] as! String
            let otherClone = try core.cloneVariant(sourceRef:"1")
            fake.corruptOracle = true
            let rejected = try workflow.run("recipe_verify",arguments:["recipeId":otherID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken])
            XCTAssertEqual(rejected["status"] as? String,"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(".c1/verified-recipes/" + otherID + ".json").path))
            for key in ["rgb curve","film grain type","vignetting amount"] {
                fake.corruptField = key
                fake.corruptAfterWrites = fake.writes
                let rejected = try workflow.run("recipe_verify",arguments:["recipeId":otherID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken])
                XCTAssertEqual(rejected["status"] as? String,"failed","Omitted typed fields must be independently preserved")
                XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(".c1/verified-recipes/" + otherID + ".json").path))
            }
            fake.corruptOracle = false
            // Scoped recipes explicitly replace advanced bands and preserve unrelated basic bands.
            var scopedRecipe = recipe
            scopedRecipe["version"] = 2
            let band: [String:Any] = ["enabled":true,"red":30000,"green":20000,"blue":10000,"hue start":10,"hue end":30,"saturation start":10,"saturation end":90,"smoothness":20,"hue change":2,"saturation change":3,"lightness change":4]
            scopedRecipe["scopes"] = ["basicColor":[["index":2,"name":"band-2","settings":["hue change":3]]],"advancedColor":["mode":"replace","bands":[band]]]
            let scopedID = try workflow.run("recipe_register",arguments:["recipe":scopedRecipe])["recipeId"] as! String
            let scopedVerification = try workflow.run("recipe_verify",arguments:["recipeId":scopedID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken])
            XCTAssertEqual(scopedVerification["status"] as? String,"succeeded")
            XCTAssertEqual(fake.advanced.count,1)
            XCTAssertEqual(fake.basic[0]["hue change"] as? Double,0)
            XCTAssertEqual(fake.basic[1]["hue change"] as? Double,3)
            let applied = try workflow.run("edit_apply",arguments:["sourceRef":"1","recipeId":scopedID,"ifState":initial.stateHash,"ifDocument":doc.openToken])
            XCTAssertEqual(applied["status"] as? String,"succeeded")
            XCTAssertTrue((applied["plan"] as! [String]).contains("scope-advanced-delete-1"))
            XCTAssertNotNil((applied["resultBundle"] as! [String:Any])["scopedNative"])
            fake.corruptScope = true; fake.corruptAfterWrites = fake.writes
            let drifted = try workflow.run("recipe_verify",arguments:["recipeId":scopedID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken])
            XCTAssertEqual(drifted["status"] as? String,"failed")
            XCTAssertNil(drifted["resultBundle"])
            XCTAssertNotNil(drifted["scopedObserved"],"Failed verification must retain the observed scoped evidence")
            fake.corruptScope = false
            // An incompatible camera is rejected before dispatch.
            scopedRecipe["scopes"] = ["camera":["cameraModel":"wrong-camera","settings":["film curve":"Auto"]]]
            let wrongID = try workflow.run("recipe_register",arguments:["recipe":scopedRecipe])["recipeId"] as! String
            let writesBeforeMismatch = fake.writes
            XCTAssertThrowsError(try workflow.run("recipe_verify",arguments:["recipeId":wrongID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken]))
            XCTAssertEqual(fake.writes,writesBeforeMismatch)
            // Corrupt verified evidence must fail before mutation.
            let evidence = directory.appendingPathComponent(".c1/verified-recipes/" + id + ".json")
            let saved = try Data(contentsOf:evidence)
            try Data("{}".utf8).write(to:evidence)
            let count = fake.writes
            XCTAssertThrowsError(try workflow.run("edit_apply",arguments:request))
            XCTAssertEqual(fake.writes,count)
            try saved.write(to:evidence)
            // Simulated lost reply stops before optional tonal and preview steps.
            fake.fault = "native"
            var failRequest = request; failRequest["exposure"] = ["mode":"absolute","value":0.3]; failRequest["preview"] = true
            let failed = try workflow.run("edit_apply",arguments:failRequest)
            XCTAssertEqual(failed["status"] as? String,"outcome-unknown")
            XCTAssertNil(failed["resultBundle"],"Unknown outcomes must not have a final result bundle")
            XCTAssertEqual(failed["unattempted"] as? [String],["tonal","preview","observe"])
            XCTAssertEqual(base.values["1"]![0],0)
            XCTAssertThrowsError(try workflow.run("edit_apply",arguments:request))
            // An interrupted durable parent exposes exactly its linked children.
            let failedID = failed["compoundId"] as! String
            var interrupted = failed; interrupted["status"] = "running"
            try JSONSerialization.data(withJSONObject:interrupted).write(to:directory.appendingPathComponent(".c1/compounds/" + failedID + ".json"))
            let status = try workflow.run("edit_status",arguments:["compoundId":failedID])
            XCTAssertEqual(status["status"] as? String,"interrupted")
            XCTAssertNil(status["resultBundle"])
            XCTAssertEqual((status["childOperations"] as? [[String:Any]])?.count,1)
        }
        scopeFault(ignoreDelete:false)
        scopeFault(ignoreDelete:true)
    }
    static func scopeFault(ignoreDelete: Bool) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = RecipeFake(directory), base = fake.geometry.base
        let core = SessionController(executor:fake,appInstance:{ base.generation },databaseIdentity:{ _ in "db" },imageDimensions:{ _ in [6000,4000] })
        let workflow = RecipeWorkflow(core:core)
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), source = try core.get(ref:"1")
            let reference = try workflow.run("reference_capture",arguments:["ref":"1","ifDocument":doc.openToken,"ifState":source.stateHash])
            let band = Dictionary(uniqueKeysWithValues:NativeEditing.fields["advancedColor"]!.map { ($0.name,$0.type == "boolean" ? true as Any : 0.0 as Any) })
            let recipe: [String:Any] = ["version":2,"referenceId":reference["referenceId"]!,"settings":["clarity amount":5],"exposure":["mode":"preserve"],"whiteBalance":["mode":"preserve"],"cropPolicy":"preserve","scopes":["advancedColor":["mode":"replace","bands":[band]]]]
            let id = try workflow.run("recipe_register",arguments:["recipe":recipe])["recipeId"]!
            let clone = try core.cloneVariant(sourceRef:"1")
            let checked = try workflow.run("recipe_verify",arguments:["recipeId":id,"workingRef":clone.workingRef,"ifDocument":doc.openToken,"ifState":try core.get(ref:clone.workingRef).stateHash])
            XCTAssertEqual(checked["status"] as? String,"succeeded")
            if ignoreDelete { fake.ignoreDelete = true } else { fake.fault = "native-action" }
            let failed = try workflow.run("edit_apply",arguments:["recipeId":id,"sourceRef":"1","ifDocument":doc.openToken,"ifState":source.stateHash,"preview":true])
            XCTAssertEqual(failed["status"] as? String,"outcome-unknown")
            XCTAssertEqual(failed["activeStep"] as? String,"scope-advanced-delete-1")
            XCTAssertNil(failed["resultBundle"])
            XCTAssertEqual((failed["completed"] as! [[String:Any]]).count,1)
            let linked = try OperationJournal(sessionDirectory:directory).validatedEntries().filter { $0.compoundId == failed["compoundId"] as? String }
            XCTAssertEqual(linked.count,1)
            XCTAssertEqual(linked.first?.nativeAction,"color.delete")
            XCTAssertNotNil(linked.first?.beforeNative)
        }
    }

}
