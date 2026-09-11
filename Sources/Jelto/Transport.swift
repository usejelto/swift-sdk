// Synchronous transport for the SDK's serial queue, never the main thread.
// It owns no clock or environment policy and writes nothing to stderr.

import Foundation

/// The outcome of one POST. `status == 0` means the request never got an answer (a network error,
/// including a timeout or the semaphore's own real-time guard firing).
struct Outcome: Sendable {
    var status: Int
    var body: Data
    var retryAfter: String? // the RAW header value; nil means the header was absent
    var isNetworkError: Bool
    var isRetryable: Bool
}

/// One `URLSession` per `Transport`, process-lifetime, never invalidated — that is deliberate
/// (§4.1's third trap), not a leak.
final class Transport: @unchecked Sendable {
    private let endpoint: URL
    private let mockMode: String?
    private let session: URLSession
    private let delegate: TransportDelegate
    private let requestTimeout: TimeInterval
    private let semaphoreTimeout: TimeInterval
    /// Test-only seam: called with the task `post` just cancelled, right
    /// after `task.cancel()`, so `TransportTests` can observe that a wedged send is actually
    /// cancelled rather than merely reported as failed while its socket lingers open. `nil` in
    /// production.
    private let onSendTimeout: (@Sendable (URLSessionTask) -> Void)?

    /// `mockMode` is forwarded verbatim as the `X-Mock` header when non-nil and non-empty,
    /// omitted otherwise (mockd's precedence rule takes the header only "when present and
    /// non-empty").
    convenience init(endpoint: URL, mockMode: String?) {
        self.init(endpoint: endpoint, mockMode: mockMode, requestTimeout: 5, resourceTimeout: 5,
            semaphoreTimeout: 6, onSendTimeout: nil)
    }

    /// The internal second initialiser: every timeout is a parameter (defaulted to production's
    /// own 5 s/5 s/6 s ladder above) so `TransportTests` can shrink all three and reach the
    /// semaphore's own real-time guard in well under a second, instead of waiting out the
    /// production values to prove `post` cancels the task it gave up on.
    /// `delegateQueue` is also injectable: `TransportTests` pre-blocks it so URLSession's own
    /// callback provably cannot be delivered, which is the only way to deterministically reach
    /// `post`'s OWN semaphore guard rather than URLSession's much more commonly hit
    /// `timeoutIntervalForRequest`/`-Resource` (both of which reliably deliver a callback and so
    /// never touch this code path at all).
    init(endpoint: URL, mockMode: String?, requestTimeout: TimeInterval, resourceTimeout: TimeInterval,
         semaphoreTimeout: TimeInterval, delegateQueue: OperationQueue? = nil,
         onSendTimeout: (@Sendable (URLSessionTask) -> Void)? = nil) {
        self.endpoint = endpoint
        self.mockMode = mockMode
        self.requestTimeout = requestTimeout
        self.semaphoreTimeout = semaphoreTimeout
        self.onSendTimeout = onSendTimeout

        let config = URLSessionConfiguration.default
        // §5 Swift addendum: the SDK's own backoff governs retries, not URLSession's own wait.
        config.waitsForConnectivity = false
        // The SDK's own request timeout, part of its retry/timeout policy. On Darwin this is an
        // INACTIVITY timeout — what fires against mockd's `slow:10000`, which sends nothing for 10 s.
        config.timeoutIntervalForRequest = requestTimeout
        // The TOTAL bound. Needed as well because `huge:` streams continuously, so inactivity
        // never fires and only this caps the transfer.
        config.timeoutIntervalForResource = resourceTimeout
        // Every byte the SDK writes goes inside JELTO_STATE_DIR. `.ephemeral` is the
        // WRONG fix here — it keeps an in-memory cache, worse for §8.3 item 11's 2 MB ceiling.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        // One request is in flight at a time by construction; this bounds it structurally.
        config.httpMaximumConnectionsPerHost = 1

        let transportDelegate = TransportDelegate()
        let resolvedDelegateQueue = delegateQueue ?? OperationQueue()
        resolvedDelegateQueue.maxConcurrentOperationCount = 1
        // No `underlyingQueue`: delivering the callback onto the queue that is blocked in
        // `semaphore.wait()` would be a deadlock (§4.1 trap 1).

        self.delegate = transportDelegate
        self.session = URLSession(configuration: config, delegate: transportDelegate, delegateQueue: resolvedDelegateQueue)
    }

