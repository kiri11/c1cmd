import Foundation
import CaptureOneCore

private final class RecipeFake: ScriptExecuting {
    let geometry: GeometryFake
    var properties: [String:Double] = [:]
    var fault: String?
    var corruptOracle = false
    var writes = 0
    init(_ directory: URL) { geometry = GeometryFake(directory:directory) }
    var fields: [String] { ["exposure","temperature","tint"] + Recipes.fields }
    func values(_ id: String) -> [String:Double] {
        var v = Dictionary(uniqueKeysWithValues:fields.map { ($0,properties[$0] ?? 0) })
        let a = geometry.base.values[id]!
        v["exposure"] = a[0]; v["contrast"] = a[1]; v["saturation"] = a[2]; v["temperature"] = a[3]; v["tint"] = a[4]
        return v
    }
    func executeAndDecode<T:Decodable>(handler: String,args: [NSAppleEventDescriptor]) throws -> T {
        let result: Any
        if handler == "nativeRead" {
            let v = values(args[1].stringValue!)
            result = ["nativeRows":v.keys.sorted().map { ["fieldName":$0,"numbersVal":[v[$0]!]] as [String:Any] },"nativeLayers":[],"basicColorCount":0,"advancedColorCount":0] as [String:Any]
        } else if handler == "nativeRecipeOracle" {
            var v = values(args[1].stringValue!)
            if corruptOracle, writes > 0 { v["clarity amount"]! += 1 }
            result = fields.map { v[$0]! }
        } else if handler == "nativeApply" {
            writes += 1
            if fault == "native" { throw C1Error.timeout("recipe injected timeout") }
            let id = args[1].stringValue!
            for i in 1...args[9].numberOfItems {
                let key = args[9].atIndex(i)!.stringValue!, value = args[10].atIndex(i)!.doubleValue
                properties[key] = value
                if let index = ["exposure","contrast","saturation","temperature","tint"].firstIndex(of:key) { geometry.base.values[id]![index] = value }
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
        for (key,value) in [("version",2 as Any),("cropPolicy","magic"),("settings",["film curve":"Auto"]),("exposure",["mode":"absolute"]),("whiteBalance",["mode":"absolute","temperature":5000])] {
            var bad = policy; bad[key] = value
            XCTAssertThrowsError(try ContractSchema.validate(tool:"recipe_register",arguments:["recipe":bad]))
        }
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
            let registered = try workflow.run("recipe_register",arguments:["recipe":recipe]), id = registered["recipeId"] as! String
            let request: [String:Any] = ["sourceRef":"1","ifState":initial.stateHash,"ifDocument":doc.openToken,"recipeId":id]
            XCTAssertThrowsError(try workflow.run("edit_apply",arguments:request),"Unverified payload must never dispatch")
            XCTAssertEqual(fake.writes,0)
            XCTAssertThrowsError(try workflow.run("recipe_verify",arguments:["workingRef":"1","ifState":initial.stateHash,"ifDocument":doc.openToken,"recipeId":id]))
            let clone = try core.cloneVariant(sourceRef:"1")
            let verification = try workflow.run("recipe_verify",arguments:["workingRef":clone.workingRef,"ifState":try core.get(ref:clone.workingRef).stateHash,"ifDocument":doc.openToken,"recipeId":id])
            XCTAssertEqual(verification["status"] as? String,"succeeded")
            let result = try workflow.run("edit_apply",arguments:request)
            XCTAssertEqual(result["status"] as? String,"succeeded")
            XCTAssertNotNil(result["observed"])
            let compound = result["compoundId"] as! String
            let child = try OperationJournal(sessionDirectory:directory).validatedEntries().filter { $0.compoundId == compound }
            XCTAssertEqual(child.count,1)
            XCTAssertEqual(child.first?.status,"succeeded")
            // An independent oracle disagreement must never qualify a payload.
            var other = recipe; other["settings"] = ["clarity amount":6]
            let otherID = try workflow.run("recipe_register",arguments:["recipe":other])["recipeId"] as! String
            let otherClone = try core.cloneVariant(sourceRef:"1")
            fake.corruptOracle = true
            let rejected = try workflow.run("recipe_verify",arguments:["recipeId":otherID,"workingRef":otherClone.workingRef,"ifState":try core.get(ref:otherClone.workingRef).stateHash,"ifDocument":doc.openToken])
            XCTAssertEqual(rejected["status"] as? String,"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(".c1/verified-recipes/" + otherID + ".json").path))
            fake.corruptOracle = false
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
            XCTAssertEqual(failed["unattempted"] as? [String],["tonal","preview","observe"])
            XCTAssertEqual(base.values["1"]![0],0)
            XCTAssertThrowsError(try workflow.run("edit_apply",arguments:request))
            // An interrupted durable parent exposes exactly its linked children.
            let failedID = failed["compoundId"] as! String
            var interrupted = failed; interrupted["status"] = "running"
            try JSONSerialization.data(withJSONObject:interrupted).write(to:directory.appendingPathComponent(".c1/compounds/" + failedID + ".json"))
            let status = try workflow.run("edit_status",arguments:["compoundId":failedID])
            XCTAssertEqual(status["status"] as? String,"interrupted")
            XCTAssertEqual((status["childOperations"] as? [[String:Any]])?.count,1)
        }
    }
}
