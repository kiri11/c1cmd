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
    }
}
