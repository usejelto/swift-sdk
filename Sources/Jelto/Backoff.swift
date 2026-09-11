// Composes retry backoff with Retry-After (RFC-0001 §8.3 item 8, wire §9).
// Only the duration multiplier uses Double; instants remain exact integers.
enum Backoff {
    static let firstStepMS = 1_000
    static let ceilingMS = 3_600_000
    /// The ±20% belongs with the arithmetic; the engine draws `Double.random(in: Backoff.jitterRange)`
    /// and `next` clamps into it so a caller bug cannot exceed ±20% against the live endpoint.
    static let jitterRange: ClosedRange<Double> = 0.8...1.2

    /// R4, R5's input half. `delay-seconds` is RFC 9110 §10.2.3: one or more ASCII digits and
    /// nothing else, after trimming HTTP OWS (ASCII space and tab). Empty or whitespace-only, or
    /// absent, is `nil` (absent, never zero) — never zero. Leading zeros are legal (`"007"` -> 7).
    /// The whole string is validated as digits-only before any accumulation, so a value that
    /// overflows partway through is never confused with one that was simply unparseable. Overflow
    /// in the accumulation, or in the seconds -> milliseconds conversion, returns `Int.max` rather
    /// than wrapping or saturating into a nonsense value. The return is milliseconds, UNCLAMPED —
    /// the clamp lives in `next` and in `headerNote`, because a function that clamped silently
    /// could not tell its caller that R6's ceiling line is owed.
    static func retryAfterMS(_ header: String?) -> Int? {
        guard let header else { return nil }
        let trimmed = Backoff.trimOWS(header)
        guard !trimmed.isEmpty else { return nil }

        for scalar in trimmed.unicodeScalars {
            guard scalar.value >= 0x30, scalar.value <= 0x39 else { return nil }
        }

        var seconds = 0
        var overflowed = false
        for scalar in trimmed.unicodeScalars {
            let digit = Int(scalar.value - 0x30)
            let (mul, mulOverflow) = seconds.multipliedReportingOverflow(by: 10)
            if mulOverflow {
                overflowed = true
                break
            }
            let (sum, addOverflow) = mul.addingReportingOverflow(digit)
            if addOverflow {
                overflowed = true
                break
            }
            seconds = sum
        }
        if overflowed { return Int.max }

        let (ms, msOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        return msOverflow ? Int.max : ms
    }

    /// R6 — the two stderr substrings, asserted verbatim by the scenarios (BRIEF §6). `nil` when
    /// the header is absent, empty, or a plain `delay-seconds` at or below the 3 600 s ceiling.
    /// Quotes the header's TRIMMED ORIGINAL TEXT rather than a parsed number, so a 40-digit value
    /// renders as what was received rather than as `Int.max`. `Backoff` itself never writes to
    /// stderr; the engine (plan 5) logs the returned string through `DebugLog` on every refusal.
    static func headerNote(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = Backoff.trimOWS(header)
        guard !trimmed.isEmpty else { return nil }

        guard let ms = Backoff.retryAfterMS(header) else {
            return "Retry-After: \"\(trimmed)\" is not delay-seconds and is treated as absent"
        }
        guard ms > Backoff.ceilingMS else { return nil }
        return "Retry-After: \"\(trimmed)\" exceeds the 3600 s ceiling and is clamped to 3600 s"
    }

    /// R1-R3, R7-R10, the whole composition, in order:
    ///
    /// 1. the step governing THIS wait, with `<= 0` read as `firstStepMS` (R3's zero rule) and
    ///    clamped to the ceiling;
    /// 2. jitter clamped into `jitterRange`, without ever trapping on a non-finite value (see the
    ///    note on `clampedJitter` below);
    /// 3. the backoff's own wait, jittered and ceiling-clamped, floored at 1 ms (R10);
    /// 4. the header's wait, UNJITTERED (R9) and ceiling-clamped (R5) — `nil` stays `nil`,
    ///    absent/unparseable is never zero (R4);
    /// 5. the wait actually taken is the LATER of the two floors (R1);
    /// 6. a tie is credited to the header, which named it — deterministic, not incidental;
    /// 7. `answeredAt` is when the ANSWER arrived, never when the request was sent (R7); the
    ///    deadline is the answer plus the wait plus ONE ms, because `Instant` is whole
    ///    milliseconds and `now()` is `floor(ms)` (R8);
    /// 8. the step advances regardless of what the header said (R2), doubling and clamping to the
    ///    ceiling — `step` is already clamped, so the multiply cannot overflow.
    static func next(
        currentStepMS: Int,
        header: String?,
        answeredAt: Instant,
        jitter: Double
    ) -> (waitMS: Int, source: String, deadline: Instant, nextStepMS: Int) {
        let step = currentStepMS <= 0 ? Backoff.firstStepMS : min(currentStepMS, Backoff.ceilingMS)
        let j = Backoff.clampedJitter(jitter)

        let backoffWait = max(1, min(Int((Double(step) * j).rounded()), Backoff.ceilingMS))
        let headerWait = Backoff.retryAfterMS(header).map { min($0, Backoff.ceilingMS) }
        let waitMS = max(backoffWait, headerWait ?? 0)
        let source = (headerWait ?? -1) >= backoffWait ? "retry-after" : "backoff"
        let deadline = answeredAt.adding(Int64(waitMS) + 1)
        let nextStepMS = min(step * 2, Backoff.ceilingMS)

        return (waitMS: waitMS, source: source, deadline: deadline, nextStepMS: nextStepMS)
    }

    /// Clamps `jitter` into `jitterRange`, without trapping on a non-finite input. `Int(Double)`
    /// traps on NaN, which is a crash into the host RFC-0001 §8.3 item 10 forbids ("the SDK never
    /// throws into the host; every failure path is swallowed and logged"), so NaN is special-cased
    /// to `1.0` before it can reach `min`/`max` at all — those propagate NaN rather than clamping
    /// it. `+infinity` and `-infinity` need no special case: `max(+inf, 0.8)` is `+inf` and
    /// `min(+inf, 1.2)` is `1.2` (and symmetrically `0.8` for `-infinity`), because a comparison
    /// against an infinite value is well-defined and behaves like clamping any other
    /// out-of-range finite value — it is only NaN, where every comparison is false, that breaks.
    /// Unreachable from `Double.random(in:)`; defence against a future caller, not a live bug.
    private static func clampedJitter(_ jitter: Double) -> Double {
        guard !jitter.isNaN else { return 1.0 }
        return min(max(jitter, Backoff.jitterRange.lowerBound), Backoff.jitterRange.upperBound)
    }

    /// HTTP OWS: ASCII space (0x20) and horizontal tab (0x09) trimmed from both ends. A
    /// hand-written scan, not `String.trimmingCharacters(in:)`, so this file stays exactly as
    /// ASCII-precise as `Grammar`'s scans and needs no `import Foundation`.
    private static func trimOWS(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        func isOWS(_ v: Unicode.Scalar) -> Bool { v.value == 0x20 || v.value == 0x09 }
        while let first = scalars.first, isOWS(first) { scalars.removeFirst() }
        while let last = scalars.last, isOWS(last) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        for scalar in scalars { view.append(scalar) }
        return String(view)
    }
}
