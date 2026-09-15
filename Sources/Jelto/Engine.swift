import Foundation

// All SDK work runs on one serial utility queue. Synchronous API fields use lock;
// readyCondition wakes bootstrap waiters and remains open for later callers until re-armed.
// idleAckCondition wakes barrier waiters; idleWant has a separate lock.
// Jelto.swift owns the shared instance and public/SPI accessors.
final class Engine: @unchecked Sendable {
    enum Mutation: Sendable { case track, setProps, reset, disable }
    let clock: Clock
    private let store: Store
    private let eventQueue: EventQueue
    let log: DebugLog
    // Build Transport lazily on dispatchQueue to keep URLSession setup off the init caller.
    // Only that queue accesses transportInstance.
    private let envEndpoint: String?

    // Write the endpoint under lock before dispatching bootstrap; `transport()` re-reads it
    // under `lock` on every call rather than trusting a stale unsynchronized read. `nil` means:
    // no absolute http(s) URL with no userinfo could be resolved at
    // any precedence level touched so far — the whole process stays inactive (spec/wire-v1.md §1).
    private var transportEndpoint: URL?
    private let transportMockMode: String?
    private var transportInstance: Transport?
    // Paired with `transportInstance`: the endpoint that instance was actually built with, so a
    // later `init` with a new endpoint rebuilds rather than silently keeps sending to the old
    // one. Only `dispatchQueue` touches this, same as `transportInstance`.
    private var cachedTransportEndpoint: URL?
    private let clientVersion: String?
    private let appVersionOverride: String?
    private let beforeMutation: (@Sendable (Mutation) -> Void)?
    private let postOverride: (@Sendable (Data) -> Outcome)?
    private let beforeBatchSelection: (@Sendable () -> Void)?
    private let beforeIdlePendingClear: (@Sendable () -> Void)?
    // Only dispatchQueue touches observation/recovery state.
    private var versionObserved = false
    private var observationTime: Instant?
    private var installEnqueuedThisRun = false // dispatchQueue owns scheduling, including final refusals.
    private let dispatchQueue: DispatchQueue

    // Fields the synchronous API reads, all guarded by `lock`

    private let lock = NSLock()
    private var started = false
    private var disabled = false
    private var quit = false
    private var lifecycleGeneration: UInt64 = 0
    private var identityGeneration: UInt64 = 0
    private var key = ""
    private var installIDValue = ""
    private var props: [String: String] = [:] // the install-properties mirror
    private var platform: Platform?
    private var initFlushAt: Instant?
    private var trackFlushAt: Instant?
    private var pending = false
    private var wakeScheduled = false // the wake mark — coalescing (§2.3)
    private var timerGeneration: UInt64 = 0 // the real-clock timer's generation (§2.3)

    // Only dispatchQueue accesses the wake timer; lock guards timerGeneration.
    private var wakeTimer: DispatchSourceTimer?

    // The ready latch (§2.1). Reset on every fresh start and every re-arm.

    private let readyCondition = NSCondition()
    private var isReady = false // guarded by `readyCondition`, not `lock`

    // The idle barrier (§3.7). `idleWant` under its own dedicated `NSLock`; `idleAck`
    // under its own `NSCondition`, since a waiter needs to be woken and `NSLock` cannot do that.

    private let idleLock = NSLock()
    private var idleWant: UInt64 = 0
    private let idleAckCondition = NSCondition()
    private var idleAck: UInt64 = 0

    // Creates no file and opens no socket: `Store.init`/`EventQueue.init` already guarantee it,
    // and nothing below calls `load`, `update` or `append`.

    // Internal injection points keep lifecycle interleavings and HTTP outcomes deterministic in tests.
    init(beforeMutation: (@Sendable (Mutation) -> Void)? = nil, post: (@Sendable (Data) -> Outcome)? = nil,
         beforeBatchSelection: (@Sendable () -> Void)? = nil, beforeIdlePendingClear: (@Sendable () -> Void)? = nil) {
        self.beforeMutation = beforeMutation
        self.postOverride = post
        self.beforeBatchSelection = beforeBatchSelection
        self.beforeIdlePendingClear = beforeIdlePendingClear
        let env = ProcessInfo.processInfo.environment

        let debugEnabled = env["JELTO_DEBUG"] == "1"
        self.log = DebugLog(enabled: debugEnabled)

        self.clock = Clock()
        // Presence pins the clock, including JELTO_NOW=0. Invalid values leave it unpinned;
        // the conformance host rejects invalid syntax before constructing the SDK.
        if let nowString = env["JELTO_NOW"] {
            let trimmed = nowString.trimmingCharacters(in: .whitespaces)
            if let parsed = Instant(decimal: trimmed) {
                self.clock.pin(to: parsed)
            }
        }

        let directory: URL
        if let stateDir = env["JELTO_STATE_DIR"], !stateDir.isEmpty {
            directory = URL(fileURLWithPath: stateDir)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "jelto"
            directory = base.appendingPathComponent(bundleID).appendingPathComponent("jelto")
        }
        self.store = Store(directory: directory)
        self.eventQueue = EventQueue(fileURL: directory.appendingPathComponent("queue.jsonl"))

        self.envEndpoint = env["JELTO_ENDPOINT"]
        self.transportEndpoint = Engine.resolveEndpoint(argument: nil, envValue: self.envEndpoint, log: self.log)
        self.transportMockMode = env["JELTO_MOCK"]

        self.appVersionOverride = env["JELTO_APP_VERSION"]
        self.clientVersion = WireGate.clientVersion(override: env["JELTO_CLIENT_VERSION"], log: self.log)

        self.dispatchQueue = DispatchQueue(label: "io.jelto.sdk", qos: .utility)
    }

