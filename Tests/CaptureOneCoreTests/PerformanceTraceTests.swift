import Foundation
import CaptureOneCore

struct PerformanceTraceTests {
    private enum ProbeError: Error { case expected }
    static func run() {
        var calls = 0
        let result = PerformanceTrace.measure("test_success", handler: "offline") {
            calls += 1
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, 1, "Profiling must not repeat work")
        do {
            try PerformanceTrace.measure("test_failure", handler: "offline") {
                calls += 1
                throw ProbeError.expected
            }
            XCTFail("Expected original error")
        } catch ProbeError.expected {
            XCTAssertEqual(calls, 2, "Profiling must not retry failures")
        } catch { XCTFail("Profiling replaced original error") }
    }
}
