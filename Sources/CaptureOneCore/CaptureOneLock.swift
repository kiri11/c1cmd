import Foundation

public final class CaptureOneLock {
    public static let shared = CaptureOneLock()

    public let lockPath: String

    public init(lockPath: String = "/private/tmp/c1-application.lock") {
        self.lockPath = lockPath
    }

    public func withLock<T>(timeout: TimeInterval = 5.0, _ body: () throws -> T) throws -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else {
            throw C1Error.captureOneBusy("Unable to open advisory lock file at '\(lockPath)'.")
        }
        defer {
            close(fd)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var acquired = false

        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            usleep(50_000) // 50ms sleep
        }

        guard acquired else {
            throw C1Error.captureOneBusy("Capture One application lock is held by another process; timed out after \(timeout)s waiting for release.")
        }

        defer {
            flock(fd, LOCK_UN)
        }

        return try body()
    }
}
