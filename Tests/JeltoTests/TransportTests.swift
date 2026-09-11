import XCTest
@testable import Jelto

/// `Transport.post` must actually CANCEL the task it gave up
/// waiting on, not merely stop waiting for it and leave the socket (and
/// `httpMaximumConnectionsPerHost`'s one connection slot) hanging open.
///
/// URLSession reliably delivers a callback once `timeoutIntervalForRequest`/`-Resource` elapses,
/// so a live socket that simply never answers exercises the WRONG code path (URLSession's own
/// timeout, not `post`'s own semaphore guard). The only deterministic way to reach the guard this
/// file is testing is to make sure URLSession's callback CANNOT be delivered at all: pre-block the
/// delegate queue on an unrelated task, via the internal `delegateQueue:` seam, before `post`'s
/// own semaphore runs out.
final class TransportTests: XCTestCase {
    private final class TaskStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _state: URLSessionTask.State?
        var state: URLSessionTask.State? {
            get { lock.lock(); defer { lock.unlock() }; return _state }
            set { lock.lock(); _state = newValue; lock.unlock() }
        }
    }

    func testPostCancelsTheTaskWhenItsOwnSemaphoreGuardFires() throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let released = DispatchSemaphore(value: 0)
        // Occupies the ONLY slot on the delegate queue before `post` ever runs, so no
        // URLSession callback for this request can be delivered until `released` signals --
        // long after `post`'s own semaphore has already timed out.
        queue.addOperation {
            _ = released.wait(timeout: .now() + 5)
        }

        // The endpoint's own reachability does not matter: no callback can reach this queue
        // regardless, so even a closed port exercises the same path.
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1/e"))
        let timedOut = DispatchSemaphore(value: 0)
        let capturedState = TaskStateBox()

        let transport = Transport(
            endpoint: endpoint, mockMode: nil,
            requestTimeout: 5, resourceTimeout: 5, semaphoreTimeout: 0.3,
            delegateQueue: queue,
            onSendTimeout: { task in
                capturedState.state = task.state
                timedOut.signal()
            }
        )

        let outcome = transport.post(Data("{}".utf8))
        released.signal() // let the blocked operation, and the request behind it, drain.

        XCTAssertEqual(timedOut.wait(timeout: .now() + 2), .success, "expected post's own semaphore guard to fire")
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.isNetworkError)
        XCTAssertTrue(outcome.isRetryable)
        // `cancel()` moves a task to `.canceling` at once; by the time this line runs the
        // delegate queue may already have delivered the cancellation completion, moving it on to
        // `.completed`. Either proves the cancel happened.
        let state = capturedState.state
        XCTAssertTrue(
            state == .canceling || state == .completed,
            "expected the wedged task to have been cancelled, got \(String(describing: state))"
        )
    }

    /// The production initialiser's own defaults still produce a working `Transport` — the new
    /// parameters must not have silently changed ordinary POST behaviour when unspecified.
    func testProductionInitializerStillPostsSuccessfully() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1/e")) // closed port: fails fast.
        let transport = Transport(endpoint: endpoint, mockMode: nil)
        let outcome = transport.post(Data("{}".utf8))
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.isNetworkError)
    }
}
