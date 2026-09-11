import XCTest
@_spi(Conformance) @testable import Jelto

final class ResponseTests: XCTestCase {
    func testEmptyObjectIsNonNilAndAllEmpty() {
        let r = ServerResponse.parse(Data("{}".utf8))
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.rejected.count, 0)
        XCTAssertNil(r?.stop)
        XCTAssertNil(r?.error)
    }

    /// wire §8's executed example, verbatim.
    func testWireSection8Example() {
        let body = Data(
            #"{"rejected":[{"i":0,"reason":"stopped"},{"i":1,"reason":"stopped"}],"stop":{"until":1788188001,"scope":"web"}}"#.utf8
        )
        let r = ServerResponse.parse(body)
        XCTAssertEqual(r?.rejected.count, 2)
        XCTAssertEqual(r?.rejected[0].index, 0)
        XCTAssertEqual(r?.rejected[0].reason, "stopped")
        XCTAssertEqual(r?.rejected[1].index, 1)
        XCTAssertEqual(r?.rejected[1].reason, "stopped")
        XCTAssertEqual(r?.stop?.scope, "web")
        XCTAssertEqual(r?.stop?.until.description, "1788188001000")
    }

    /// wire §6's example.
    func testWireSection6Example() {
        let body = Data(#"{"rejected":[{"i":2,"reason":"prop_not_allowlisted","field":"email"}]}"#.utf8)
        let r = ServerResponse.parse(body)
        XCTAssertEqual(r?.rejected.count, 1)
        XCTAssertEqual(r?.rejected[0].index, 2)
        XCTAssertEqual(r?.rejected[0].reason, "prop_not_allowlisted")
        XCTAssertEqual(r?.rejected[0].field, "email")
    }

    /// C9b's stderr source, and the rest of wire §2a's error strings.
    func testErrorStrings() {
        let codes = ["payment_required", "malformed", "too_large", "internal", "unsupported_version"]
        for code in codes {
            let body = Data(#"{"error":"\#(code)"}"#.utf8)
            XCTAssertEqual(ServerResponse.parse(body)?.error, code, code)
        }
    }

    /// The no-Double guard: 2^53 + 1, the smallest positive integer a `Double` cannot represent
    /// exactly. If this assertion fails, the fix is in the source, never in the test:
    /// scan `until`'s literal digits out of the body directly, and keep
    /// this assertion exactly as written.
    func testNoDoubleGuard() {
        let body = Data(#"{"stop":{"until":9007199254740993,"scope":"app"}}"#.utf8)
        let r = ServerResponse.parse(body)
        XCTAssertEqual(r?.stop?.until.description, "9007199254740993000")
    }

    /// A fractional `until` drops the stop, but the parse itself is still non-nil.
    func testFractionalUntilDropsStopOnly() {
        let body = Data(#"{"stop":{"until":1.5,"scope":"app"}}"#.utf8)
        let r = ServerResponse.parse(body)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.stop)
    }

    /// No `until` at all drops the stop, but the parse itself is still non-nil.
    func testMissingUntilDropsStopOnly() {
        let body = Data(#"{"stop":{"scope":"app"}}"#.utf8)
        let r = ServerResponse.parse(body)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.stop)
    }

    /// Unknown keys, top-level and inside `stop`, are ignored — wire §10's versioning policy
    /// only ever appends fields.
    func testUnknownKeysIgnored() {
        let body = Data(#"{"unknown":1,"stop":{"until":1788188001,"scope":"app","extra":true}}"#.utf8)
        let r = ServerResponse.parse(body)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.stop?.scope, "app")
        XCTAssertEqual(r?.stop?.until.description, "1788188001000")
    }

    /// Not JSON, all -> `nil`. The truncated object documents the consequence of `Transport`'s
    /// 64 KiB cap on a `huge` body — C10's `garbage` and `huge` arms in one place.
    func testNotJSONAllNil() {
        let bodies: [Data] = [
            Data("not json at all".utf8),
            Data("<html>".utf8),
            Data(),
            Data("[1,2,3]".utf8),
            Data(#""a string""#.utf8),
            Data("7".utf8),
            Data(#"{"stop":{"until":17881"#.utf8),
        ]
        for body in bodies {
            XCTAssertNil(ServerResponse.parse(body), String(decoding: body, as: UTF8.self))
        }
    }
}
