import XCTest
@_spi(Conformance) @testable import Jelto

final class InstantTests: XCTestCase {
    // C15b's two literals round-trip.

    func testRoundTripBigPositive() {
        XCTAssertEqual(Instant(decimal: "99999999999999999999")?.description, "99999999999999999999")
    }

    func testRoundTripNegative() {
        XCTAssertEqual(Instant(decimal: "-14256000000")?.description, "-14256000000")
    }


    func testDayIndexBigPositive() {
        XCTAssertEqual(Instant(decimal: "99999999999999999999")!.utcDayIndex.description, "1157407407407")
    }

    func testDayIndexNegativeExact() {
        XCTAssertEqual(Instant(decimal: "-14256000000")!.utcDayIndex.description, "-165")
    }


    func testFloorZero() {
        XCTAssertEqual(Instant(0).utcDayIndex.description, "0")
    }

    func testFloorOneDay() {
        XCTAssertEqual(Instant(86_400_000).utcDayIndex.description, "1")
    }

    func testFloorMinusOneMs() {
        XCTAssertEqual(Instant(-1).utcDayIndex.description, "-1")
    }

    func testFloorExactMinusOneDay() {
        XCTAssertEqual(Instant(-86_400_000).utcDayIndex.description, "-1")
    }

    func testFloorAdjustedMinusTwoDays() {
        XCTAssertEqual(Instant(-86_400_001).utcDayIndex.description, "-2")
    }


    func testParsingRejectsInvalid() {
        let invalid = ["", "-", "+", " 12", "12 ", "1 2", "12a", "1.5", "1e3", "--1"]
        for s in invalid {
            XCTAssertNil(Instant(decimal: s), "expected nil for \(s.debugDescription)")
        }
    }

    func testParsingLeadingPlus() {
        XCTAssertEqual(Instant(decimal: "+7")?.description, "7")
    }

    func testParsingLeadingZeros() {
        XCTAssertEqual(Instant(decimal: "007")?.description, "7")
    }

    func testParsingNegativeZero() {
        XCTAssertEqual(Instant(decimal: "-0")?.description, "0")
        XCTAssertEqual(Instant(decimal: "-0"), Instant(0))
    }

    func testParsingZero() {
        XCTAssertEqual(Instant(decimal: "0")?.description, "0")
    }


    func testAddingBigPositiveSmall() {
        XCTAssertEqual(
            Instant(decimal: "99999999999999999999")!.adding(3000).description,
            "100000000000000002999"
        )
    }

    func testAddingBigPositiveNegativeSmall() {
        XCTAssertEqual(
            Instant(decimal: "99999999999999999999")!.adding(-3000).description,
            "99999999999999996999"
        )
    }

    func testAddingLimbCarry() {
        XCTAssertEqual(Instant(999_999_999).adding(1).description, "1000000000")
    }

    func testAddingToZeroNoNegativeZero() {
        let result = Instant(-1).adding(1)
        XCTAssertEqual(result, Instant(0))
        XCTAssertEqual(result.description, "0")
    }

    func testAddingNegativeResult() {
        XCTAssertEqual(Instant(5).adding(-10), Instant(-5))
    }

    func testInt64MaxDescription() {
        XCTAssertEqual(Instant(Int64.max).description, "9223372036854775807")
    }

    func testInt64MinDescription() {
        XCTAssertEqual(Instant(Int64.min).description, "-9223372036854775808")
    }

    func testAddingInt64MaxToInt64Max() {
        XCTAssertEqual(Instant(Int64.max).adding(Int64.max).description, "18446744073709551614")
    }

    func testAddingInt64MinToZero() {
        XCTAssertEqual(Instant(0).adding(Int64.min).description, "-9223372036854775808")
    }


    func testLow48BigPositive() {
        XCTAssertEqual(Instant(decimal: "99999999999999999999")!.low48, 103_549_028_532_223)
    }

    func testLow48Negative() {
        XCTAssertEqual(Instant(decimal: "-14256000000")!.low48, 281_460_720_710_656)
    }

    func testLow48Zero() {
        XCTAssertEqual(Instant(0).low48, 0)
    }

    func testLow48MinusOne() {
        XCTAssertEqual(Instant(-1).low48, 281_474_976_710_655)
    }

    func testLow48OneDay() {
        XCTAssertEqual(Instant(86_400_000).low48, 86_400_000)
    }


    func testOrderingNegativeBeforeZero() {
        XCTAssertTrue(Instant(decimal: "-14256000000")! < Instant(0))
    }

    func testOrderingZeroBeforeBigPositive() {
        XCTAssertTrue(Instant(0) < Instant(decimal: "99999999999999999999")!)
    }

    func testOrderingNotStrictlyLessThanSelf() {
        XCTAssertFalse(Instant(5) < Instant(5))
    }

    func testOrderingBothNegative() {
        XCTAssertTrue(Instant(-5) < Instant(-4))
    }

    func testOrderingLeadingZerosEqual() {
        XCTAssertEqual(Instant(decimal: "007")!, Instant(7))
    }
}

final class ClockTests: XCTestCase {
    private let plausibleWallClock = Instant(1_700_000_000_000)

    func testFreshClockIsNotPinned() {
        let clock = Clock()
        XCTAssertFalse(clock.isPinned)
        XCTAssertTrue(plausibleWallClock < clock.now())
    }

    func testFreshClockTwoReadsNonDecreasing() {
        let clock = Clock()
        let a = clock.now()
        let b = clock.now()
        XCTAssertTrue(a < b || a == b)
    }

    func testAdvanceOnUnpinnedClockIsNoOp() {
        let clock = Clock()
        clock.advance(by: 1_000)
        XCTAssertFalse(clock.isPinned)
        XCTAssertTrue(plausibleWallClock < clock.now())
    }

    func testPinSetsIsPinnedAndValue() {
        let clock = Clock()
        let pinned = Instant(decimal: "99999999999999999999")!
        clock.pin(to: pinned)
        XCTAssertTrue(clock.isPinned)
        XCTAssertEqual(clock.now().description, "99999999999999999999")
        XCTAssertEqual(clock.now().description, "99999999999999999999")
    }

    func testAdvanceOnPinnedClock() {
        let clock = Clock()
        clock.pin(to: Instant(decimal: "99999999999999999999")!)
        clock.advance(by: 3000)
        XCTAssertEqual(clock.now().description, "100000000000000002999")
    }

    func testPinToZeroIsFalsyButPinned() {
        let clock = Clock()
        clock.pin(to: Instant(0))
        XCTAssertEqual(clock.now().description, "0")
    }
}
