import Foundation
import CaptureOneCore

struct LockTests {
    static func run() {
        print("Running LockTests...")
        let lockFile = "/private/tmp/c1-unit-test-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: lockFile) }

        let lock = CaptureOneLock(lockPath: lockFile)
        var executed = false
        XCTAssertNoThrow(try lock.withLock(timeout: 1.0) {
            executed = true
        })
        XCTAssertTrue(executed)

        // Can acquire again after release
        var executedSecond = false
        XCTAssertNoThrow(try lock.withLock(timeout: 1.0) {
            executedSecond = true
        })
        XCTAssertTrue(executedSecond)

        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for file in (try? FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "swift" {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let constructions = source.components(separatedBy: "SessionController" + "(").dropFirst()
            XCTAssertTrue(constructions.allSatisfy { $0.hasPrefix("lock: testLock") } && !source.contains("CaptureOne" + "Lock.shared")
                          && !source.contains("SessionController" + ".shared"),
                          "\(file.lastPathComponent) must build SessionController with `lock: testLock` so it never takes the machine-wide lock")
        }
    }
}
