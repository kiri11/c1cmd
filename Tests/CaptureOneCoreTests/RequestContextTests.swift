import Foundation
import CaptureOneCore

struct RequestContextTests {
    static func run() {
        print("Running RequestContextTests...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory)
        // Exercise the bounded fallback path here so cancellation/deadline
        // checkpoints occur between rating and summary Apple Events.
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "db" }, nativeInventoryEnabled: false)

        let cancelled = RequestContext(tool: "variants_list", progressMode: "quiet", directory: directory)
        fake.beforeReadRatings = { cancelled.cancel() }
        XCTAssertThrowsError(try cancelled.withCurrent { try core.listVariants() }) { error in
            XCTAssertEqual((error as? C1Error)?.errorCode, "request-cancelled")
            cancelled.finish(error: error)
        }
        XCTAssertTrue(fake.hydrationBatches.isEmpty, "Cancellation after the rating event prevents metadata dispatch")
        XCTAssertEqual(cancelled.snapshot.status, "cancelled")
        XCTAssertNil(RequestContext.current, "Synchronous request context is restored after a thrown error")

        fake.beforeReadRatings = { Thread.sleep(forTimeInterval: 0.03) }
        let deadline = RequestContext(tool: "variants_list", progressMode: "quiet", directory: directory)
        XCTAssertThrowsError(try deadline.withCurrent { try core.listVariants(deadlineSeconds: 0.01) }) { error in
            XCTAssertEqual((error as? C1Error)?.errorCode, "deadline-exceeded")
            deadline.finish(error: error)
        }
        XCTAssertTrue(fake.hydrationBatches.isEmpty, "A deadline cannot start another batch or publish partial results")
        fake.beforeReadRatings = nil

        // A timer on a background queue must run even while the request's thread is blocked.
        let beat = DispatchSemaphore(value: 0)
        let live = RequestContext(tool: "variants_list", progressMode: "quiet", directory: directory,
            observer: { if $0.elapsedMs >= 40 && $0.status == "running" { beat.signal() } }, heartbeatSeconds: 0.02)
        live.update(phase: "metadata", scanned: 1, matches: 1, completed: 0, total: 1)
        live.appleEvent("readVariantSummaries", waiting: true)
        XCTAssertEqual(beat.wait(timeout: .now() + 1), .success, "Heartbeat does not depend on the blocked main thread")
        // finish flushes all pending status writes; a heartbeat alone never increases real counters.
        live.appleEvent(nil, waiting: false)
        live.finish()
        XCTAssertNoThrowBlock {
            let stored = try RequestContext.status(requestId: live.snapshot.requestId, directory: directory)
            XCTAssertEqual(stored.candidatesScanned, 1)
            XCTAssertEqual(stored.summariesCompleted, 0)
            XCTAssertEqual(stored.status, "completed")
            XCTAssertEqual(stored.processAlive, true)
            XCTAssertEqual(stored.stale, false)
            var stale = stored
            stale.status = "running"; stale.updatedAt = Date().timeIntervalSince1970 - 60
            try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent(stale.requestId + ".json"))
            let reread = try RequestContext.status(requestId: stale.requestId, directory: directory)
            XCTAssertEqual(reread.stale, true)
        }
        XCTAssertThrowsError(try RequestContext.status(requestId: "../../private", directory: directory))

        let write = RequestContext(tool: "variant_clone", progressMode: "quiet", directory: directory)
        write.cancel()
        XCTAssertNoThrow(try write.checkReadCancellation(), "Read cancellation cannot bypass mutation reconciliation")
        let failure = OperationFailure(operationId: "op-test", cause: C1Error.timeout("late reply"))
        write.finish(error: failure)
        XCTAssertEqual(write.snapshot.status, "outcome-unknown")
        let error = write.annotate(ErrorResponse.payload(failure))["error"] as! [String: Any]
        XCTAssertEqual(error["operationId"] as? String, "op-test")
        XCTAssertTrue((error["recoveryAction"] as? String ?? "").contains("do not retry"))

        let rejected = RequestContext(tool: "variant_clone", progressMode: "quiet", directory: directory)
        let uncertain = OperationFailure(operationId: "op-native-error", cause: C1Error.scriptError("dispatch failed", code: -1700))
        rejected.finish(error: uncertain)
        XCTAssertEqual(rejected.snapshot.status, "outcome-unknown", "Every post-dispatch OperationFailure remains conservative, not just timeouts")
        let rejectedError = rejected.annotate(ErrorResponse.payload(uncertain))["error"] as! [String: Any]
        XCTAssertTrue((rejectedError["recoveryAction"] as? String ?? "").contains("do not retry"))

        let broken = RequestContext(tool: "schema", progressMode: "quiet", directory: URL(fileURLWithPath: "/dev/null/impossible"))
        broken.finish()
        XCTAssertEqual(broken.snapshot.status, "completed", "Unwritable diagnostics never fail the request")

        let lock = CaptureOneLock(lockPath: directory.appendingPathComponent("lock").path)
        XCTAssertNoThrowBlock {
            try lock.withLock {
                try lock.withLock(timeout: 0.01) {} // same owner can enumerate during clone/recovery
                let other = CaptureOneLock(lockPath: lock.lockPath)
                XCTAssertThrowsError(try other.withLock(timeout: 0.05) {}, "A different lock owner cannot enter during the request")
            }
        }
    }
}
