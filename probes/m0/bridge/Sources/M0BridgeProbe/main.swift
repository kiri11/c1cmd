import Foundation
import AppleScriptBridge

struct Nested: Codable, Equatable { let kelvinVal: Double; let tintVal: Double? }
struct Payload: Codable, Equatable { let nestedVal: Nested; let valuesVal: [Double?] }
let script = NSAppleScript(source: "return {nestedVal:{kelvinVal:5400.0, tintVal:missing value}, valuesVal:{1.25, missing value, 3.5}}")!
var error: NSDictionary?
let descriptor = script.executeAndReturnError(&error)
if let error { fatalError("AppleScript error: \(error)") }
var report: [String: Any] = ["revision": "58946d7fd5b38b6a92c13ccb413d30ba1f0e9179", "descriptor": descriptor.description]
let decoder = DescriptorDecoder()
let expected = Payload(nestedVal: Nested(kelvinVal: 5400, tintVal: nil), valuesVal: [1.25, nil, 3.5])
do {
    let decoded = try decoder.decode(Payload.self, from: descriptor)
    report["appleScriptNestedAndArrayPass"] = decoded == expected
    report["decoded"] = String(describing: decoded)
} catch { report["appleScriptError"] = String(describing: error) }
for strategy in [DescriptorEncoder.NilEncodingStrategy.null, .missingValue] {
    do {
        let encoder = DescriptorEncoder()
        encoder.nilEncoding = strategy
        let encoded = try encoder.encode(expected)
        let roundtrip = try decoder.decode(Payload.self, from: encoded)
        report["roundtrip_\(strategy)"] = roundtrip == expected
    } catch { report["roundtripError_\(strategy)"] = String(describing: error) }
}
let appScript = NSAppleScript(source: "tell application id \"com.captureone.captureone16\" to return version")!
error = nil
let appResult = appScript.executeAndReturnError(&error)
report["appVersion"] = appResult.stringValue ?? "unavailable"
if let error { report["automationError"] = error.description }
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
