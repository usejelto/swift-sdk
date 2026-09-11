import XCTest
@_spi(Conformance) @testable import Jelto

/// Every expected number is derived from spec/wire-v1.md §9 or copied from
/// a conformance scenario whose file and arm are named beside the assertion.
/// Expectations are never taken from a test run.
final class BackoffTests: XCTestCase {
    private let answeredAt = Instant(1_788_134_400_123)


    func testRetryAfterMSAbsentAndUnparseable() {
        let cases: [String?] = [
            nil, "", "   ", "soon", "-5", "1.5", "2s", "+2",
            "Wed, 21 Oct 2015 07:28:00 GMT",
        ]
        for header in cases {
            XCTAssertNil(Backoff.retryAfterMS(header), "expected nil for \(String(describing: header))")
        }
    }

    func testRetryAfterMSTable() {
        XCTAssertEqual(Backoff.retryAfterMS("0"), 0)
        XCTAssertEqual(Backoff.retryAfterMS("1"), 1_000)
        XCTAssertEqual(Backoff.retryAfterMS("007"), 7_000)
        XCTAssertEqual(Backoff.retryAfterMS(" 20 "), 20_000)
        XCTAssertEqual(Backoff.retryAfterMS("2"), 2_000)
        XCTAssertEqual(Backoff.retryAfterMS("3"), 3_000)
        XCTAssertEqual(Backoff.retryAfterMS("3600"), 3_600_000)
        XCTAssertEqual(Backoff.retryAfterMS("9999"), 9_999_000)
    }

    /// A 40-digit string never wraps — the point is that it does not wrap, not what the exact
    /// value is, so this asserts `>= ceilingMS` rather than a literal.
    func testRetryAfterMSNeverWraps() {
        let fortyDigits = String(repeating: "9", count: 40)
        XCTAssertGreaterThanOrEqual(Backoff.retryAfterMS(fortyDigits) ?? 0, Backoff.ceilingMS)
    }


    func testHeaderNoteNilCases() {
        let cases: [String?] = [nil, "", "20", "3600"]
        for header in cases {
            XCTAssertNil(Backoff.headerNote(header), "expected nil for \(String(describing: header))")
        }
    }

    func testHeaderNoteCeilingExceeded() {
        let cases = ["3601", "9999", String(repeating: "9", count: 40)]
        for header in cases {
            XCTAssertEqual(
                Backoff.headerNote(header)?.contains("exceeds the 3600 s ceiling"), true,
                "header \(header)"
            )
        }
    }

    func testHeaderNoteUnparseable() {
        let cases = ["soon", "-5", "1.5"]
        for header in cases {
            XCTAssertEqual(
                Backoff.headerNote(header)?.contains("is not delay-seconds and is treated as absent"), true,
                "header \(header)"
            )
        }
    }

    // C. Transport.isRetryable, over the whole of wire §2a. (C9, C9b's rule under `swift test`.)

    func testIsRetryable() {
        XCTAssertTrue(Transport.isRetryable(status: 0, isNetworkError: true))
        XCTAssertTrue(Transport.isRetryable(status: 429, isNetworkError: false))
        XCTAssertTrue(Transport.isRetryable(status: 503, isNetworkError: false))

        // 502/504 are what a naive `status >= 500` shortcut would wrongly retry; C10 sends a 500
        // for exactly that reason.
        let final = [202, 204, 400, 402, 405, 413, 500, 502, 504]
        for status in final {
            XCTAssertFalse(Transport.isRetryable(status: status, isNetworkError: false), "status \(status)")
        }
    }


