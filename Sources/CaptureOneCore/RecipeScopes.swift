import Foundation

/// Explicit image-level scopes only. Indexed advanced colors are a replacement
/// list, never an implicit merge with unrelated destination indices.
enum RecipeScopes {
    static let cameraFields = ["color profile", "film curve"]
    static let lensFields = (NativeEditing.fields["lens"] ?? []).map(\.name)
    static let basicFields = ["name", "hue change", "saturation change", "lightness change"]
    static let advancedFields = ["enabled", "red", "green", "blue", "hue start", "hue end", "saturation start", "saturation end", "smoothness", "hue change", "saturation change", "lightness change"]
    static func settings(_ names: [String], required: Bool = false) -> [String:Any] {
        let all = NativeEditing.patchSchema["properties"] as! [String:Any]
        var result = ContractSchema.object(all.filter { names.contains($0.key) },required:required ? names : [])
        result["minProperties"] = 1
        return result
    }
    static var schema: [String:Any] {
        let text: [String:Any] = ["type":"string","minLength":1]
        var result = ContractSchema.object([
            "camera":ContractSchema.object(["cameraModel":text,"settings":settings(cameraFields)],required:["cameraModel","settings"]),
            "lens":ContractSchema.object(["cameraModel":text,"lensModel":text,"geometryPolicy":["type":"string","enum":["preserve-crop","allow-native-crop"]],"settings":settings(lensFields)],required:["cameraModel","lensModel","geometryPolicy","settings"]),
            "basicColor":["type":"array","minItems":1,"maxItems":9,"items":ContractSchema.object([
                "index":["type":"integer","minimum":1,"maximum":9],"name":text,"settings":settings(Array(basicFields.dropFirst()))],required:["index","name","settings"])],
            "advancedColor":ContractSchema.object(["mode":["type":"string","enum":["replace"]],"bands":["type":"array","maxItems":64,"items":settings(advancedFields,required:true)]],required:["mode","bands"])
        ])
        result["minProperties"] = 1
        return result
    }
    static var evidenceSchema: [String:Any] {
        ContractSchema.object([
            "camera":settings(cameraFields,required:true),
            "lens":settings(lensFields,required:true),
            "basicColor":["type":"array","maxItems":9,"items":settings(basicFields,required:true)],
            "advancedColor":["type":"array","maxItems":64,"items":settings(advancedFields,required:true)],
            "observationHash":ContractSchema.string
        ],required:["camera","lens","basicColor","advancedColor","observationHash"])
    }
    static func validate(_ scopes: [String:Any], cropPolicy: String) throws {
        try ContractSchema.validateValue(scopes,schema:schema,path:"scopes")
        for name in ["camera","lens"] {
            guard let config = scopes[name] as? [String:Any] else { continue }
            for key in name == "camera" ? ["cameraModel"] : ["cameraModel","lensModel"] {
                guard let value = config[key] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw C1Error.invalidRequest("Empty scope compatibility identity.") }
            }
            for (field,value) in config["settings"] as! [String:Any] where ["film curve","color profile","lens profile"].contains(field) {
                guard let text = value as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw C1Error.invalidRequest("Profile names must be explicit and nonempty.") }
            }
            try NativeEditing.validate(NativeEditing.parseValues(Recipes.data(config["settings"]!)),target:NativeTarget(scope:name == "camera" ? "adjustments" : "lens"))
            if name == "lens" {
                guard let policy = config["geometryPolicy"] as? String, ["preserve-crop","allow-native-crop"].contains(policy), policy != "allow-native-crop" || cropPolicy == "per-photo" else { throw C1Error.invalidRequest("Native lens crop changes require explicit per-photo crop policy.") }
            }
        }
        if let basic = scopes["basicColor"] as? [[String:Any]], !(1...9).contains(basic.count) { throw C1Error.invalidRequest("Provide 1...9 named basic patches.") }
        var indices = Set<Int>()
        for entry in scopes["basicColor"] as? [[String:Any]] ?? [] {
            guard indices.insert(entry["index"] as! Int).inserted, !(entry["name"] as! String).isEmpty else { throw C1Error.invalidRequest("Basic color indices must be unique and named.") }
            try NativeEditing.validate(NativeEditing.parseValues(Recipes.data(entry["settings"]!)),target:NativeTarget(scope:"basicColor",element:entry["index"] as! Int))
        }
        if let advanced = scopes["advancedColor"] as? [String:Any] {
            guard advanced["mode"] as? String == "replace" else { throw C1Error.invalidRequest("Advanced colors require explicit replace mode.") }
            guard (advanced["bands"] as! [[String:Any]]).count <= 64 else { throw C1Error.invalidRequest("Advanced replacement is limited to 64 bands.") }
            for band in advanced["bands"] as! [[String:Any]] {
                try NativeEditing.validate(NativeEditing.parseValues(Recipes.data(band)),target:NativeTarget(scope:"advancedColor",element:1))
            }
        }
    }

    struct Wire: Decodable {
        let recipeCameraValues: [NativeValue]
        let recipeLensValues: [NativeValue]
        let recipeBasicValues: [[NativeValue]]
        let recipeAdvancedValues: [[NativeValue]]
    }
    struct Observation: Codable, Equatable {
        var camera: [String:NativeValue]
        var lens: [String:NativeValue]
        var basicColor: [[String:NativeValue]]
        var advancedColor: [[String:NativeValue]]
        init(_ wire: Wire) throws {
            func row(_ values: [NativeValue], _ names: [String]) throws -> [String:NativeValue] {
                guard values.count == names.count else { throw C1Error.readbackMismatch("Incomplete independent scoped observation.") }
                return Dictionary(uniqueKeysWithValues:zip(names,values))
            }
            guard wire.recipeBasicValues.count <= 9, wire.recipeAdvancedValues.count <= 64 else { throw C1Error.invalidRequest("Scoped recipes support at most 9 basic and 64 advanced bands.") }
            guard lensFields.count == 16 else { throw C1Error.invalidRequest("Scoped native schema unavailable.") }
            camera = try row(wire.recipeCameraValues,cameraFields)
            lens = try row(wire.recipeLensValues,lensFields)
            basicColor = try wire.recipeBasicValues.map { try row($0,basicFields) }
            advancedColor = try wire.recipeAdvancedValues.map { try row($0,advancedFields) }
            try NativeEditing.validate(camera,target:NativeTarget())
            try NativeEditing.validate(lens,target:NativeTarget(scope:"lens"))
            for band in basicColor {
                guard case .text = band["name"] else { throw C1Error.readbackMismatch("Missing basic band identity.") }
                try NativeEditing.validate(band.filter { $0.key != "name" },target:NativeTarget(scope:"basicColor",element:1))
            }
            for band in advancedColor { try NativeEditing.validate(band,target:NativeTarget(scope:"advancedColor",element:1)) }
        }
        func evidence() throws -> [String:Any] {
            var value = try Recipes.object(self)
            value["observationHash"] = try Recipes.digest(value)
            return value
        }
        func expected(_ scopes: [String:Any]) throws -> Observation {
            var result = self
            for key in ["camera","lens"] {
                if let config = scopes[key] as? [String:Any] {
                    let patch = try NativeEditing.parseValues(Recipes.data(config["settings"]!))
                    if key == "camera" { result.camera.merge(patch) { _,new in new } }
                    else { result.lens.merge(patch) { _,new in new } }
                }
            }
            for entry in scopes["basicColor"] as? [[String:Any]] ?? [] {
                let index = entry["index"] as! Int - 1
                guard basicColor.indices.contains(index), basicColor[index]["name"] == .text(entry["name"] as! String) else { throw C1Error.stateChanged("Basic color index/name does not match destination.") }
                result.basicColor[index].merge(try NativeEditing.parseValues(Recipes.data(entry["settings"]!))) { _,new in new }
            }
            if let advanced = scopes["advancedColor"] as? [String:Any] {
                result.advancedColor = try (advanced["bands"] as! [[String:Any]]).map { try NativeEditing.parseValues(Recipes.data($0)) }
            }
            return result
        }
        func assertMatches(_ wanted: Observation) throws {
            func equal(_ a: [String:NativeValue], _ b: [String:NativeValue]) -> Bool {
                Set(a.keys) == Set(b.keys) && a.allSatisfy { key,value in b[key].map { NativeEditing.matchesReadback(field:key,expected:$0,actual:value) } ?? false }
            }
            guard equal(camera,wanted.camera), equal(lens,wanted.lens),
                  basicColor.count == wanted.basicColor.count, advancedColor.count == wanted.advancedColor.count,
                  zip(basicColor,wanted.basicColor).allSatisfy(equal), zip(advancedColor,wanted.advancedColor).allSatisfy(equal) else { throw C1Error.readbackMismatch("Independent scoped verification failed, including omitted-field preservation.") }
        }
    }
    static func compatibility(_ scopes: [String:Any], source: GetResult) throws {
        let metadata = (try Recipes.object(source))["metadata"] as? [String:Any] ?? [:]
        for key in ["camera","lens"] {
            guard let config = scopes[key] as? [String:Any] else { continue }
            guard config["cameraModel"] as? String == metadata["camera"] as? String else { throw C1Error.invalidRequest("Recipe camera model differs from destination.") }
            if key == "lens", config["lensModel"] as? String != metadata["lens"] as? String { throw C1Error.invalidRequest("Recipe lens model differs from destination.") }
        }
    }
    struct Step {
        let name: String
        let target: NativeTarget
        let patch: [String:NativeValue]
        let action: String?
    }
    static func steps(_ scopes: [String:Any], before: Observation) throws -> [Step] {
        _ = try before.expected(scopes) // validate indices before any write
        var result: [Step] = []
        for key in ["camera","lens"] {
            if let config = scopes[key] as? [String:Any] {
                result.append(Step(name:"scope-" + key,target:NativeTarget(scope:key == "camera" ? "adjustments" : "lens"),patch:try NativeEditing.parseValues(Recipes.data(config["settings"]!)),action:nil))
            }
        }
        for entry in scopes["basicColor"] as? [[String:Any]] ?? [] {
            let index = entry["index"] as! Int
            result.append(Step(name:"scope-basic-\(index)",target:NativeTarget(scope:"basicColor",element:index),patch:try NativeEditing.parseValues(Recipes.data(entry["settings"]!)),action:nil))
        }
        if let advanced = scopes["advancedColor"] as? [String:Any] {
            for index in before.advancedColor.indices.reversed() {
                result.append(Step(name:"scope-advanced-delete-\(index+1)",target:NativeTarget(scope:"advancedColor",element:index+1),patch:[:],action:"color.delete"))
            }
            for (index,band) in (advanced["bands"] as! [[String:Any]]).enumerated() {
                result.append(Step(name:"scope-advanced-create-\(index+1)",target:NativeTarget(),patch:[:],action:"color.create"))
                result.append(Step(name:"scope-advanced-set-\(index+1)",target:NativeTarget(scope:"advancedColor",element:index+1),patch:try NativeEditing.parseValues(Recipes.data(band)),action:nil))
            }
        }
        return result
    }
}