    // The ready latch.

    private func resetReady() {
        readyCondition.lock()
        isReady = false
        readyCondition.unlock()
    }

    private func markReady() {
        readyCondition.lock()
        isReady = true
        readyCondition.broadcast()
        readyCondition.unlock()
    }

    private func waitReady() {
        readyCondition.lock()
        while !isReady {
            readyCondition.wait()
        }
        readyCondition.unlock()
    }

    /// Reads the latch without waiting on it (§2.3): the pump must never block on a channel it
    /// does not own.
    private func bootstrapped() -> Bool {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        return isReady
    }

    /// The gate on every public call (§2.1). `false` before `init` (C5) and `false` after
    /// `disable()` until the next `init` (C18).
    private func awaitReady() -> Bool {
        admissionGeneration(allowIdentityChange: true) != nil
    }

    private func admissionGeneration(allowIdentityChange: Bool = false) -> (lifecycle: UInt64, identity: UInt64)? {
        lock.lock()
        let active = started && !disabled && !quit
        let generation = (lifecycle: lifecycleGeneration, identity: identityGeneration)
        lock.unlock()
        guard active else { return nil }
        waitReady()
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, !quit, generation.lifecycle == lifecycleGeneration,
              allowIdentityChange || generation.identity == identityGeneration else { return nil }
        return generation
    }


    func initialize(key: String, app: String?, endpoint: String? = nil, installOrigin: Jelto.InstallOrigin = .unknown) {
        lock.lock()
        // Resolve explicit endpoint, then JELTO_ENDPOINT, then the default (wire §1).
        // The environment override must work so conformance traffic stays on the mock endpoint.
        if let endpoint, !endpoint.isEmpty {
            self.transportEndpoint = Engine.resolveEndpoint(argument: endpoint, envValue: envEndpoint, log: log)
        }
        // A non-empty invalid endpoint at any precedence level leaves the client inactive for
        // the whole process (spec/wire-v1.md §1) — never a fall-through.
        guard self.transportEndpoint != nil else {
            lock.unlock()
            return
        }
        // spec/wire-v1.md §2's `p` grammar: `init` is refused outright.
        guard WireGate.productKey(key, log: log) != nil else {
            lock.unlock()
            return
        }
        if started && !disabled {
            lock.unlock()
            return
        }
        let isReArm = started && disabled
        resetReady()
        lifecycleGeneration += 1
        if isReArm {
            disabled = false
        } else {
            started = true
            disabled = false
        }
        self.key = key
        lock.unlock()

        // Validate the slug synchronously and capture its immutable value for bootstrap.
        let gatedSlug = WireGate.appSlug(app, log: log)

        if isReArm {
            dispatchQueue.async { [self] in
                bootstrap(gatedSlug: gatedSlug, installOrigin: installOrigin)
                notify()
            }
        } else {
            // Dispatch bootstrap before the first pump tick on the serial queue.
            dispatchQueue.async { [self] in
                bootstrap(gatedSlug: gatedSlug, installOrigin: installOrigin)
                tick()
            }
        }
    }

