// The conformance clock exposes pinning and advancement through SPI.
// Timer scheduling and idle acknowledgement belong to Engine.

import Darwin
// `NSLock` needs Foundation; that is acceptable in this file only, not in Instant.swift.
import Foundation

@_spi(Conformance) public final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var pinned = false
    private var pinnedNow = Instant(0)

    /// The real wall clock. Not pinned.
    @_spi(Conformance) public init() {}

    @_spi(Conformance) public var isPinned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinned
    }

    /// When pinned, returns the pinned instant. When not pinned, reads the real clock without
    /// going through `Double`: `clock_gettime(CLOCK_REALTIME, ...)` into `Instant(_:)`.
    @_spi(Conformance) public func now() -> Instant {
        lock.lock()
        defer { lock.unlock() }
        if pinned {
            return pinnedNow
        }
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let ms = Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
        return Instant(ms)
    }

    /// Sets `pinned = true` and the value. Once pinned the clock moves only on `advance`.
    @_spi(Conformance) public func pin(to t: Instant) {
        lock.lock()
        defer { lock.unlock() }
        pinned = true
        pinnedNow = t
    }

    /// On a pinned clock, replaces the value with `value.adding(milliseconds)`. On an unpinned
    /// clock this is a no-op (refhost's `Advance` behaves the same way; the caller is expected to
    /// really sleep instead).
    @_spi(Conformance) public func advance(by milliseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard pinned else { return }
        pinnedNow = pinnedNow.adding(milliseconds)
    }
}
