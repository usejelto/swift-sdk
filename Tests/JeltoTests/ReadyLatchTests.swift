import Darwin
import Foundation
import XCTest
@_spi(Conformance) @testable import Jelto

/// A lock-guarded cell for the values two threads hand each other in these tests.
private final class Cell<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A caller of the synchronous API that arrives while `initialize`'s bootstrap is still running
/// parks until bootstrap has run — and HOW it parks is load-bearing on an app's main thread.
/// These pin the two halves of `Engine.waitReady()`: the park lends the caller's QoS to the
/// worker, and it ends with bootstrap rather than with whatever the pump does next.
final class ReadyLatchTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("JELTO_STATE_DIR", directory.path, 1)
        setenv("JELTO_APP_VERSION", "1.0.0", 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1) // a closed port; nothing leaves the machine.
        setenv("JELTO_NOW", "1700000000000", 1) // pinned: the pump runs one step and schedules nothing.
        unsetenv("JELTO_DEBUG")
        unsetenv("JELTO_MOCK")
        unsetenv("JELTO_CLIENT_VERSION")
    }

    override func tearDown() {
        for name in ["JELTO_STATE_DIR", "JELTO_APP_VERSION", "JELTO_ENDPOINT", "JELTO_NOW"] { unsetenv(name) }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static let accepted = Outcome(
        status: 202, body: Data("{}".utf8), retryAfter: nil, isNetworkError: false, isRetryable: false)

    /// The kernel's view of the calling thread's EFFECTIVE scheduling priority: its class plus
    /// any override in force. `qos_class_self()` reports the requested class only and never
    /// sees an override, which is the very thing under test. Mach base priorities: utility 20,
    /// default 31, user-initiated 37, user-interactive 47.
    private static func currentPriority() -> Int32 {
        var info = thread_extended_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                // `pthread_mach_thread_np` adds no port right, unlike `mach_thread_self()`.
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_EXTENDED_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? info.pth_curpri : -1
    }

    /// Whether the kernel schedules a thread that asked for user-initiated at utility's 20
    /// anyway: the process carries a utility QoS clamp (`taskpolicy -c utility`, and the way
    /// this suite runs on a GitHub-hosted macOS runner). Under it every class collapses to 20,
    /// so the propagation below is unobservable rather than broken. The request itself must
    /// have taken; a thread that never got its class is a harness fault the test fails on.
    private static func utilityClampInForce() -> Bool {
        let clamped = Cell(false)
        let sampled = DispatchSemaphore(value: 0)
        let probe = Thread {
            clamped.value = qos_class_self() == QOS_CLASS_USER_INITIATED && currentPriority() <= 20
            sampled.signal()
        }
        probe.qualityOfService = .userInitiated
        probe.start()
        return sampled.wait(timeout: .now() + 5) == .success && clamped.value
    }

    /// A user-initiated caller parked on bootstrap raises the utility worker to its own class
    /// for as long as it is parked. The worker samples its own effective priority from inside
    /// bootstrap, before the latch opens, until it sees the waiter's or gives up: on the old
    /// `readyCondition.wait()` it saw 20 for the whole three seconds — the inversion Xcode's
    /// Thread Performance Checker reported.
    func testCallerParkedOnBootstrapLendsItsPriorityToTheWorker() throws {
        try XCTSkipIf(ReadyLatchTests.utilityClampInForce(),
            "the process is clamped to utility: no thread can outrank the worker here")
        let waiterPriority = Cell<Int32>(-1)
        let workerPeak = Cell<Int32>(-1)
        let workerSawWaiter = Cell(false)
        let waiterSetOut = DispatchSemaphore(value: 0)
        let engine = Engine(post: { _ in ReadyLatchTests.accepted }, beforeReady: {
            // Sample only once the waiter has set out; it parks within microseconds of that.
            workerSawWaiter.value = waiterSetOut.wait(timeout: .now() + 5) == .success
            let target = waiterPriority.value
            let deadline = Date().addingTimeInterval(3)
            repeat {
                let now = ReadyLatchTests.currentPriority()
                workerPeak.value = max(workerPeak.value, now)
                if now >= target { break }
                usleep(2_000)
            } while Date() < deadline
        })
        engine.initialize(key: "prd_conform001", app: "desktop")

        let finished = DispatchSemaphore(value: 0)
        let waiter = Thread {
            waiterPriority.value = ReadyLatchTests.currentPriority()
            waiterSetOut.signal()
            _ = engine.installID()
            finished.signal()
        }
        waiter.qualityOfService = .userInitiated
        waiter.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)

        XCTAssertTrue(workerSawWaiter.value)
        XCTAssertGreaterThan(waiterPriority.value, 20, "the waiter must outrank the utility worker for this to mean anything")
        XCTAssertGreaterThanOrEqual(workerPeak.value, waiterPriority.value,
            "the worker never reached the waiter's priority (peak \(workerPeak.value)): the park does not propagate QoS")
        XCTAssertFalse(engine.installID().isEmpty)
        XCTAssertTrue(engine.awaitBarrier(engine.openBarrier(), timeoutMS: 2_000))
    }

    /// The park ends with bootstrap, not with the first pump tick. Seeded with a stop probe that
    /// fell due while the app was closed, that tick POSTs; a caller parked during bootstrap
    /// returns while the POST is still in flight. Pins that the first tick is enqueued from
    /// bootstrap's tail as its own block, so the caller's `sync` block lands between the two —
    /// folded back into one block, the caller would wait out the whole round trip.
    func testCallerParkedOnBootstrapDoesNotWaitForTheFirstTicksPost() {
        XCTAssertTrue(Store(directory: directory).commit {
            $0.installID = Identifiers.uuidV4()
            $0.installClaimed = true
            $0.lastAppVersion = "1.0.0"
            $0.stopProbeDue = true
        })
        let holdBootstrap = DispatchSemaphore(value: 0)
        let postEntered = DispatchSemaphore(value: 0)
        let releasePost = DispatchSemaphore(value: 0)
        let engine = Engine(post: { _ in
            postEntered.signal()
            _ = releasePost.wait(timeout: .now() + 10)
            return ReadyLatchTests.accepted
        }, beforeReady: {
            _ = holdBootstrap.wait(timeout: .now() + 10)
        })
        engine.initialize(key: "prd_conform001", app: "desktop")

        let finished = DispatchSemaphore(value: 0)
        let waiter = Thread {
            _ = engine.installID()
            finished.signal()
        }
        waiter.start()
        // Bootstrap is held, so the caller cannot have returned: it is parked.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)

        holdBootstrap.signal()
        // Released with bootstrap — long before the probe's POST is answered.
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(postEntered.wait(timeout: .now() + 2), .success, "the seeded stop probe did not POST on the first tick")
        releasePost.signal()
        XCTAssertTrue(engine.awaitBarrier(engine.openBarrier(), timeoutMS: 5_000))
    }
}
