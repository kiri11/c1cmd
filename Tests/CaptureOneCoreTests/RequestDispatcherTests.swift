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
