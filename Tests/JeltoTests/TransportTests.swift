import Network
import XCTest
@testable import Jelto

/// A loopback HTTP listener for one test: answers every request it has fully read with the bytes
/// `response` returns for the port the kernel chose, and records each request line so a test can
/// prove which paths were ever hit. Bound to 127.0.0.1 only; nothing leaves the machine.
private final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var requestLines: [String] = []
    private var connections: [NWConnection] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.jelto.tests.loopback")
    private let ready = DispatchSemaphore(value: 0)
    private let response: @Sendable (UInt16) -> Data

    init(response: @escaping @Sendable (UInt16) -> Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = response
    }

    /// The port the kernel chose; meaningful once `start` has returned `true`.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// Bounded: `false` if the listener did not come up within `timeout` seconds.
    func start(timeout: TimeInterval) -> Bool {
        listener.stateUpdateHandler = { [ready] state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        return ready.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    func recordedRequestLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLines
    }

    private func serve(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        read(connection, buffered: Data())
    }

    /// Accumulates until the request line, the headers and `Content-Length` bytes of body have
    /// all arrived, then answers and closes the connection.
    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let requestLine = LoopbackServer.requestLineOfCompleteRequest(in: buffer) {
                self.lock.lock()
                self.requestLines.append(requestLine)
                self.lock.unlock()
                connection.send(content: self.response(self.port), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffered: buffer)
        }
    }

    /// The request line once the whole request is in `buffer`, `nil` while bytes are still owed.
    private static func requestLineOfCompleteRequest(in buffer: Data) -> String? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                return nil
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        guard buffer.count >= headerEnd.upperBound + contentLength else { return nil }
        return lines.first
    }
}

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

    /// A `3xx` is a final answer (wire §2a), never followed: the envelope must not be re-POSTed
    /// to whatever `Location` the server chose. The loopback listener answers the POST with a
    /// `307` pointing back at itself; the redirect target must see no request at all, and `post`
    /// must report the `307` as its outcome. No wait is needed to catch a follow that did not
    /// happen: had URLSession followed, `post` could not have returned before the second request
    /// had been read and answered, so the recorded request lines are complete when `post` returns.
    func testPostTreatsARedirectAsFinalAndNeverFollowsIt() throws {
        let server = try LoopbackServer { port in
            let head = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/redirected\r\n"
            return Data((head + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8)
        }
        defer { server.stop() }
        XCTAssertTrue(server.start(timeout: 2), "expected the loopback listener to come up")

        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/v1/e"))
        let transport = Transport(endpoint: endpoint, mockMode: nil)
        let outcome = transport.post(Data("{}".utf8))

        XCTAssertEqual(outcome.status, 307)
        XCTAssertFalse(outcome.isNetworkError)
        XCTAssertFalse(outcome.isRetryable)
        XCTAssertEqual(server.recordedRequestLines(), ["POST /v1/e HTTP/1.1"])
    }
}
