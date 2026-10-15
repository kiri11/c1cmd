import Foundation
import CaptureOneCore

struct RequestDispatcherTests {
    static func run() {
        print("Running RequestDispatcherTests...")
        XCTAssertThrowsError(try ToolRequest(tool: "native_get", arguments: [:]))
        XCTAssertThrowsError(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exposure": 9]))
        XCTAssertNoThrow(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1]))
        XCTAssertNoThrow(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "adjustments": ["exp": 1]]))
        // Stored variantUUIDs are rejected before any Apple Event; native IDs and c1 references pass.
        let storedUUID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        for (tool, arguments) in [("get", ["ref": storedUUID]), ("get", ["ref": storedUUID.lowercased(), "live": true]),
                                  ("variants_list", ["ids": ["12", storedUUID]]), ("dump", ["ids": ["12", storedUUID]])] as [(String, [String: Any])] {
            XCTAssertThrowsError(try ToolRequest(tool: tool, arguments: arguments, profile: .standard)) { error in
                XCTAssertEqual((error as? C1Error)?.errorCode, "invalid-request")
                XCTAssertTrue("\(error)".contains("variantDatabaseID"), "\(error)")
            }
        }
        for ref in ["12", "c1_edit_" + storedUUID.lowercased(), "c1_wrk_" + storedUUID.lowercased()] {
            XCTAssertNoThrow(try ToolRequest(tool: "get", arguments: ["ref": ref], profile: .standard))
        }
        for tool in ContractSchema.names {
            XCTAssertEqual(ToolRequest.localTools.contains(tool), tool == "request_status" || tool.hasPrefix("catalog_"))
        }
        let quiet = try? ToolRequest(tool: "preview", arguments: ["ref": "x", "inlineImage": false], profile: .standard)
        XCTAssertEqual(quiet?.inlineImage, false)
        XCTAssertNil(quiet?.arguments["inlineImage"])
        XCTAssertEqual(try? ToolRequest(tool: "preview", arguments: ["ref": "x"], profile: .standard).inlineImage, true)
        XCTAssertEqual(try? ToolRequest(tool: "thumb", arguments: ["ref": "x"], profile: .standard).inlineImage, true)
        XCTAssertThrowsError(try ToolRequest(tool: "preview", arguments: ["ref": "x", "inlineImage": "no"], profile: .standard))
        XCTAssertThrowsError(try ToolRequest(tool: "thumb", arguments: ["ref": "x", "inlineImage": false], profile: .standard))
        let sheet = try? ToolRequest(tool: "contact_sheet", arguments: ["minRating": 3, "inlineImage": false], profile: .standard)
        XCTAssertEqual(sheet?.inlineImage, false)
        XCTAssertNil(sheet?.arguments["inlineImage"])
        XCTAssertThrowsError(try ToolRequest(tool: "contact_sheet", arguments: ["inlineImage": "no"], profile: .standard))
        XCTAssertEqual(ContractSchema.names.filter { (ContractSchema.input($0)["properties"] as? [String: Any])?["inlineImage"] != nil }.sorted(),
                       ["contact_sheet", "preview"])
        for arguments: [String: Any] in [["rating": 3, "minRating": 2], ["ids": ["1", "1"]], ["ids": [storedUUID]], ["page": 0],
                                         ["perPage": 0], ["perPage": 49], ["rowHeight": 119], ["rowHeight": 451], ["columns": 5], ["tileSize": 300],
                                         ["deadlineSeconds": 5]] {
            XCTAssertThrowsError(try ToolRequest(tool: "contact_sheet", arguments: arguments, profile: .standard)) { error in
                XCTAssertEqual((error as? C1Error)?.errorCode, "invalid-request", "\(arguments)")
            }
        }
        XCTAssertNoThrow(try ToolRequest(tool: "contact_sheet", arguments: ["ids": ["1", "2"], "collection": "Day 1", "selected": true, "page": 2,
                                                                            "perPage": 48, "rowHeight": 450], profile: .standard))
        let layoutProperties = ContractSchema.input("contact_sheet")["properties"] as! [String: [String: Any]]
        XCTAssertEqual([layoutProperties["perPage"]?["minimum"], layoutProperties["perPage"]?["maximum"],
                        layoutProperties["rowHeight"]?["minimum"], layoutProperties["rowHeight"]?["maximum"]] as? [Int],
                       [SheetLayout.perPageRange.lowerBound, SheetLayout.perPageRange.upperBound,
                        SheetLayout.rowHeightRange.lowerBound, SheetLayout.rowHeightRange.upperBound])

        // Every schema tool is registered with a description; only the profile removes tools.
        XCTAssertEqual(ToolProfile.standard.tools.map(\.name), ContractSchema.names)
        XCTAssertTrue(ToolProfile.standard.tools.allSatisfy { !$0.description.isEmpty })
        // Slow inventory names its escape routes before a client request timeout swallows the call.
        for tool in ToolProfile.standard.tools where ["variants_list", "dump"].contains(tool.name) {
            XCTAssertTrue(tool.description.contains("deadlineSeconds"), tool.name)
            XCTAssertTrue(tool.description.contains("catalog_variants"), tool.name)
        }
        let deadline = (ContractSchema.input("variants_list")["properties"] as! [String: [String: Any]])["deadlineSeconds"]!
        XCTAssertTrue((deadline["description"] as? String ?? "").contains("deadline-exceeded"))
        XCTAssertEqual(ToolProfile.standard.tools.filter(\.destructive).map(\.name).sorted(), ["native_action", "variant_delete"])
        XCTAssertEqual(ToolProfile.standard.tools.filter(\.readOnly).map(\.name).sorted(),
                       ["capabilities", "catalog_collections", "catalog_get", "catalog_inspect", "catalog_variants", "contact_sheet", "diff", "doc_info", "doctor", "dump",
                        "edit_status", "exif", "get", "read_session_status", "request_status", "schema", "thumb", "variants_list"])

        // The composition profile is transport-neutral: ToolRequest enforces it for the CLI and MCP alike.
        let blocked = ["set", "add", "reset", "variant_baseline", "metadata_set", "native_set", "native_action",
                       "reference_capture", "recipe_register", "recipe_verify", "edit_apply"]
        let composition = Set(ToolProfile.composition.tools.map(\.name))
        XCTAssertEqual(Set(ContractSchema.names).subtracting(composition), Set(blocked))
        XCTAssertTrue(composition.isSuperset(of: ["variant_edit", "geometry_set", "geometry_restore", "get", "exif", "thumb", "contact_sheet", "preview", "edit_status"]))
        for tool in blocked {
            XCTAssertThrowsError(try ToolRequest(tool: tool, arguments: [:], profile: .composition)) { error in
                XCTAssertEqual(error as? C1Error, .invalidRequest("Tool is not enabled in the composition profile: \(tool)"))
            }
        }
        XCTAssertNoThrow(try ToolRequest(tool: "geometry_set", arguments: ["workingRef": "x", "ifGeometryState": "h", "rotation": 1],
                                         profile: .composition))
        XCTAssertNoThrow(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1], profile: .standard))
        XCTAssertEqual(try? ToolProfile.configured([:]), .standard)
        XCTAssertEqual(try? ToolProfile.configured(["C1_TOOL_PROFILE": ""]), .standard)
        XCTAssertEqual(try? ToolProfile.configured(["C1_TOOL_PROFILE": "default"]), .standard)
        XCTAssertEqual(try? ToolProfile.configured(["C1_TOOL_PROFILE": "composition"]), .composition)
        XCTAssertEqual(try? ToolProfile.configured(["C1_MCP_PROFILE": "composition"]), .composition)
        XCTAssertEqual(try? ToolProfile.configured(["C1_TOOL_PROFILE": "composition", "C1_MCP_PROFILE": "composition"]), .composition)
        // Typos and conflicts fail closed rather than silently granting every tool.
        XCTAssertThrowsError(try ToolProfile.configured(["C1_TOOL_PROFILE": "Composition"]))
        XCTAssertThrowsError(try ToolProfile.configured(["C1_TOOL_PROFILE": "default", "C1_MCP_PROFILE": "composition"]))

        // Each limit has one definition; the schema, field registry and guards derive from it.
        let requests = ContractSchema.document()["requests"] as! [String: [String: Any]]
        func bounds(_ tool: String, _ key: String) -> [Double] {
            let schema = (requests[tool]!["properties"] as! [String: [String: Any]])[key]!
            return [schema["minimum"], schema["maximum"]].map { ($0 as! NSNumber).doubleValue }
        }
        let rating = VariantMetadata.ratingRange, colorTag = VariantMetadata.colorTagRange
        for (tool, key) in [("metadata_set", "rating"), ("variants_list", "rating"), ("variants_list", "minRating"),
                            ("catalog_variants", "rating"), ("catalog_variants", "minRating")] {
            XCTAssertEqual(bounds(tool, key), [Double(rating.lowerBound), Double(rating.upperBound)])
        }
        XCTAssertEqual(bounds("metadata_set", "colorTag"), [Double(colorTag.lowerBound), Double(colorTag.upperBound)])
        XCTAssertEqual(bounds("geometry_set", "rotation"), [-Geometry.maximumRotation, Geometry.maximumRotation])
        let registry = FieldRegistry.shared
        XCTAssertEqual([registry.findMetadataSpec(named: "rating")!.minValue, registry.findMetadataSpec(named: "rating")!.maxValue],
                       [Double(rating.lowerBound), Double(rating.upperBound)])
        XCTAssertEqual([registry.findMetadataSpec(named: "colorTag")!.minValue, registry.findMetadataSpec(named: "colorTag")!.maxValue],
                       [Double(colorTag.lowerBound), Double(colorTag.upperBound)])
        XCTAssertNil(VariantMetadata.from(Metadata(rating: rating.upperBound + 1, colorTag: 0)))
        XCTAssertNil(VariantMetadata.from(Metadata(rating: 0, colorTag: colorTag.upperBound + 1)))
        XCTAssertThrowsError(try GeometryRequest(crop: nil, rotation: Geometry.maximumRotation + 0.1, aspectRatio: nil))
        XCTAssertNoThrow(try GeometryRequest(crop: nil, rotation: -Geometry.maximumRotation, aspectRatio: nil))
    }
}
