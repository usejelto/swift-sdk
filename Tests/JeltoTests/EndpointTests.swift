import XCTest
@_spi(Conformance) @testable import Jelto

/// The conformance runner always injects JELTO_ENDPOINT, so unit tests must cover
/// the default endpoint and precedence. Resolve URLs without sending production traffic.
final class EndpointTests: XCTestCase {
    private var log: DebugLog { DebugLog(enabled: false) }

    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Counts `post` calls without sending anything — the same injection point
    /// `LifecycleRegressionTests` uses.
    private final class RecordedPosts: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func post(_ body: Data) -> Outcome {
            lock.lock(); _count += 1; lock.unlock()
            return Outcome(status: 202, body: Data("{}".utf8), retryAfter: nil, isNetworkError: false, isRetryable: false)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    /// The row that fails if the default is removed.
    func testAnSDKWithNoEnvironmentAndNoArgumentTargetsTheProductionHost() throws {
        let resolved = try XCTUnwrap(Engine.resolveEndpoint(argument: nil, envValue: nil, log: log))
        XCTAssertEqual(resolved.absoluteString, "https://in.jelto.io/v1/e")
        XCTAssertEqual(resolved.scheme, "https", "a shipped app must send over TLS")
        XCTAssertNotEqual(resolved.scheme, "file", "the rev 0.18 fallback was a /dev/null file URL")
    }

    /// §1: "the environment override MUST beat the default rather than the other way round". If
    /// this inverts, the conformance host ignores the endpoint its own runner handed it and posts
    /// real traffic to in.jelto.io while the suite reports green.
    func testTheEnvironmentBeatsTheDefault() throws {
        let resolved = try XCTUnwrap(Engine.resolveEndpoint(argument: nil, envValue: "http://127.0.0.1:8080/v1/e", log: log))
        XCTAssertEqual(resolved.absoluteString, "http://127.0.0.1:8080/v1/e")
    }

    /// §1's precedence, in full: an explicit endpoint beats both.
    func testTheArgumentBeatsTheEnvironment() throws {
        let resolved = try XCTUnwrap(Engine.resolveEndpoint(argument: "https://a.example.com/v1/e",
                                              envValue: "http://127.0.0.1:8080/v1/e", log: log))
        XCTAssertEqual(resolved.absoluteString, "https://a.example.com/v1/e")
    }

    /// An empty value is an absent one at every level — the rule §5.1 `f` and §5.2 `a` state for
    /// themselves, applied here so a shell exporting `JELTO_ENDPOINT=` does not silence an app.
    func testAnEmptyValueIsAnAbsentValue() throws {
        XCTAssertEqual(try XCTUnwrap(Engine.resolveEndpoint(argument: "", envValue: "", log: log)).absoluteString,
                       "https://in.jelto.io/v1/e")
        XCTAssertEqual(try XCTUnwrap(Engine.resolveEndpoint(argument: "", envValue: "https://e.example.com/v1/e", log: log)).absoluteString,
                       "https://e.example.com/v1/e")
    }

    /// The scheme comparison is case-insensitive (spec/wire-v1.md §1), unlike every other
    /// character in the URL.
    func testSchemeComparisonIsCaseInsensitive() throws {
        let resolved = try XCTUnwrap(Engine.resolveEndpoint(argument: "HTTP://localhost:1/v1/e", envValue: nil, log: log))
        XCTAssertEqual(resolved.absoluteString, "HTTP://localhost:1/v1/e")
    }