    /// D1 — first refusal, no header.
    func testNextFirstRefusalNoHeader() {
        let expected: [Double: Int] = [0.8: 800, 1.0: 1_000, 1.2: 1_200]
        for jitter in [0.8, 1.0, 1.2] {
            let r = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: jitter)
            XCTAssertEqual(r.waitMS, expected[jitter], "jitter \(jitter)")
            XCTAssertEqual(r.source, "backoff")
            XCTAssertEqual(r.nextStepMS, 2_000)
        }
    }

    /// D2 — `currentStepMS` of 0 and -1 behave identically (§3 R3's zero rule).
    func testNextZeroAndNegativeStepIdentical() {
        let zero = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 1.0)
        let negative = Backoff.next(currentStepMS: -1, header: nil, answeredAt: answeredAt, jitter: 1.0)
        XCTAssertEqual(zero.waitMS, negative.waitMS)
        XCTAssertEqual(zero.nextStepMS, negative.nextStepMS)
    }

    /// D3 — the step advances regardless (R2).
    func testNextStepAdvancesRegardless() {
        let headers: [String?] = [nil, "", "1", "0", "9999", "soon"]
        for header in headers {
            let r = Backoff.next(currentStepMS: 1_000, header: header, answeredAt: answeredAt, jitter: 1.0)
            XCTAssertEqual(r.nextStepMS, 2_000, "header \(String(describing: header))")
        }
    }

    /// D4 — the header never shortens (R2). C8c arm D's tenth refusal.
    func testNextHeaderNeverShortens() {
        let r = Backoff.next(currentStepMS: 512_000, header: "1", answeredAt: answeredAt, jitter: 0.8)
        XCTAssertEqual(r.waitMS, 409_600)
        XCTAssertEqual(r.source, "backoff")
    }

    /// D5 — "0" does not mean now.
    func testNextZeroHeaderDoesNotMeanNow() {
        let r = Backoff.next(currentStepMS: 1_000, header: "0", answeredAt: answeredAt, jitter: 0.8)
        XCTAssertEqual(r.waitMS, 800)
    }

    /// D6 — unparseable is absent, never zero (R4). C8c arm C's `no_request_before_s: 0.7`.
    func testNextUnparseableIsAbsentNeverZero() {
        let r = Backoff.next(currentStepMS: 0, header: "soon", answeredAt: answeredAt, jitter: 0.8)
        XCTAssertEqual(r.waitMS, 800)
        XCTAssertGreaterThanOrEqual(r.waitMS, 700)
    }

    /// D7 — clamped (R5). C8c arm A's `backoff_step_ms: "2000"`.
    func testNextHeaderClamped() {
        let r = Backoff.next(currentStepMS: 0, header: "9999", answeredAt: answeredAt, jitter: 1.0)
        XCTAssertEqual(r.waitMS, 3_600_000)
        XCTAssertEqual(r.source, "retry-after")
        XCTAssertEqual(r.nextStepMS, 2_000)
        XCTAssertEqual(r.deadline, answeredAt.adding(3_600_001))
    }

    /// D8 — the backoff's own ceiling survives jitter (R10).
    func testNextBackoffCeilingSurvivesJitter() {
        let r = Backoff.next(currentStepMS: 3_600_000, header: nil, answeredAt: answeredAt, jitter: 1.2)
        XCTAssertEqual(r.waitMS, 3_600_000)
        XCTAssertEqual(r.nextStepMS, 3_600_000)
    }

    /// D9 — jitter is clamped, and a non-finite jitter does not trap (R9, note 3).
    func testNextJitterClampedAndNonFiniteDoesNotTrap() {
        let atTop = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 1.2)
        let over = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 5.0)
        XCTAssertEqual(over.waitMS, atTop.waitMS)

        let atBottom = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 0.8)
        let under = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 0.0)
        XCTAssertEqual(under.waitMS, atBottom.waitMS)

        let infinite = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: .infinity)
        XCTAssertEqual(infinite.waitMS, atTop.waitMS)

        let identity = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: 1.0)
        let nan = Backoff.next(currentStepMS: 0, header: nil, answeredAt: answeredAt, jitter: .nan)
        XCTAssertEqual(nan.waitMS, identity.waitMS)
    }

    /// D10 — the header is never jittered (R9). C8b arm A's `tolerance_pct: 5`.
    func testNextHeaderNeverJittered() {
        let low = Backoff.next(currentStepMS: 1_000, header: "20", answeredAt: answeredAt, jitter: 0.8)
        let high = Backoff.next(currentStepMS: 1_000, header: "20", answeredAt: answeredAt, jitter: 1.2)
        XCTAssertEqual(low.waitMS, 20_000)
        XCTAssertEqual(high.waitMS, 20_000)
    }

    /// D11 — the deadline is the answer plus the wait plus one (R7, R8), as a property over a
    /// representative slice of the table, computed from the returned `waitMS`.
    func testNextDeadlineIsAnswerPlusWaitPlusOne() {
        let cases: [(step: Int, header: String?, jitter: Double)] = [
            (0, nil, 0.8), (0, nil, 1.0), (0, nil, 1.2),
            (512_000, "1", 0.8), (1_000, "0", 0.8), (0, "soon", 0.8),
            (0, "9999", 1.0), (3_600_000, nil, 1.2),
            (1_000, "20", 0.8), (1_000, "20", 1.2), (2_000, "2", 1.0),
        ]
        for c in cases {
            let r = Backoff.next(currentStepMS: c.step, header: c.header, answeredAt: answeredAt, jitter: c.jitter)
            XCTAssertEqual(r.deadline, answeredAt.adding(Int64(r.waitMS) + 1), "\(c)")
        }
    }

    /// D12, note 11 — a tie is credited to the header: the exact case where
    /// `headerWait == backoffWait == 2_000`.
    func testNextTieCreditedToHeader() {
        let r = Backoff.next(currentStepMS: 2_000, header: "2", answeredAt: answeredAt, jitter: 1.0)
        XCTAssertEqual(r.source, "retry-after")
    }


    /// Walks `next` from `currentStepMS: 0`, feeding `nextStepMS` forward.
    private func walk(header: String?, jitter: Double, count: Int) -> [(waitMS: Int, source: String)] {
        var results: [(waitMS: Int, source: String)] = []
        var step = 0
        for _ in 0..<count {
            let r = Backoff.next(currentStepMS: step, header: header, answeredAt: answeredAt, jitter: jitter)
            results.append((waitMS: r.waitMS, source: r.source))
            step = r.nextStepMS
        }
        return results
    }

    /// C8b arm C, `429:3`, `expect_s: [3, 3, 4, 8]`. The crossover is refusal 3, for the whole
    /// jitter band under spec/wire-v1.md §9.
    func testWalkC8bArmC() {
        let expectS: [Double] = [3, 3, 4, 8]
        for jitter in [0.8, 1.2] {
            let results = walk(header: "3", jitter: jitter, count: 4)
            XCTAssertEqual(
                results.map(\.source),
                ["retry-after", "retry-after", "backoff", "backoff"],
                "jitter \(jitter)"
            )
            for (i, r) in results.enumerated() {
                let expectMS = expectS[i] * 1_000
                let toleranceMS = expectMS * 0.2 + 500
                XCTAssertLessThanOrEqual(
                    abs(Double(r.waitMS) - expectMS), toleranceMS,
                    "arm C wait \(i) at jitter \(jitter): got \(r.waitMS)"
                )
            }
        }
    }

    /// C8b arm A, `429:20`. The crossover is refusal 6, for the whole jitter band.
    /// `tolerance_pct: 5` leaves no room for anything but exactly 20 000 on the first two waits.
    func testWalkC8bArmA() {
        for jitter in [0.8, 1.2] {
            let results = walk(header: "20", jitter: jitter, count: 6)
            XCTAssertEqual(
                results.map(\.source),
                ["retry-after", "retry-after", "retry-after", "retry-after", "retry-after", "backoff"],
                "jitter \(jitter)"
            )
            XCTAssertEqual(results[0].waitMS, 20_000, "jitter \(jitter)")
            XCTAssertEqual(results[1].waitMS, 20_000, "jitter \(jitter)")
        }
    }

    /// C8 arms 2-3, `Retry-After: 2`, `expect_s: [2, 2, 4]`. Do NOT assert a crossover index —
    /// It is refusal 2 for every jitter above 1.0 and refusal 3 at or below it,
    /// so an index assertion would be pinning a coin toss. Band membership only.
    func testWalkC8HeaderTwo() {
        let expectS: [Double] = [2, 2, 4]
        for jitter in [0.8, 1.2] {
            let results = walk(header: "2", jitter: jitter, count: 3)
            for (i, r) in results.enumerated() {
                let expectMS = expectS[i] * 1_000
                let toleranceMS = expectMS * 0.2 + 400
                XCTAssertLessThanOrEqual(
                    abs(Double(r.waitMS) - expectMS), toleranceMS,
                    "header-2 wait \(i) at jitter \(jitter): got \(r.waitMS)"
                )
            }
        }
    }

    /// C8 arm 1 / C8c arm B and C: no usable header, `expect_s: [1, 2]` / `[1, 2, 4]`. `nil`,
    /// `""` and `"soon"` must all produce the identical list — that equality IS R4.
    func testWalkNoUsableHeader() {
        let expectS: [Double] = [1, 2, 4]
        let headers: [String?] = [nil, "", "soon"]
        var reference: [Int]?
        for header in headers {
            for jitter in [0.8, 1.2] {
                let results = walk(header: header, jitter: jitter, count: 3)
                for (i, r) in results.enumerated() {
                    let expectMS = expectS[i] * 1_000
                    let toleranceMS = expectMS * 0.2 + 400
                    XCTAssertLessThanOrEqual(
                        abs(Double(r.waitMS) - expectMS), toleranceMS,
                        "header \(String(describing: header)) wait \(i) at jitter \(jitter): got \(r.waitMS)"
                    )
                }
            }
            let atOne = walk(header: header, jitter: 1.0, count: 3).map(\.waitMS)
            if let reference {
                XCTAssertEqual(atOne, reference, "header \(String(describing: header))")
            } else {
                reference = atOne
            }
        }
    }

    /// C8c arm D, ten consecutive refusals: the first nine `429:` (header ""), the tenth `503:1`
    /// (header "1"). The step after the tenth is exactly 1 024 000 (`backoff_step_ms`); neither
    /// the 1 s the header named nor the 1 s a reset would put back.
    func testWalkC8cArmD() {
        let expectedTenthWait: [Double: Int] = [0.8: 409_600, 1.0: 512_000, 1.2: 614_400]
        for jitter in [0.8, 1.0, 1.2] {
            var step = 0
            var lastWait = 0
            for refusal in 1...10 {
                let header = refusal == 10 ? "1" : ""
                let r = Backoff.next(currentStepMS: step, header: header, answeredAt: answeredAt, jitter: jitter)
                step = r.nextStepMS
                lastWait = r.waitMS
            }
            XCTAssertEqual(step, 1_024_000, "jitter \(jitter)")
            XCTAssertEqual(lastWait, expectedTenthWait[jitter], "jitter \(jitter)")

            let expectMS = 512_000.0
            let toleranceMS = expectMS * 0.2 + 2_000
            XCTAssertLessThanOrEqual(abs(Double(lastWait) - expectMS), toleranceMS, "jitter \(jitter)")
        }
    }

    /// C8 arm 4: the schedule survives a process boundary. There is no process to restart in a
    /// unit test; this asserts `next` is a pure function of the STORED step, which is what makes
    /// the restart work in plan 5.
    func testWalkSurvivesProcessBoundary() {
        for jitter in [0.8, 1.0, 1.2] {
            let r = Backoff.next(currentStepMS: 8_000, header: nil, answeredAt: answeredAt, jitter: jitter)
            let expectMS = 8_000.0
            XCTAssertLessThanOrEqual(abs(Double(r.waitMS) - expectMS), expectMS * 0.2, "jitter \(jitter)")
        }
    }
}
