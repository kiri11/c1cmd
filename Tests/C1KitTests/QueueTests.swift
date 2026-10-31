import C1Kit
import Foundation

enum QueueTests {
    static func run() {
        fifoOrder()
        fullQueueIsBusy()
        waitLimitIsBusy()
        deadTicketIsReleased()
        crossProcessCrashRelease()
        concurrentCallersRunOneAtATime()
    }

    static func fifoOrder() {
        let queue = CaptureOneQueue(directory: scratchDirectory("fifo"), pollInterval: 0.005)
        let lock = NSLock()
        var order: [Int] = []
        let group = DispatchGroup()
        for index in 0..<5 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                _ = try? queue.run {
                    lock.lock(); order.append(index); lock.unlock()
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            // Callers arrive in index order while the first holds the queue.
            Thread.sleep(forTimeInterval: 0.03)
        }
        group.wait()
        checkEqual(order, [0, 1, 2, 3, 4], "callers run in arrival order")
    }

    static func fullQueueIsBusy() {
        let queue = CaptureOneQueue(directory: scratchDirectory("full"), capacity: 3, pollInterval: 0.005)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for _ in 0..<3 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                _ = try? queue.run { release.wait() }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let start = Date()
        checkFailure(.busy, containing: "full") { try queue.run {} }
        check(Date().timeIntervalSince(start) < 0.5, "a caller beyond capacity fails at once")
        for _ in 0..<3 { release.signal() }
        group.wait()
        check((try? queue.run { true }) == true, "the queue accepts callers again once it drains")
    }

    static func waitLimitIsBusy() {
        let queue = CaptureOneQueue(directory: scratchDirectory("wait"), maxWait: 0.2, pollInterval: 0.005)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? queue.run { release.wait() }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        let start = Date()
        checkFailure(.busy, containing: "Waited") { try queue.run {} }
        let waited = Date().timeIntervalSince(start)
        check(waited >= 0.2 && waited < 1, "gives up after the wait limit, waited \(waited)")
        release.signal()
        done.wait()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: queue.directory.path))?.filter { $0.hasSuffix(".ticket") } ?? []
        checkEqual(leftovers, [], "a caller that gave up removes its ticket")
    }

    static func deadTicketIsReleased() {
        let directory = scratchDirectory("dead")
        try! "1".write(to: directory.appendingPathComponent("counter"), atomically: true, encoding: .utf8)
        let stale = directory.appendingPathComponent(String(format: "%020d.ticket", 1))
        FileManager.default.createFile(atPath: stale.path, contents: nil)
        let queue = CaptureOneQueue(directory: directory, maxWait: 2, pollInterval: 0.005)
        let start = Date()
        check((try? queue.run { true }) == true, "a caller passes an unlocked ticket left by a crashed caller")
        check(Date().timeIntervalSince(start) < 0.5, "without waiting for the wait limit")
        check(!FileManager.default.fileExists(atPath: stale.path), "the dead ticket is removed")
    }

    /// A separate process holds a lower ticket, then exits without removing it.
    static func crossProcessCrashRelease() {
        let directory = scratchDirectory("process")
        try! "1".write(to: directory.appendingPathComponent("counter"), atomically: true, encoding: .utf8)
        let ticket = directory.appendingPathComponent(String(format: "%020d.ticket", 1)).path
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.flock(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(0.6)", ticket]
        let output = Pipe()
        holder.standardOutput = output
        try! holder.run()
        _ = output.fileHandleForReading.availableData
        let queue = CaptureOneQueue(directory: directory, maxWait: 5, pollInterval: 0.005)
        let start = Date()
        check((try? queue.run { true }) == true, "runs after the other process dies")
        let waited = Date().timeIntervalSince(start)
        check(waited >= 0.4, "waits while another process holds a lower ticket, waited \(waited)")
        check(waited < 3, "proceeds once the process is gone, waited \(waited)")
        check(!FileManager.default.fileExists(atPath: ticket), "the dead process's ticket is removed")
        holder.waitUntilExit()
    }

    static func concurrentCallersRunOneAtATime() {
        let directory = scratchDirectory("concurrent")
        let lock = NSLock()
        var running = 0, maxRunning = 0, completed = 0
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                // Separate queue objects, as separate MCP requests or processes would have.
                let queue = CaptureOneQueue(directory: directory, pollInterval: 0.002)
                let ran: Bool? = try? queue.run {
                    lock.lock(); running += 1; maxRunning = max(maxRunning, running); lock.unlock()
                    Thread.sleep(forTimeInterval: 0.02)
                    lock.lock(); running -= 1; lock.unlock()
                    return true
                }
                lock.lock(); if ran == true { completed += 1 }; lock.unlock()
            }
        }
        group.wait()
        checkEqual(maxRunning, 1, "one caller at a time")
        checkEqual(completed, 8, "every caller completes")
    }
}
