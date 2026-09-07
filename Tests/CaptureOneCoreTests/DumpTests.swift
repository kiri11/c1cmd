import Foundation
import CaptureOneCore

public struct DumpTests {
    public static func run() {
        print("Running DumpTests...")

        let record = DumpRecord(
            id: "10",
            name: "TestVariant",
            workingRef: nil,
            adjustments: Adjustments(exposure: 0.1, contrast: 5.0, saturation: 10.0, temperature: 5600.0, tint: 2.0),
            metadata: Metadata(camera: "Canon EOS R5", lens: "RF 50mm", iso: "100", shutterSpeed: "1/200", asShotWB: "Shot", captureDate: "2026-01-01", rating: 4, colorTag: 1),
            stateHash: "abc123statehash"
        )

        // 1. JSON encoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record),
              let jsonStr = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to encode DumpRecord to JSON")
            return
        }

        XCTAssertTrue(jsonStr.contains("\"id\":\"10\""), "JSON should contain id")
        XCTAssertTrue(jsonStr.contains("\"name\":\"TestVariant\""), "JSON should contain name")
        XCTAssertTrue(jsonStr.contains("\"stateHash\":\"abc123statehash\""), "JSON should contain stateHash")
        XCTAssertTrue(jsonStr.contains("\"exposure\":0.1"), "JSON should contain exposure")
        XCTAssertTrue(jsonStr.contains("\"camera\":\"Canon EOS R5\""), "JSON should contain camera metadata")

        // 2. JSON Decoding roundtrip
        guard let decoded = try? JSONDecoder().decode(DumpRecord.self, from: data) else {
            XCTFail("Failed to decode DumpRecord from JSON")
            return
        }
        XCTAssertEqual(decoded.id, "10", "Decoded ID")
        XCTAssertEqual(decoded.name, "TestVariant", "Decoded name")
        XCTAssertEqual(decoded.adjustments.exposure, 0.1, "Decoded exposure")
        XCTAssertEqual(decoded.metadata.camera, "Canon EOS R5", "Decoded camera")

        // 3. OutputFormatter.renderDump JSONL
        let jsonlOutput = OutputFormatter.renderDump([record], format: .json, jsonl: true)
        let lines = jsonlOutput.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "Should render 1 line of JSONL")
        XCTAssertTrue(lines[0].contains("\"id\":\"10\""), "JSONL line contains id")

        // 4. OutputFormatter.renderDump Human
        let humanOutput = OutputFormatter.renderDump([record], format: .human, jsonl: false)
        XCTAssertTrue(humanOutput.contains("TestVariant"), "Human output contains variant name")
        XCTAssertTrue(humanOutput.contains("Total variants dumped: 1"), "Human output contains total summary count")
    }
}
