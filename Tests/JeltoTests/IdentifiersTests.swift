import XCTest
@_spi(Conformance) @testable import Jelto

final class IdentifiersTests: XCTestCase {
    private let v4Regex = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private let v7Regex = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    // 1 000 uuidV4()s: C2's exact regex, all distinct, none the nil UUID.

    func testUUIDV4MatchesC2RegexAllDistinctNeverNil() {
        var seen = Set<String>()
        for _ in 0..<1_000 {
            let id = Identifiers.uuidV4()
            XCTAssertNotNil(id.range(of: v4Regex, options: .regularExpression))
            XCTAssertNotEqual(id, Identifiers.nilUUID)
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 1_000)
    }


    func testUUIDV4NoUpperCaseHex() {
        for _ in 0..<1_000 {
            let id = Identifiers.uuidV4()
            XCTAssertNil(id.range(of: "[A-F]", options: .regularExpression))
        }
    }

    // uuidV7(at:) matches its regex and is never nil-shaped, across C15b's two clocks.

    func testUUIDV7MatchesRegexNeverNil() {
        let instants: [Instant] = [
            Instant(0),
            Instant(1_788_134_400_000),
            Instant(decimal: "-14256000000")!,
            Instant(decimal: "99999999999999999999")!,
        ]
        for instant in instants {
            let id = Identifiers.uuidV7(at: instant)
            XCTAssertNotNil(id.range(of: v7Regex, options: .regularExpression))
            XCTAssertNotEqual(id, Identifiers.nilUUID)
        }
    }


    func testUUIDV7TimestampFidelity() {
        let instant = Instant(1_788_134_400_000)
        let id = Identifiers.uuidV7(at: instant)
        let hexOnly = id.replacingOccurrences(of: "-", with: "")
        let first12 = String(hexOnly.prefix(12))
        let decoded = UInt64(first12, radix: 16)
        XCTAssertEqual(decoded, instant.low48)
    }


    func testUUIDV7DistinctAtSameInstant() {
        let instant = Instant(1_788_134_400_000)
        var seen = Set<String>()
        for _ in 0..<1_000 {
            seen.insert(Identifiers.uuidV7(at: instant))
        }
        XCTAssertEqual(seen.count, 1_000)
    }
}
