import Foundation
import CaptureOneCore

struct RequestDispatcherTests {
    static func run() {
        print("Running RequestDispatcherTests...")
        XCTAssertThrowsError(try ToolRequest(tool: "native_get", arguments: [:]))
        XCTAssertThrowsError(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exposure": 9]))
        XCTAssertNoThrow(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1]))
        XCTAssertNoThrow(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "adjustments": ["exp": 1]]))
        for tool in ContractSchema.names {
            XCTAssertEqual(ToolRequest.localTools.contains(tool), tool == "request_status" || tool.hasPrefix("catalog_"))
        }

        // Every schema tool is registered with a description; only the profile removes tools.
        XCTAssertEqual(ToolProfile.standard.tools.map(\.name), ContractSchema.names)
        XCTAssertTrue(ToolProfile.standard.tools.allSatisfy { !$0.description.isEmpty })
        XCTAssertEqual(ToolProfile.standard.tools.filter(\.destructive).map(\.name).sorted(), ["native_action", "variant_delete"])
        XCTAssertEqual(ToolProfile.standard.tools.filter(\.readOnly).map(\.name).sorted(),
                       ["capabilities", "catalog_get", "catalog_inspect", "catalog_variants", "diff", "doc_info", "doctor", "dump",
                        "edit_status", "exif", "get", "read_session_status", "request_status", "schema", "variants_list"])

        // The composition profile is transport-neutral: ToolRequest enforces it for the CLI and MCP alike.
        let blocked = ["set", "add", "reset", "variant_baseline", "metadata_set", "native_set", "native_action",
                       "reference_capture", "recipe_register", "recipe_verify", "edit_apply"]
        let composition = Set(ToolProfile.composition.tools.map(\.name))
        XCTAssertEqual(Set(ContractSchema.names).subtracting(composition), Set(blocked))
        XCTAssertTrue(composition.isSuperset(of: ["variant_edit", "geometry_set", "geometry_restore", "get", "preview", "edit_status"]))
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
