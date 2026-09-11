import XCTest
@testable import Jelto

/// The conformance runner always injects JELTO_ENDPOINT, so unit tests must cover
/// the default endpoint and precedence. Resolve URLs without sending production traffic.
final class EndpointTests: XCTestCase {
    private var log: DebugLog { DebugLog(enabled: false) }

    /// The row that fails if the default is removed.
    func testAnSDKWithNoEnvironmentAndNoArgumentTargetsTheProductionHost() {
        let resolved = Engine.resolveEndpoint(argument: nil, envValue: nil, log: log)
        XCTAssertEqual(resolved.absoluteString, "https://in.jelto.io/v1/e")
        XCTAssertEqual(resolved.scheme, "https", "a shipped app must send over TLS")
        XCTAssertNotEqual(resolved.scheme, "file", "the rev 0.18 fallback was a /dev/null file URL")
    }

    /// §1: "the environment override MUST beat the default rather than the other way round". If
    /// this inverts, the conformance host ignores the endpoint its own runner handed it and posts
    /// real traffic to in.jelto.io while the suite reports green.
    func testTheEnvironmentBeatsTheDefault() {
        let resolved = Engine.resolveEndpoint(argument: nil, envValue: "http://127.0.0.1:8080/v1/e", log: log)
        XCTAssertEqual(resolved.absoluteString, "http://127.0.0.1:8080/v1/e")
    }

    /// §1's precedence, in full: an explicit endpoint beats both.
    func testTheArgumentBeatsTheEnvironment() {
        let resolved = Engine.resolveEndpoint(argument: "https://a.example.com/v1/e",
                                              envValue: "http://127.0.0.1:8080/v1/e", log: log)
        XCTAssertEqual(resolved.absoluteString, "https://a.example.com/v1/e")
    }

    /// An empty value is an absent one at every level — the rule §5.1 `f` and §5.2 `a` state for
    /// themselves, applied here so a shell exporting `JELTO_ENDPOINT=` does not silence an app.
    func testAnEmptyValueIsAnAbsentValue() {
        XCTAssertEqual(Engine.resolveEndpoint(argument: "", envValue: "", log: log).absoluteString,
                       "https://in.jelto.io/v1/e")
        XCTAssertEqual(Engine.resolveEndpoint(argument: "", envValue: "https://e.example.com/v1/e", log: log).absoluteString,
                       "https://e.example.com/v1/e")
    }

    /// A malformed value falls through to the next level rather than becoming a URL that can only
    /// fail. This is the specific shape of the original defect: something unusable was accepted
    /// and then silently never delivered.
    func testAMalformedValueFallsThroughInsteadOfBecomingAnUnsendableURL() {
        XCTAssertEqual(Engine.resolveEndpoint(argument: "not a url", envValue: nil, log: log).absoluteString,
                       "https://in.jelto.io/v1/e")
        XCTAssertEqual(Engine.resolveEndpoint(argument: nil, envValue: "/v1/e", log: log).absoluteString,
                       "https://in.jelto.io/v1/e",
                       "a relative path has no scheme and cannot be posted to")
    }

    /// The default is a literal, so it must parse. If it ever does not, the floor is a file URL
    /// and every send fails — which is exactly the state this whole test file exists to prevent.
    func testTheDefaultIsItselfParsable() {
        XCTAssertNotNil(URL(string: Engine.defaultEndpoint)?.scheme)
    }
}
