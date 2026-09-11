import Foundation
import XCTest
@_spi(Conformance) @testable import Jelto

private final class RecordedPosts: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    let status: Int
    init(status: Int = 202) { self.status = status }
    func post(_ body: Data) -> Outcome {
        lock.lock()
        bodies.append(body)
        lock.unlock()
        return Outcome(status: status, body: Data("{}".utf8), retryAfter: nil,
            isNetworkError: false, isRetryable: status == 503)
    }
    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }
}

private final class MutationPause: @unchecked Sendable {
    let target: Engine.Mutation
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    init(target: Engine.Mutation) { self.target = target }
    func pause(_ mutation: Engine.Mutation) {
        guard mutation == target else { return }
        entered.signal()
        resume.wait()
    }
}

private final class OneShotPause: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func pause() {
        lock.lock()
        let shouldPause = first
        first = false
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        resume.wait()
    }
}

final class LifecycleRegressionTests: XCTestCase {
    private func seed(claimed: Bool = false, pinned: Bool = true) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("JELTO_STATE_DIR", directory.path, 1)
        setenv("JELTO_APP_VERSION", "1.0.0", 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1)
        if pinned { setenv("JELTO_NOW", "0", 1) } else { unsetenv("JELTO_NOW") }
        let now = pinned ? Int64(0) : Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertTrue(Store(directory: directory).commit {
            $0.installID = Identifiers.uuidV4()
            $0.lastAppVersion = "1.0.0"
            $0.lastHeartbeatDay = String(now / 86_400_000)
            $0.installClaimed = claimed
            $0.installDueAt = Instant(claimed ? now - 10_000 : 10_000)
        })
        return directory
    }

    private func settle(_ engine: Engine, at: Int64) {
        engine.clock.pin(to: Instant(at))
        XCTAssertTrue(engine.awaitBarrier(engine.openBarrier(), timeoutMS: 2_000))
    }

    private func updateProps(whilePaused pause: OneShotPause, engine: Engine) {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            engine.setProps(["license": "paid"])
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // Old split-lock ordering lets SetProps finish inside the paused transition.
        // The fixed transition keeps it blocked until its state change is complete.
        let finishedEarly = finished.wait(timeout: .now() + 0.1) == .success
        pause.resume.signal()
        if !finishedEarly { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
    }

    override func tearDown() {
        for name in ["JELTO_STATE_DIR", "JELTO_APP_VERSION", "JELTO_ENDPOINT", "JELTO_NOW"] { unsetenv(name) }
        super.tearDown()
    }

    func testInstallDeadlineFlushesAfterInitialFlushAndHonorsFinalOrRetryableResponse() throws {
        for status in [202, 400, 402, 503] {
            let directory = seed()
            defer { try? FileManager.default.removeItem(at: directory) }
            let posts = RecordedPosts(status: status)
            let engine = Engine(post: posts.post)
            engine.initialize(key: "prd_conform001", app: nil)
            _ = engine.exportState()
            settle(engine, at: 3_000)
            XCTAssertTrue(posts.snapshot().isEmpty)
            settle(engine, at: 11_000)
            XCTAssertEqual(posts.snapshot().count, 1, "status \(status)")
            let first = try XCTUnwrap(posts.snapshot().first)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
            let events = try XCTUnwrap(body["e"] as? [[String: Any]])
            XCTAssertEqual(events.map { $0["n"] as? String }, ["install"])
            settle(engine, at: 15_000)
            XCTAssertEqual(posts.snapshot().count, status == 503 ? 2 : 1)
            if status == 503 { XCTAssertEqual(posts.snapshot()[0], posts.snapshot()[1]) }
            XCTAssertEqual(Store(directory: directory).load().installClaimed, status == 202)
            engine.disable()
        }
    }

    func testConcurrentPropertyMergesPersistEveryDistinctKey() {
        let directory = seed(claimed: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Store(directory: directory)
        _ = saved.load()
        XCTAssertTrue(saved.commit { $0.stopUntil = Instant(1_000_000) })
        let engine = Engine(post: RecordedPosts().post)
        engine.initialize(key: "prd_conform001", app: nil)
        _ = engine.exportState()
        DispatchQueue.concurrentPerform(iterations: 20) { index in engine.setProps(["k\(index)": "v"]) }
        let expected = Dictionary(uniqueKeysWithValues: (0..<20).map { ("k\($0)", "v") })
        XCTAssertEqual(Store(directory: directory).load().installProps, expected)
        engine.disable()
    }

    func testSelectedPropertyHeartbeatUsesItsMatchingPropertySnapshot() throws {
        let directory = seed(claimed: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = OneShotPause()
        let posts = RecordedPosts()
        let engine = Engine(post: posts.post, beforeBatchSelection: pause.pause)
        engine.initialize(key: "prd_conform001", app: nil)
        _ = engine.exportState()
        engine.track(name: "existing", props: nil)
        engine.clock.pin(to: Instant(6_000))
        let barrier = engine.openBarrier()
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 2), .success)
        updateProps(whilePaused: pause, engine: engine)
        XCTAssertTrue(engine.awaitBarrier(barrier, timeoutMS: 2_000))
        settle(engine, at: 6_000)
        let events = try posts.snapshot().flatMap { body -> [[String: Any]] in
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(envelope["e"] as? [[String: Any]])
        }
        let heartbeat = try XCTUnwrap(events.first { ($0["n"] as? String) == "heartbeat" })
        XCTAssertEqual(heartbeat["props"] as? [String: String], ["license": "paid"])
        engine.disable()
    }

    func testClearingIdlePendingCannotLoseConcurrentPropertyHeartbeat() throws {
        let directory = seed(claimed: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = OneShotPause()
        let posts = RecordedPosts()
        let engine = Engine(post: posts.post, beforeIdlePendingClear: pause.pause)
        engine.initialize(key: "prd_conform001", app: nil)
        _ = engine.exportState()
        engine.clock.pin(to: Instant(3_000)) // Initial flush is due but the queue is empty.
        let barrier = engine.openBarrier()
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 2), .success)
        updateProps(whilePaused: pause, engine: engine)
        XCTAssertTrue(engine.awaitBarrier(barrier, timeoutMS: 2_000))
        settle(engine, at: 3_000)
        XCTAssertEqual(posts.snapshot().count, 1)
        let body = try XCTUnwrap(posts.snapshot().first)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(envelope["e"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["n"] as? String, "heartbeat")
        XCTAssertEqual(events.first?["props"] as? [String: String], ["license": "paid"])
        engine.disable()
    }

    func testAdmittedMutationsCannotRestoreDataAfterDisableOrReinitialization() throws {
        for mutation: Engine.Mutation in [.track, .setProps, .reset] {
            for reinitialize in [false, true] {
                let directory = seed(claimed: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let pause = MutationPause(target: mutation)
                let engine = Engine(beforeMutation: pause.pause, post: RecordedPosts().post)
                engine.initialize(key: "prd_conform001", app: nil)
                _ = engine.exportState()
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    switch mutation {
                    case .track: engine.track(name: "stale", props: nil)
                    case .setProps: engine.setProps(["license": "paid"])
                    case .reset: engine.reset()
                    case .disable: break
                    }
                    finished.signal()
                }
                XCTAssertEqual(pause.entered.wait(timeout: .now() + 2), .success)
                engine.disable()
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
                var reinitializedID: String?
                if reinitialize {
                    engine.initialize(key: "prd_conform001", app: nil)
                    _ = engine.exportState()
                    reinitializedID = engine.installID()
                }
                pause.resume.signal()
                XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
                let data = engine.exportState()
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("stale"))
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("paid"))
                if let reinitializedID { XCTAssertEqual(engine.installID(), reinitializedID) }
                if reinitialize { engine.disable() }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            }
        }
    }

    func testConcurrentResetCannotCancelAnAdmittedDisable() throws {
        let directory = seed(claimed: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = MutationPause(target: .disable)
        let engine = Engine(beforeMutation: pause.pause, post: RecordedPosts().post)
        engine.initialize(key: "prd_conform001", app: nil)
        _ = engine.exportState()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine.disable()
            finished.signal()
        }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 2), .success)
        engine.reset()
        pause.resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(engine.installID(), "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testClaimedPastDeadlineDoesNotContinuouslyScheduleTimers() throws {
        let directory = seed(claimed: true, pinned: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(post: RecordedPosts().post)
        engine.initialize(key: "prd_conform001", app: nil)
        _ = engine.exportState()
        let lock = try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "lock" }?.value as? NSLock)
        func generation() throws -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "timerGeneration" }?.value as? UInt64)
        }
        let before = try generation()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertLessThanOrEqual(try generation() - before, 1)
        engine.disable()
    }
}