    /// A NON-EMPTY value that is not an absolute http(s) URL with no userinfo makes resolution
    /// `nil` AT ONCE — never a fall-through to the next precedence level. This is the specific
    /// shape of the original defect: something unusable was accepted and then
    /// silently never delivered; the fix is not a *different* silent failure one level down.
    func testInvalidNonEmptyValuesResolveToNilRatherThanFallingThrough() {
        // file:// has a scheme but it is not http/https.
        XCTAssertNil(Engine.resolveEndpoint(argument: "file:///dev/null", envValue: nil, log: log))
        // Userinfo — exactly as unsendable as the two neighbors in this table.
        XCTAssertNil(Engine.resolveEndpoint(argument: "https://u:p@e.example/v1/e", envValue: nil, log: log))
        // No scheme at all.
        XCTAssertNil(Engine.resolveEndpoint(argument: "not a url", envValue: nil, log: log))
        // A relative path has no scheme and cannot be posted to.
        XCTAssertNil(Engine.resolveEndpoint(argument: nil, envValue: "/v1/e", log: log))
        // The same rule applies to JELTO_ENDPOINT, not only the explicit argument.
        XCTAssertNil(Engine.resolveEndpoint(argument: nil, envValue: "file:///dev/null", log: log))
    }

    /// The default is a literal, so it must parse. If it ever does not, the floor is `nil` and
    /// every send fails — which is exactly the state this whole test file exists to prevent.
    func testTheDefaultIsItselfParsable() {
        XCTAssertNotNil(URL(string: Engine.defaultEndpoint)?.scheme)
    }

    // The engine-level half: an invalid explicit endpoint must leave the whole process INACTIVE
    // (spec/wire-v1.md §1) — `init`, `track` and time passing must never produce a single POST.

    func testInvalidExplicitEndpointLeavesTheEngineInactiveAndPostsNothing() {
        for badEndpoint in ["file:///dev/null", "https://u:p@e.example/v1/e", "not a url", "/v1/e"] {
            let dir = freshDirectory()
            defer { removeQuietly(dir) }
            setenv("JELTO_STATE_DIR", dir.path, 1)
            setenv("JELTO_NOW", "0", 1)
            unsetenv("JELTO_ENDPOINT")
            defer { unsetenv("JELTO_STATE_DIR"); unsetenv("JELTO_NOW") }

            let posts = RecordedPosts()
            let engine = Engine(post: posts.post)
            engine.initialize(key: "prd_conform001", app: nil, endpoint: badEndpoint)
            engine.track(name: "x", props: nil)
            engine.clock.pin(to: Instant(50_000)) // advance time; a live pump would flush by now.

            XCTAssertEqual(engine.installID(), "", badEndpoint)
            XCTAssertEqual(posts.count, 0, badEndpoint)
        }
    }

    /// An empty explicit endpoint is absent, not invalid — the process starts normally.
    func testEmptyExplicitEndpointDoesNotDisableTheEngine() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        setenv("JELTO_STATE_DIR", dir.path, 1)
        setenv("JELTO_NOW", "0", 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1)
        defer { unsetenv("JELTO_STATE_DIR"); unsetenv("JELTO_NOW"); unsetenv("JELTO_ENDPOINT") }

        let engine = Engine(post: RecordedPosts().post)
        engine.initialize(key: "prd_conform001", app: nil, endpoint: "")
        XCTAssertFalse(engine.installID().isEmpty)
        engine.disable()
    }

    // §1's caching half: `transport()` must rebuild rather than latch the
    // FIRST endpoint it ever saw across a disable/re-init cycle with a different one.

    func testEndpointChangeAfterDisableRebuildsTheCachedTransport() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        setenv("JELTO_STATE_DIR", dir.path, 1)
        setenv("JELTO_NOW", "0", 1)
        unsetenv("JELTO_ENDPOINT")
        defer { unsetenv("JELTO_STATE_DIR"); unsetenv("JELTO_NOW") }

        let engine = Engine(post: RecordedPosts().post)
        engine.initialize(key: "prd_conform001", app: nil, endpoint: "http://first.example/v1/e")
        _ = engine.installID()
        XCTAssertEqual(engine.currentTransportEndpoint()?.host, "first.example")

        engine.disable()

        engine.initialize(key: "prd_conform001", app: nil, endpoint: "http://second.example/v1/e")
        _ = engine.installID()
        XCTAssertEqual(engine.currentTransportEndpoint()?.host, "second.example")
    }
}
