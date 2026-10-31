import Foundation

/// A first-in, first-out queue for Capture One shared by every c1 process and thread.
///
/// Each caller draws a sequence number from a counter file and creates a ticket file named after it,
/// holding an exclusive `flock` on the ticket while it waits and runs. It runs once no lower ticket
/// remains. The kernel drops a dead caller's lock, so a lower ticket whose lock can be taken is
/// removed. `flock` locks belong to open file descriptions, so threads of one process exclude each
/// other as separate processes do.
public final class CaptureOneQueue {
    public let directory: URL
    /// Callers in the queue at once, including the one running: 8 waiting plus 1.
    public let capacity: Int
    public let maxWait: TimeInterval
    let pollInterval: TimeInterval

    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("c1-queue")
    }

    public init(directory: URL = defaultDirectory, capacity: Int = 9, maxWait: TimeInterval = 600, pollInterval: TimeInterval = 0.02) {
        self.directory = directory; self.capacity = capacity; self.maxWait = maxWait; self.pollInterval = pollInterval
    }

    public func run<T>(_ body: () throws -> T) throws -> T {
        let ticket = try take()
        defer { release(ticket) }
        try wait(for: ticket)
        return try body()
    }

    struct Ticket { let number: Int64; let fd: Int32; let path: String }

    private func take() throws -> Ticket {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counterPath = directory.appendingPathComponent("counter").path
        let counter = open(counterPath, O_RDWR | O_CREAT | O_EXLOCK | O_CLOEXEC, 0o644)
        guard counter >= 0 else { throw queueError("cannot open \(counterPath): \(String(cString: strerror(errno)))") }
        defer { close(counter) }

        let live = liveTickets(below: .max)
        guard live.count < capacity else {
            throw C1Failure(.busy, "Capture One queue is full: \(live.count) callers are waiting for or using Capture One.",
                            hint: "Try again when the running calls finish.")
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(counter, &buffer, buffer.count)
        let number = (count > 0 ? Int64(String(decoding: buffer.prefix(count), as: UTF8.self)) : nil).map { $0 + 1 } ?? 1
        let text = Array(String(number).utf8)
        guard ftruncate(counter, 0) == 0, pwrite(counter, text, text.count, 0) == text.count else {
            throw queueError("cannot update \(counterPath): \(String(cString: strerror(errno)))")
        }
        let path = directory.appendingPathComponent(String(format: "%020lld.ticket", number)).path
        // O_EXLOCK creates and locks in one step, so no scanner can see an unlocked live ticket.
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw queueError("cannot create \(path): \(String(cString: strerror(errno)))") }
        return Ticket(number: number, fd: fd, path: path)
    }

    private func wait(for ticket: Ticket) throws {
        let start = Date()
        while !liveTickets(below: ticket.number).isEmpty {
            guard Date().timeIntervalSince(start) < maxWait else {
                throw C1Failure(.busy, "Waited \(Int(maxWait)) seconds for Capture One without reaching the front of the queue.",
                                hint: "Another caller holds Capture One for a long time; try again later.")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func release(_ ticket: Ticket) {
        unlink(ticket.path)
        close(ticket.fd)
    }

    /// Ticket numbers below `limit` whose owners are alive; removes tickets of dead owners.
    private func liveTickets(below limit: Int64) -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Int64? in
            guard name.hasSuffix(".ticket"), let number = Int64(name.dropLast(7)), number < limit else { return nil }
            let path = directory.appendingPathComponent(name).path
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                unlink(path)
                return nil
            }
            return number
        }
    }

    private func queueError(_ message: String) -> C1Failure {
        C1Failure(.internal, "Capture One queue failed: \(message)")
    }
}