    /// Resolve explicit endpoint, then environment, then the default (spec/wire-v1.md §1).
    /// An empty value is absent at every level, so the next level applies. A NON-EMPTY value
    /// that is not an absolute http(s) URL with no userinfo makes resolution `nil` at once —
    /// there is no fall-through past a value that was actually given (the original defect was
    /// accepting something unusable and then silently never delivering; the fix is not to
    /// invent a *different* silent failure one level down). Resolution never
    /// throws.
    static func resolveEndpoint(argument: String?, envValue: String?, log: DebugLog) -> URL? {
        if let argument, !argument.isEmpty {
            if let url = Engine.validatedEndpointURL(argument) { return url }
            log.log("endpoint \(DebugLog.display(argument)) passed to initialize is not an absolute http(s) URL with no userinfo (spec/wire-v1.md §1); the client is inactive")
            return nil
        }
        if let envValue, !envValue.isEmpty {
            if let url = Engine.validatedEndpointURL(envValue) { return url }
            log.log("JELTO_ENDPOINT \(DebugLog.display(envValue)) is not an absolute http(s) URL with no userinfo (spec/wire-v1.md §1); the client is inactive")
            return nil
        }
        if let url = URL(string: defaultEndpoint) { return url }
        // Unreachable: `defaultEndpoint` is a literal this test suite parses. No force unwrap.
        log.log("spec/wire-v1.md §1's default endpoint \(defaultEndpoint) did not parse; the client is inactive")
        return nil
    }

