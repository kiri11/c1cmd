import Foundation
import CaptureOneCore

struct ResultCompactionTests {
    static func run() {
        print("Running ResultCompactionTests...")
        let schema = ContractSchema.document()
        let compactSchemas = schema["compactResponses"] as! [String: [String: Any]]
        XCTAssertEqual(Set(compactSchemas.keys), ResultCompaction.tools)
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("c1-compact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: document) }
        func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }

        /// Compacts through the public seam and checks the summary against its published schema
        /// and the evidence file against the complete result.
        func compacted(_ tool: String, _ response: ToolResponse) -> [String: Any]? {
            guard case .compact(let summary, let complete) = ResultCompaction.compact(response, tool: tool, documentPath: document.path) else { return nil }
            let properties = compactSchemas[tool]!["properties"] as! [String: Any]
            XCTAssertTrue(Set(summary.keys).isSubset(of: Set(properties.keys)), "\(tool) summary has unpublished fields: \(summary.keys.sorted())")
            XCTAssertTrue(Set(compactSchemas[tool]!["required"] as! [String]).isSubset(of: Set(summary.keys)), "\(tool) summary lacks required fields")
            let path = summary["evidencePath"] as! String
            XCTAssertTrue(path.hasPrefix(document.appendingPathComponent(".c1/results").path), path)
            let evidence = try? String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(NSDictionary(dictionary: json(evidence ?? "{}")).isEqual(to: json(complete.json)), "\(tool) evidence differs from the complete result")
            XCTAssertTrue(NSDictionary(dictionary: json(ToolResponse.compact(summary, complete: complete).json)).isEqual(to: summary))
            return summary
        }

        // Tonal mutation: the new state token and changed fields stay; full before/after move to evidence.
        let mutation = try! JSONDecoder().decode(MutationResult.self, from: Data("""
            {"operationId":"op1","workingRef":"c1_edit_a","before":{"exposure":0,"contrast":0,"saturation":0,"temperature":5000,"tint":0},
             "after":{"exposure":0.5,"contrast":0,"saturation":0,"temperature":5000,"tint":0},
             "diff":{"exposure":{"before":0,"after":0.5,"delta":0.5}},"stateHash":"h2","isDryRun":false}
            """.utf8))
        let tonal = compacted("set", .mutation(mutation))
        XCTAssertEqual(tonal?.keys.sorted(), ["diff", "evidencePath", "isDryRun", "operationId", "stateHash", "workingRef"])
        XCTAssertEqual(tonal?["stateHash"] as? String, "h2")

        // Native mutation: only changed values are listed; unavailable fields are never dropped.
        let native: [String: Any] = ["operationId": "op2", "dryRun": false,
            "before": ["target": ["scope": "adjustments"], "values": ["clarity amount": 0, "brightness": 3], "unavailable": ["hue": "missing"],
                       "layers": [], "basicColorCount": 0, "advancedColorCount": 0, "nativeStateHash": "n1"],
            "after": ["target": ["scope": "adjustments"], "values": ["clarity amount": 5, "brightness": 3], "unavailable": ["hue": "missing"],
                      "layers": [], "basicColorCount": 0, "advancedColorCount": 0, "nativeStateHash": "n2"]]
        let nativeSummary = compacted("native_set", .object(native))
        XCTAssertEqual(nativeSummary?["nativeStateHash"] as? String, "n2")
        XCTAssertEqual((nativeSummary?["diff"] as? [String: Any]).map { $0.keys.sorted() }, ["values.clarity amount"])
        XCTAssertEqual(nativeSummary?["unavailable"] as? [String: String], ["hue": "missing"])

        // Preview: the path and tokens stay; geometry moves to evidence.
        let preview = PreviewResult(operationId: "op3", workingRef: "c1_edit_a", outputPath: "/x/p.jpg", fileSizeBytes: 10, width: 3, height: 2,
                                    pixelSha256: "s", stateHash: "h2", geometryStateHash: "g2")
        let previewSummary = compacted("preview", .preview(preview))
        XCTAssertEqual(previewSummary?["outputPath"] as? String, "/x/p.jpg")
        XCTAssertNil(previewSummary?["pixelSha256"])
        if case .preview = ResultCompaction.compact(.preview(preview), tool: "preview", documentPath: document.path).complete {} else { XCTFail("complete lost the preview") }

        // Succeeded compound edit: IDs, changes, coverage, final tokens and preview path stay.
        let coverage: [String: Any] = ["geometry": "compared", "nativeTarget": NSNull(), "nativeComparedFields": ["brightness"], "nativeNotComparedFields": ["hue"],
            "nativeUnavailableBefore": [:], "nativeUnavailableAfter": ["hue": "missing"], "maskPixels": "unsupported", "layerSettings": "not-compared",
            "colorEditorElements": "not-compared", "nativeLensAndVariantSettings": "not-compared", "atomicSnapshot": false]
        let bundle: [String: Any] = ["version": 1, "observed": [:], "preview": ["outputPath": "/x/c.jpg"], "coverage": coverage,
            "diff": ["adjustments": ["exposure": ["before": 0, "after": 1, "beforePresent": true, "afterPresent": true, "delta": 1]],
                     "geometry": [:], "metadata": [:], "nativeAdjustments": [:]],
            "provenance": ["workingRef": "c1_edit_b", "operations": [["step": "native", "operationId": "op4"]],
                           "finalHashes": ["stateHash": "h3", "native": []]]]
        let report: [String: Any] = ["compoundId": "c1", "recipeId": "r1", "status": "succeeded", "plan": ["native"], "completed": [], "resultBundle": bundle]
        let compound = compacted("edit_apply", .compound(report))
        XCTAssertEqual(compound?["previewPath"] as? String, "/x/c.jpg")
        XCTAssertEqual((compound?["coverage"] as? [String: Any])?["nativeNotComparedFields"] as? [String], ["hue"])
        XCTAssertEqual((compound?["operations"] as? [[String: String]])?.first?["operationId"], "op4")

        // Unfinished compound edits and results without writable evidence are returned complete.
        let before = (try? FileManager.default.contentsOfDirectory(atPath: document.appendingPathComponent(".c1/results").path))?.count
        for status in ["failed", "outcome-unknown", "interrupted", "running"] {
            var unfinished = report; unfinished["status"] = status
            if case .compact = ResultCompaction.compact(.compound(unfinished), tool: "edit_apply", documentPath: document.path) { XCTFail("\(status) compound was compacted") }
            XCTAssertEqual(ResultCompaction.compact(.compound(unfinished), tool: "edit_status", documentPath: document.path).reportsFailure, status != "running")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: document.appendingPathComponent(".c1/results").path))?.count, before)
        if case .compact = ResultCompaction.compact(.mutation(mutation), tool: "set", documentPath: nil) { XCTFail("compacted without a document") }
        if case .compact = ResultCompaction.compact(.mutation(mutation), tool: "set", documentPath: "/dev/null/document") { XCTFail("compacted without evidence") }

        // `full` is a presentation option: accepted only where results compact, and never passed to the command.
        let request = try? ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1, "full": true], profile: .standard)
        XCTAssertEqual(request?.full, true)
        XCTAssertNil(request?.arguments["full"])
        XCTAssertEqual(try? ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1], profile: .standard).full, false)
        XCTAssertThrowsError(try ToolRequest(tool: "set", arguments: ["workingRef": "x", "ifState": "h", "exp": 1, "full": "yes"], profile: .standard))
        XCTAssertThrowsError(try ToolRequest(tool: "get", arguments: ["ref": "x", "full": true], profile: .standard))
        XCTAssertNoThrow(try ToolRequest(tool: "edit_status", arguments: ["compoundId": String(repeating: "a", count: 64), "full": false], profile: .standard))
        let requests = schema["requests"] as! [String: [String: Any]]
        for (tool, request) in requests {
            XCTAssertEqual((request["properties"] as! [String: Any])["full"] != nil, ResultCompaction.tools.contains(tool), tool)
        }
        let applyGeometry = (requests["edit_apply"]!["properties"] as! [String: [String: Any]])["geometry"]!["properties"] as! [String: Any]
        XCTAssertNil(applyGeometry["full"])
    }
}
