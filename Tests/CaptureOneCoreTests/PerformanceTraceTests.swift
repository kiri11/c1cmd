import Foundation
import CaptureOneCore

/// Runs `body` with C1_PROFILE set as given and returns everything it wrote to stderr.
func captureStandardError(profile: Bool, _ body: () -> Void) -> Data {
    let previous = getenv("C1_PROFILE").map { String(cString: $0) }
    if profile { setenv("C1_PROFILE", "1", 1) } else { unsetenv("C1_PROFILE") }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: file)
    let saved = dup(STDERR_FILENO)
    dup2(handle.fileDescriptor, STDERR_FILENO)
    defer {
        dup2(saved, STDERR_FILENO); close(saved); try? handle.close()
        try? FileManager.default.removeItem(at: file)
        if let previous { setenv("C1_PROFILE", previous, 1) } else { unsetenv("C1_PROFILE") }
    }
    body()
    return (try? Data(contentsOf: file)) ?? Data()
}

func profileRecords(_ body: () -> Void) -> [[String: Any]] {
    captureStandardError(profile: true, body).split(separator: 10).compactMap {
        try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
    }.filter { $0["type"] as? String == "c1-profile" }
}

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

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OperationJournal(sessionDirectory: directory)
        func exercise() throws {
            try PerformanceTrace.step("geometry") {
                _ = PerformanceTrace.measure("handler_total", handler: "getAdjustmentsBatch") { 0 }
                try journal.append(entry: OperationRecord(operationType: "probe", workingRef: nil, documentPath: directory.path))
            }
            _ = try? PerformanceTrace.step("tonal") { throw ProbeError.expected }
            _ = ImageDimensions.read(directory.appendingPathComponent("missing.cr3").path)
        }

        let silent = captureStandardError(profile: false) { XCTAssertNoThrowBlock { try exercise() } }
        XCTAssertTrue(silent.isEmpty, "Without C1_PROFILE, stderr must stay empty")

        let records = profileRecords { XCTAssertNoThrowBlock { try exercise() } }
        let shape = records.map { [$0["phase"] as? String ?? "", $0["handler"] as? String ?? "", $0["step"] as? String ?? "-"] }
        XCTAssertEqual(shape, [
            ["handler_total", "getAdjustmentsBatch", "geometry"],
            ["journal_read", "OperationJournal.validatedEntries", "geometry"],
            ["journal_fsync", "OperationJournal.append", "geometry"],
            ["step", "geometry", "-"],
            ["step", "tonal", "-"],
            ["image_dimensions", "ImageDimensions.read", "-"],
        ], "Records inside a step carry its label; a step and later records do not")
        XCTAssertEqual(records.map { $0["succeeded"] as? Bool }, [true, true, true, true, false, true])
        let line = String(decoding: captureStandardError(profile: true) { XCTAssertNoThrowBlock { try exercise() } }, as: UTF8.self)
        XCTAssertFalse(line.contains(directory.path), "Records must not include paths")
    }
}