    /// spec/wire-v1.md §1: absolute, scheme `http` or `https` (case-insensitive), a non-empty
    /// host, and no userinfo — `https://u:p@e.example/v1/e` is exactly as unsendable as
    /// `file:///dev/null` or a bare relative path, and none of the three may become the URL a
    /// client posts to.
    private static func validatedEndpointURL(_ s: String) -> URL? {
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static let defaultEndpoint = "https://in.jelto.io/v1/e"

    /// Reuse the process-lifetime URLSession across disable/re-init, but rebuild it when the
    /// endpoint differs from the one it was actually built with — reads
    /// `transportEndpoint` fresh under `lock` on every call rather than the old unsynchronized
    /// read. Called only on `dispatchQueue`.
    private func transport() -> Transport {
        lock.lock()
        // `initialize` already refused to start when this is `nil`; the fallback below is
        // defensive only and never reachable from a bootstrapped run.
        let endpoint = transportEndpoint ?? URL(fileURLWithPath: "/dev/null")
        lock.unlock()

        if let existing = transportInstance, cachedTransportEndpoint == endpoint { return existing }
        let built = Transport(endpoint: endpoint, mockMode: transportMockMode)
        transportInstance = built
        cachedTransportEndpoint = endpoint
        return built
    }

    /// Test-only seam: the endpoint the cached `Transport` was actually
    /// built with, read on `dispatchQueue` so it cannot race `transport()`'s write.
    func currentTransportEndpoint() -> URL? {
        dispatchQueue.sync { cachedTransportEndpoint }
    }

    private func bootstrap(gatedSlug: String?, installOrigin: Jelto.InstallOrigin) {
        _ = transport()

        _ = store.load()
        eventQueue.load(pendingTransitionID: store.get().pendingUpdate?.id)
        installEnqueuedThisRun = eventQueue.contains(name: "install")

        // Platform detection stays off the caller's thread; unsupported platforms are gated at send time.
        let detectedPlatform = Platform.detect(appVersion: appVersionOverride, slug: gatedSlug, log: log)
        lock.lock()
        platform = detectedPlatform
        lock.unlock()

        let now = clock.now()

        // Persist the draw instant once so relaunch resumes the immediate deadline (C4c).
        let stateAfterInstall = store.update { state in
            if state.installID.isEmpty || state.installID == Identifiers.nilUUID {
                state.installID = Identifiers.uuidV4()
                state.installOrigin = installOrigin.rawValue
            }
            // A legacy identity already owns its claim, even if it has not sent yet.
            if state.installOrigin == nil { state.installOrigin = "unknown" }
            if !state.installClaimed && state.installDueAt == nil {
                state.installDueAt = now
            }
        }

        // Re-gate install properties restored from disk through the same grammar `setProps`
        // enforces on the way in: a tampered or pre-upgrade `state.plist`
        // must not resurrect a key/value pair the wire schema would refuse today.
        let restoredProps = WireGate.installProps(stateAfterInstall.installProps, log: log)
        let gatedProps = WireGate.withinPropCap(restoredProps, log: log) ? restoredProps : [:]

        lock.lock()
        installIDValue = stateAfterInstall.installID
        props = gatedProps
        initFlushAt = now.adding(2_000)
        lock.unlock()

        versionObserved = false
        observationTime = now
        _ = observeVersion()

        // Persist the heartbeat day before enqueueing so same-day initialization sends no duplicate (C3).
        let today = now.utcDayIndex.description
        if stateAfterInstall.lastHeartbeatDay != today {
            store.update { state in state.lastHeartbeatDay = today }
            let heartbeat = QueuedEvent(
                id: Identifiers.uuidV7(at: now), name: "heartbeat", t: now, props: nil, isHeartbeat: true, context: eventContext()
            )
            eventQueue.append(heartbeat)
        }

        markReady()
    }


    /// Both recovery and observation run before dispatch. A failed write holds all sends;
    /// another worker tick retries without publishing an uncommitted version transition.
    private func observeVersion() -> Bool {
        guard !versionObserved else { return true }
        if let intent = store.get().pendingUpdate {
            guard let event = intent.event, eventQueue.persistTransition(event),
                  store.commit({ $0.pendingUpdate = nil }) else {
                log.log("app update persistence unavailable; delivery deferred")
                return false
            }
        }
        guard let current = Platform.observedAppVersion(appVersionOverride),
              let context = eventContext(freezeIdentity: true) else {
            versionObserved = true
            return true
        }
        let prior = store.get().lastAppVersion
        if let prior, prior.utf8.elementsEqual(current.utf8) {
            versionObserved = true
            return true
        }
        guard let prior, Platform.observedAppVersion(prior) != nil else {
            let committed = store.commit { $0.lastAppVersion = current }
            versionObserved = committed
            return committed
        }
        let now = observationTime ?? clock.now()
        let intent = AppUpdateIntent(id: Identifiers.uuidV7(at: now), timestamp: now.description,
            fromVersion: prior, toVersion: current, context: context)
        guard store.commit({
            $0.lastAppVersion = current
            $0.pendingUpdate = intent
        }) else {
            log.log("app update baseline not committed; delivery deferred")
            return false
        }
        guard let event = intent.event, eventQueue.persistTransition(event),
              store.commit({ $0.pendingUpdate = nil }) else { return false }
        versionObserved = true
        return true
    }

    private func eventContext(freezeIdentity: Bool = false) -> EventContext? {
        lock.lock()
        defer { lock.unlock() }
        return eventContextLocked(freezeIdentity: freezeIdentity)
    }

    private func eventContextLocked(freezeIdentity: Bool = false) -> EventContext? {
        guard let platform else { return nil }
        return EventContext(platform: platform, clientVersion: clientVersion,
            installID: freezeIdentity ? installIDValue : nil)
    }

    /// Test-only semantic migration seam; never changes identity or queued events.
    func legacyVersion() -> Bool {
        guard awaitReady() else { return false }
        return dispatchQueue.sync {
            guard store.get().pendingUpdate == nil else { return false }
            return store.commit { $0.lastAppVersion = nil }
        }
    }

    private func tick() {
        lock.lock()
        let shouldQuit = quit
        lock.unlock()
        if shouldQuit { return }

        // Read the barrier before the clock: observing a published barrier must also observe
        // the preceding clock advance (conformance/TODO.md §5).
        let barrier = observeBarrier()
        let now = clock.now()
        let (next, acted) = step(now)
        if acted {
            dispatchQueue.async { [self] in tick() }
            return
        }
        // Acknowledge observed barriers only after bootstrap is ready and nothing remains due.
        if bootstrapped() {
            ackBarrier(barrier)
        }
        if clock.isPinned {
            // Only `notify()` moves a pinned clock; nothing is scheduled.
            return
        }
        scheduleWake(at: next, from: now)
    }

    /// Clear the wake mark before tick observes the barrier. A concurrent notify must
    /// schedule a fresh tick instead of being swallowed after a stale barrier read.
    private func notify() {
        lock.lock()
        if wakeScheduled {
            lock.unlock()
            return
        }
        wakeScheduled = true
        lock.unlock()
        dispatchQueue.async { [self] in runTick() }
    }

    /// The mark is cleared BEFORE `tick()` calls `observeBarrier()` — load-bearing, not a
    /// formatting choice (§2.3). Cleared first, a `notify()` arriving while this tick runs —
    /// including the one `openBarrier()` issues — finds the mark clear and schedules a further
    /// tick, which the serial queue runs next and which therefore observes the NEW `want`.
    /// Cleared after `tick()`, that `notify()` would be swallowed as a duplicate while this tick
    /// already read a stale `want`, and the barrier would be acknowledged for a question asked
    /// after it was observed — TODO §5's failure, invisible to `event_names` either way.
    private func runTick() {
        lock.lock()
        wakeScheduled = false
        lock.unlock()
        tick()
    }

    /// Use a generation to discard stale timers. Unpinned wall-clock values fit Int64.
    /// DispatchSourceTimer keeps leeway at 1 ms; asyncAfter's proportional leeway can
    /// violate debounce and retry bounds. Retain and resume the source, cancel before
    /// replacement, and never release a suspended timer.
    private func scheduleWake(at next: Instant?, from now: Instant) {
        guard let next else { return }
        let waitMS = max(0, millisecondsUntil(next, from: now))

        lock.lock()
        timerGeneration += 1
        let generation = timerGeneration
        lock.unlock()

        wakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: dispatchQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(waitMS)), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in
            firedTimer(generation: generation)
        }
        wakeTimer = timer
        timer.resume()
    }

    private func firedTimer(generation: UInt64) {
        lock.lock()
        let isCurrent = generation == timerGeneration
        let shouldQuit = quit
        lock.unlock()
        guard isCurrent, !shouldQuit else { return }
        tick()
    }

    private func millisecondsUntil(_ target: Instant, from now: Instant) -> Int64 {
        guard let targetMS = Int64(target.description), let nowMS = Int64(now.description) else {
            return 0
        }
        return targetMS - nowMS
    }


    private func step(_ now: Instant) -> (next: Instant?, acted: Bool) {
        lock.lock()
        let isStarted = started
        let isDisabled = disabled
        lock.unlock()
        guard isStarted, !isDisabled else { return (nil, false) }

        guard observeVersion() else { return (now.adding(1_000), false) }
        let state = store.get()

        if !state.installClaimed, let firstTry = state.installFirstTry,
           !(now < firstTry.adding(2_592_000_000)) {
            store.update { $0.installClaimed = true }
            log.log("install claimed after 30 days of attempts without a 202 (spec/sdk-conformance.md C4b)")
            return (nil, true)
        }

        // A queued install is already the retry; never enqueue a second copy.
        if !state.installClaimed, !installEnqueuedThisRun, let dueAt = state.installDueAt, !(now < dueAt),
           !eventQueue.contains(name: "install") {
            guard store.commit({ s in
                if s.installFirstTry == nil {
                    s.installFirstTry = now
                }
            }) else { return (now.adding(1_000), false) }
            let event = QueuedEvent(
                id: Identifiers.uuidV7(at: now), name: "install", t: now,
                props: ["install_origin": .string(state.installOrigin ?? "unknown")], isHeartbeat: false, context: eventContext()
            )
            installEnqueuedThisRun = true
            eventQueue.append(event)
            lock.lock()
            // Queue immediately while preserving the two-second initial flush (C7).
            if initFlushAt == nil { pending = true }
            lock.unlock()
            return (nil, true)
        }

        if let stopUntil = state.stopUntil, now < stopUntil {
            return (nextDeadline(now: now, state: state), false)
        }

        if state.stopUntil != nil {
            store.update { $0.stopUntil = nil }
            log.log("kill switch elapsed (spec/wire-v1.md §8)")
            return (nil, true)
        }

        // The retry gate also governs the stop probe.
        if let backoffNextAt = state.backoffNextAt, now < backoffNextAt {
            return (nextDeadline(now: now, state: state), false)
        }

        if state.stopProbeDue {
            sendProbe(now)
            return (nil, true)
        }

        lock.lock()
        if let flushAt = initFlushAt, !(now < flushAt) {
            initFlushAt = nil
            pending = true
        }
        if let flushAt = trackFlushAt, !(now < flushAt) {
            trackFlushAt = nil
            pending = true
        }
        let shouldSend = pending && eventQueue.count > 0
        if pending && !shouldSend {
            beforeIdlePendingClear?()
            pending = false
        }
        lock.unlock()

        if shouldSend {
            sendBatch(now)
            return (nil, true)
        }

        return (nextDeadline(now: now, state: state), false)
    }

    private func nextDeadline(now: Instant, state: PersistedState) -> Instant? {
        lock.lock()
        var candidates: [Instant?] = [initFlushAt, trackFlushAt]
        lock.unlock()
        if !state.installClaimed && !installEnqueuedThisRun {
            candidates.append(state.installDueAt)
        }
        candidates.append(state.backoffNextAt)
        candidates.append(state.stopUntil)
        if !state.installClaimed, let firstTry = state.installFirstTry {
            candidates.append(firstTry.adding(2_592_000_000))
        }
        var best: Instant?
        for case let candidate? in candidates {
            guard now < candidate else { continue }
            if let current = best {
                if candidate < current { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }


    /// A snapshot of everything a send needs, taken under the lock so the POST itself never holds
    /// it.
    private struct SendSnapshot {
        var key: String
        var installID: String
        var clientVersion: String?
        var platform: Platform?
        var props: [String: String]
        var queued: [QueuedEvent]
    }

    private func snapshotForSend(selectBatch: Bool = false) -> SendSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = SendSnapshot(
            key: key, installID: installIDValue, clientVersion: clientVersion, platform: platform, props: props, queued: []
        )
        if selectBatch {
            beforeBatchSelection?()
            // SetProps publishes props and its heartbeat under this same lock. Select them
            // together so that a newly selected heartbeat never carries an older props snapshot.
            snapshot.queued = eventQueue.head(100)
        }
        return snapshot
    }

    private func isDisabledNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabled
    }

    private func sendBatch(_ now: Instant) {
        let snapshot = snapshotForSend(selectBatch: true)
        // §3.0: no platform, nothing sent — unreachable on any build this SDK ships for.
        guard let platform = snapshot.platform else { return }

        let queued = snapshot.queued
        let rendered = queued.map {
            Envelope.event(
                $0, platform: platform, clientVersion: snapshot.clientVersion,
                installID: snapshot.installID, installProps: snapshot.props
            )
        }
        let (body, used) = Envelope.envelope(productKey: snapshot.key, events: rendered)
        guard used > 0 else {
            // Not even the first event fits: never POST an empty body, never retry a `used == 0`.
            eventQueue.remove(ids: Set(queued.prefix(1).map(\.id)))
            return
        }

        log.payload(body)
        let outcome = postOverride?(body) ?? transport().post(body)
        let answeredAt = clock.now() // AFTER the response — both floors run from the answer.

        guard !isDisabledNow() else { return } // §3.0: a wipe raced this send.

        if outcome.isRetryable {
            applyBackoff(answeredAt: answeredAt, outcome: outcome)
            return // the batch stays queued, same ids.
        }

        if outcome.status == 202 {
            eventQueue.remove(ids: Set(queued.prefix(used).map(\.id)))
            let hadInstall = queued.prefix(used).contains { $0.name == "install" }
            if hadInstall {
                store.update { $0.installClaimed = true }
            }
            applyAccepted(answeredAt: answeredAt, outcome: outcome)
            clearBackoff()
            lock.lock()
            pending = eventQueue.count > 0 // a queue longer than one batch drains without a new trigger.
            lock.unlock()
            return
        }

        // anything else — 400, 402, 500, 502, 504 — is final.
        finalRefusal(outcome)
        eventQueue.remove(ids: Set(queued.prefix(used).map(\.id)))
        clearBackoff()
        lock.lock()
        pending = eventQueue.count > 0
        lock.unlock()
    }

    /// wire §8's MUST: one `heartbeat`, alone in its batch, before anything the queue is holding.
    /// Not enqueued; never enters the queue.
    private func sendProbe(_ now: Instant) {
        let snapshot = snapshotForSend()
        guard let platform = snapshot.platform else { return } // §3.0.

        let probe = QueuedEvent(
            id: Identifiers.uuidV7(at: now), name: "heartbeat", t: now, props: nil, isHeartbeat: true, context: eventContext()
        )
        let rendered = Envelope.event(
            probe, platform: platform, clientVersion: snapshot.clientVersion,
            installID: snapshot.installID, installProps: snapshot.props
        )
        let (body, used) = Envelope.envelope(productKey: snapshot.key, events: [rendered])
        guard used == 1 else {
            store.update { $0.stopProbeDue = false }
            return
        }

        log.payload(body)
        let outcome = postOverride?(body) ?? transport().post(body)
        let answeredAt = clock.now()

        guard !isDisabledNow() else { return }

        if outcome.isRetryable {
            applyBackoff(answeredAt: answeredAt, outcome: outcome)
            // `stop_probe_due` stays true; the retry gate delays it.
            return
        }

        if outcome.status == 202 {
            applyAccepted(answeredAt: answeredAt, outcome: outcome)
            clearBackoff()
            // Clear the probe only if the switch did not come straight back on.
            if store.get().stopUntil == nil {
                store.update { $0.stopProbeDue = false }
            }
            return
        }

        finalRefusal(outcome)
        clearBackoff()
        store.update { $0.stopProbeDue = false }
    }

    private func applyBackoff(answeredAt: Instant, outcome: Outcome) {
        let before = store.get()
        let jitter = Double.random(in: Backoff.jitterRange)
        let result = Backoff.next(
            currentStepMS: before.backoffStepMS, header: outcome.retryAfter, answeredAt: answeredAt, jitter: jitter
        )
        if let note = Backoff.headerNote(outcome.retryAfter) {
            log.log(note)
        }
        // Log the pre-doubling step that governed this wait.
        let governingStep = before.backoffStepMS <= 0 ? Backoff.firstStepMS : min(before.backoffStepMS, Backoff.ceilingMS)

        var refusalCount = 0
        store.update { state in
            state.backoffStepMS = result.nextStepMS
            state.backoffNextAt = result.deadline
            state.consecutiveRefusals += 1
            refusalCount = state.consecutiveRefusals
        }
        log.log(
            "retry in \(result.waitMS) ms (\(result.source) governs; step was \(governingStep) ms, refusal \(refusalCount)) status=\(outcome.status)"
        )
    }

    private func clearBackoff() {
        let state = store.get()
        guard state.backoffStepMS != 0 || state.backoffNextAt != nil || state.consecutiveRefusals != 0 else {
            return
        }
        store.update { s in
            s.backoffStepMS = 0
            s.backoffNextAt = nil
            s.consecutiveRefusals = 0
        }
    }

    /// A `202` body: wire §6's `rejected`, wire §8's `stop`.
    private func applyAccepted(answeredAt: Instant, outcome: Outcome) {
        guard let parsed = ServerResponse.parse(outcome.body) else {
            log.log("202 with a body that is not JSON")
            return
        }
        for rejection in parsed.rejected {
            let fieldSuffix = rejection.field.map { " (\(DebugLog.display($0)))" } ?? ""
            log.log("event \(rejection.index) rejected: \(DebugLog.display(rejection.reason))\(fieldSuffix) (spec/wire-v1.md §6)")
        }
        guard let stop = parsed.stop else { return }

        // Positive match on the one scope this client answers to, not a negative match on the
        // one scope it happens to know about today: wire §10 only ever
        // appends scopes, and a future one must default to "ignore", the same as "web" does.
        // `scope` itself is wire §8's closed `app`|`web` enum, not free-form server text — unlike
        // `rejection.reason`/`error`/the `Retry-After` header, it needs no `DebugLog.display`
        // quoting, and C16b's conformance scenario pins the exact unquoted wording.
        guard stop.scope == "app" else {
            log.log("ignoring a stop scoped to \(stop.scope) (spec/wire-v1.md §8; this client is s=app)")
            return
        }

        if stop.until < answeredAt {
            // C16 checks this diagnostic to verify the mock and host clocks are aligned.
            log.log("stop until \(stop.until.description) is already past (now \(answeredAt.description))")
        }

        store.update { s in
            s.stopUntil = stop.until
            s.stopProbeDue = true
        }
        log.log("kill switch: no request until \(stop.until.description) ms, scope \(stop.scope) (spec/wire-v1.md §8)")
    }

    private func finalRefusal(_ outcome: Outcome) {
        let error = ServerResponse.parse(outcome.body)?.error
        let suffix = error.map { " \(DebugLog.display($0))" } ?? ""
        log.log("batch dropped: status=\(outcome.status)\(suffix) -- final, not retried (spec/wire-v1.md §2a)")
    }


    func track(name: String, props: [String: WireValue]?) {
        guard let generation = admissionGeneration() else { return }
        guard let gatedName = WireGate.eventName(name, log: log) else { return }
        guard WireGate.validateTrackProps(props, eventName: name, log: log) else { return }
        beforeMutation?(.track)

        let now = clock.now()
        lock.lock()
        guard !disabled, !quit, generation == (lifecycleGeneration, identityGeneration) else {
            lock.unlock()
            return
        }
        let event = QueuedEvent(
            id: Identifiers.uuidV7(at: now), name: gatedName, t: now, props: props, isHeartbeat: false, context: eventContextLocked()
        )
        eventQueue.append(event)
        trackFlushAt = now.adding(5_000) // the 5 s debounce, reset by every `track`.
        lock.unlock()
        notify()
    }

    /// The identical `track` path with the name and props `WireGate.onboarding` returns — C20's
    /// congruence depends on this being the SAME function, not a re-implementation.
    func onboarding(step: String, status: String, reason: String?) {
        guard awaitReady() else { return }
        guard let result = WireGate.onboarding(step: step, status: status, reason: reason, log: log) else { return }
        track(name: result.name, props: result.props)
    }

    func setProps(_ raw: [String: String]) {
        guard let generation = admissionGeneration() else { return }
        let accepted = WireGate.installProps(raw, log: log)
        beforeMutation?(.setProps)
        let now = clock.now()

        lock.lock()
        guard !disabled, !quit, generation == (lifecycleGeneration, identityGeneration) else {
            lock.unlock()
            return
        }
        let current = props

        var merged = current
        for (key, value) in accepted {
            merged[key] = value
        }
        guard WireGate.withinPropCap(merged, log: log), merged != current else {
            lock.unlock()
            return
        }

        store.update { $0.installProps = merged }
        props = merged

        let heartbeat = QueuedEvent(
            id: Identifiers.uuidV7(at: now), name: "heartbeat", t: now, props: nil, isHeartbeat: true, context: eventContextLocked()
        )
        eventQueue.append(heartbeat)
        pending = true // an immediate heartbeat on change (C22's <= 2 s).
        lock.unlock()
        notify()
    }

    func installID() -> String {
        guard awaitReady() else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return installIDValue
    }

    /// The mutation half of `reset()`, run on `dispatchQueue`. A separate function so every
    /// early-return still lets its caller reach `done.signal()`.
    private func performReset(generation: (lifecycle: UInt64, identity: UInt64)) {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, !quit, generation == (lifecycleGeneration, identityGeneration) else { return }
        guard eventQueue.discardTransitions(includeInstallClaims: true) else {
            log.log("reset deferred: app update queue could not be persisted")
            return
        }
        let newID = Identifiers.uuidV4()
        guard store.commit({ state in
            state.installID = newID
            state.installOrigin = "unknown"
            state.installClaimed = false
            state.installDueAt = now
            state.installFirstTry = nil
            state.lastHeartbeatDay = nil
            state.lastAppVersion = Platform.observedAppVersion(appVersionOverride)
            state.pendingUpdate = nil
        }) else { return }
        versionObserved = true
        installEnqueuedThisRun = eventQueue.contains(name: "install")
        identityGeneration += 1
        installIDValue = newID
    }

    /// Serialize reset behind an in-flight send so its response cannot restore old state.
    /// Bounded, like `terminate()`'s own queue wait: a send stuck past its
    /// own timeout must not wedge this call forever.
    func reset() {
        guard let generation = admissionGeneration() else { return }
        beforeMutation?(.reset)
        let done = DispatchSemaphore(value: 0)
        dispatchQueue.async { [self] in
            performReset(generation: generation)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        notify()
    }

    /// §8.7 item 18. `queue.delete()` FIRST, `store.wipe()` SECOND — `EventQueue` holds an open
    /// append handle `Store.wipe()` does not and cannot close.
    func disable() {
        guard let generation = admissionGeneration(allowIdentityChange: true) else { return }
        beforeMutation?(.disable)
        let wiped = DispatchSemaphore(value: 0)
        lock.lock()
        // Reset may rotate identity while Disable is admitted; it must not cancel the wipe.
        guard !disabled, generation.lifecycle == lifecycleGeneration else {
            lock.unlock()
            return
        }
        disabled = true
        lifecycleGeneration += 1
        installIDValue = ""
        props = [:]
        initFlushAt = nil
        trackFlushAt = nil
        pending = false
        // Queue the wipe before a concurrent re-init can enqueue its bootstrap.
        dispatchQueue.async { [self] in
            eventQueue.delete()
            store.wipe()
            versionObserved = false
            installEnqueuedThisRun = false
            wiped.signal()
        }
        lock.unlock()
        // Bounded: a wedged wipe must not hang the caller forever.
        _ = wiped.wait(timeout: .now() + 2)
        notify()
    }

    /// §8.3 item 7's best-effort flush, bounded. The two numbers are ceilings on pathological
    /// paths, not a sum the healthy path pays (§3.6).
    func terminate() {
        lock.lock()
        let isStarted = started
        if started && !disabled {
            pending = true
        }
        lock.unlock()
        guard isStarted else { return }
        notify()

        let flushDeadline = Date().addingTimeInterval(0.6)
        while eventQueue.count > 0 {
            if Date() >= flushDeadline {
                log.log("termination flush gave up with \(eventQueue.count) events queued (best effort; the flush is bounded)")
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        lock.lock()
        quit = true
        lock.unlock()
        // Wake anything parked in `awaitBarrier` so it re-checks `quit` rather than riding out its
        // own timeout.
        idleAckCondition.lock()
        idleAckCondition.broadcast()
        idleAckCondition.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        dispatchQueue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // The idle barrier (§3.7). `internal`; `Jelto.swift` is the only `@_spi(Conformance)`
    // surface for these.

    func openBarrier() -> UInt64 {
        idleLock.lock()
        idleWant += 1
        let seq = idleWant
        idleLock.unlock()
        notify()
        return seq
    }

    private func observeBarrier() -> UInt64 {
        idleLock.lock()
        defer { idleLock.unlock() }
        return idleWant
    }

    private func ackBarrier(_ seq: UInt64) {
        idleAckCondition.lock()
        if seq > idleAck {
            idleAck = seq
            idleAckCondition.broadcast()
        }
        idleAckCondition.unlock()
    }

    /// Returns `true` at once when the SDK has not started (C5 — there is no pump, so nothing can
    /// become due) and when the pump has stopped (`quit`).
    func awaitBarrier(_ seq: UInt64, timeoutMS: Int) -> Bool {
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return true }

        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        idleAckCondition.lock()
        while idleAck < seq {
            lock.lock()
            let stopped = quit
            lock.unlock()
            if stopped { break }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            _ = idleAckCondition.wait(until: Date().addingTimeInterval(remaining))
        }
        let satisfied = idleAck >= seq
        idleAckCondition.unlock()

        if satisfied { return true }
        lock.lock()
        let stoppedNow = quit
        lock.unlock()
        return stoppedNow
    }

    // `dumpstate` waits on the init-in-flight latch; creates nothing.

    func exportState() -> Data {
        lock.lock()
        let isStarted = started
        lock.unlock()
        if isStarted {
            waitReady()
        }
        let state = store.get()
        let export = StateExport(
            state: state, queueBytes: eventQueue.byteCount, queueEvents: eventQueue.exportedEvents()
        )
        return export.jsonData()
    }
}