    /// Synchronous on the caller's queue: start the task, wait on a semaphore, read the result
    /// out of an `@unchecked Sendable` box guarded by `NSLock` — a pattern already proven safe
    /// elsewhere in this SDK.
    func post(_ body: Data) -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = requestTimeout
        if let mockMode, !mockMode.isEmpty {
            request.setValue(mockMode, forHTTPHeaderField: "X-Mock")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()

        let generation = delegate.beginRequest(semaphore: semaphore, box: box)
        // Kept in a local, not just handed to `resume()` and forgotten: the semaphore's own
        // real-time guard below must be able to cancel THIS task, not merely stop waiting on it
        // — otherwise a wedged connection stays open and consuming
        // `httpMaximumConnectionsPerHost`'s one slot for as long as Foundation lets it.
        let task = session.dataTask(with: request)
        // The generation this task belongs to travels WITH the task, read back by the delegate's
        // callbacks — not stored as a `URLSessionTask` reference in the delegate (§4.1 trap 3).
        task.taskDescription = String(generation)
        task.resume()

        // One second past the resource timeout: URLSession's two timeouts should make this
        // unreachable; it exists so a Foundation edge cannot wedge the SDK's only queue forever.
        let waitResult = semaphore.wait(timeout: .now() + semaphoreTimeout)
        guard waitResult == .success, let outcome = box.outcome else {
            task.cancel()
            onSendTimeout?(task)
            return Outcome(status: 0, body: Data(), retryAfter: nil, isNetworkError: true, isRetryable: true)
        }
        return outcome
    }

    /// R11: a network error, `429` and `503`, and nothing else is retryable. A `static func`
    /// rather than an inline expression so `BackoffTests` can assert the whole of wire §2a's
    /// status list under `swift test` (§4.4 C).
    static func isRetryable(status: Int, isNetworkError: Bool) -> Bool {
        isNetworkError || status == 429 || status == 503
    }
}

/// The result of one `post`, landed by the delegate and read once by the caller after the
/// semaphore fires (or times out). `@unchecked Sendable`, guarded by its own `NSLock`.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: Outcome?

    var outcome: Outcome? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _outcome
        }
        set {
            lock.lock()
            _outcome = newValue
            lock.unlock()
        }
    }
}

/// One delegate object serves every request on the session, so its state must be unambiguously
/// owned by exactly one request at a time (§4.1, "The delegate's per-request state"). A separate
/// small `final class`, not `Transport` itself, so `session -> delegate` does not point back into
/// a retain cycle.
///
/// Ownership is a generation counter bumped under `lock` before `resume()`, which resets the
/// accumulated buffer and the `truncated` flag. The generation travels with the task via
/// `task.taskDescription`, set by `Transport.post` before `resume()`; every callback reads it back
/// off the task/dataTask handed to that very call and discards the callback if it disagrees with
/// the generation currently owned. This closes two failures invisible to `swift test`:
/// - without the reset, request 2's `Outcome.body` could carry request 1's accumulated bytes,
///   which would make a plain `202 {}` parse as a `stop` that never arrived;
/// - a late callback past the semaphore's real-time guard would otherwise write the shared box and
///   signal the NEXT request's semaphore, handing it a stale status. The generation check makes a
///   late callback a no-op.
private final class TransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let responseCap = 65_536 // the same bound wire §2 puts on a request body

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var buffer = Data()
    private var truncated = false
    private var currentSemaphore: DispatchSemaphore?
    private var currentBox: OutcomeBox?

    /// Called by `Transport.post`, under `lock`, before `task.resume()`. Bumps the generation,
    /// resets the buffer and the truncated flag, and records this request's semaphore/box.
    /// Returns the generation this request owns, for the caller to stamp onto the task.
    func beginRequest(semaphore: DispatchSemaphore, box: OutcomeBox) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        buffer = Data()
        truncated = false
        currentSemaphore = semaphore
        currentBox = box
        return generation
    }

    /// Accumulates response bytes up to `responseCap`. The first byte past the cap sets
    /// `truncated` and cancels the very `dataTask` handed to this callback — so no task is ever
    /// stored and no `Sendable` question arises.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let gen = UInt64(dataTask.taskDescription ?? "") else { return }

        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        guard !truncated else {
            lock.unlock()
            return
        }

        let remaining = TransportDelegate.responseCap - buffer.count
        if remaining <= 0 {
            truncated = true
            lock.unlock()
            dataTask.cancel()
            return
        }
        if data.count > remaining {
            buffer.append(data.prefix(remaining))
            truncated = true
            lock.unlock()
            dataTask.cancel()
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    /// If `truncated` is set and an HTTP response exists, report that response's status and the
    /// truncated body, ignoring the cancellation error. Otherwise report the status, or
    /// `status = 0` + `isNetworkError = true` when there is no HTTP response — which, since a
    /// cancellation still carries the response it cancelled after, is exactly the same branch:
    /// the presence of `task.response` decides it, not `error`.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let gen = UInt64(task.taskDescription ?? "") else { return }

        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        let sem = currentSemaphore
        let box = currentBox
        let bodyData = buffer
        lock.unlock()

        let outcome: Outcome
        if let http = task.response as? HTTPURLResponse {
            outcome = Outcome(
                status: http.statusCode,
                body: bodyData,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                isNetworkError: false,
                isRetryable: Transport.isRetryable(status: http.statusCode, isNetworkError: false)
            )
        } else {
            outcome = Outcome(status: 0, body: Data(), retryAfter: nil, isNetworkError: true, isRetryable: true)
        }

        box?.outcome = outcome
        sem?.signal()
    }
}
