import XCTest
@_spi(Conformance) @testable import Jelto

final class WireTests: XCTestCase {

    /// Collects the bytes a `DebugLog` sink would have written, so tests can read stderr's would-be
    /// contents without touching the process's real stderr.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        var text: String { String(decoding: data, as: UTF8.self) }
        var isEmpty: Bool { data.isEmpty }
    }

    private func debugLog(enabled: Bool = true) -> (DebugLog, Collector) {
        let collector = Collector()
        let log = DebugLog(enabled: enabled, sink: { collector.append($0) })
        return (log, collector)
    }

    private func testPlatform(slug: String? = nil) -> Platform {
        Platform(appVersion: "1.0.0", os: "macos", osVersion: "15.1.0", arch: "arm64", slug: slug)
    }

    /// A minimal, valid-JSON event blob of exactly `targetBytes`, used only to exercise
    /// `Envelope.envelope`'s byte accounting -- `envelope` never parses its inputs.
    private func paddedEventJSON(targetBytes: Int) -> Data {
        let overhead = "{\"id\":\"\"}".utf8.count // 9
        let padLength = max(0, targetBytes - overhead)
        let json = "{\"id\":\"" + String(repeating: "a", count: padLength) + "\"}"
        return Data(json.utf8)
    }

    /// Extracts the raw `"props":{...}` substring from a produced event body, for a byte-level
    /// (not `JSONSerialization`-mediated) comparison between two encodings.
    private func rawPropsSubstring(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\"props\":") else { return nil }
        let after = text[start.upperBound...]
        guard after.first == "{" else { return nil }
        var depth = 0
        for idx in after.indices {
            if after[idx] == "{" { depth += 1 }
            if after[idx] == "}" {
                depth -= 1
                if depth == 0 { return String(after[after.startIndex...idx]) }
            }
        }
        return nil
    }


    func testPredicateAcceptRejectTable() {
        for accept in ["good_name"] { XCTAssertTrue(Grammar.isEventName(accept)) }
        for reject in ["Bad Name!"] { XCTAssertFalse(Grammar.isEventName(reject)) }

        for accept in ["permissions", "driver", "tour", "x"] { XCTAssertTrue(Grammar.isOnboardingStep(accept)) }
        for reject in ["Bad Step!"] { XCTAssertFalse(Grammar.isOnboardingStep(reject)) }

        for accept in ["no_kext"] { XCTAssertTrue(Grammar.isOnboardingReason(accept)) }
        for reject in ["Free text reason"] { XCTAssertFalse(Grammar.isOnboardingReason(reject)) }

        for accept in ["license", "edition", "page", "n", "ok"] { XCTAssertTrue(Grammar.isPropKey(accept)) }
        for reject in ["Email"] { XCTAssertFalse(Grammar.isPropKey(reject)) }

        for accept in ["trial", "paid", "pro"] { XCTAssertTrue(Grammar.isInstallPropValue(accept)) }
        for reject in [String(repeating: "a", count: 30)] { XCTAssertFalse(Grammar.isInstallPropValue(reject)) }

        for accept in ["refhost/0.1.0+conformance", "swift/0.1.0"] { XCTAssertTrue(Grammar.isClientVersion(accept)) }
        for reject in ["1.2.0", "Electron/1.0", ""] { XCTAssertFalse(Grammar.isClientVersion(reject)) }

        for accept in ["mac", "win", "helper"] { XCTAssertTrue(Grammar.isAppSlug(accept)) }
        for reject in ["Mac"] { XCTAssertFalse(Grammar.isAppSlug(reject)) }
    }


    func testTrailingNewlineRejectedByEveryGrammar() {
        XCTAssertTrue(Grammar.isEventName("good_name"))
        XCTAssertFalse(Grammar.isEventName("good_name\n"))

        XCTAssertTrue(Grammar.isOnboardingStep("driver"))
        XCTAssertFalse(Grammar.isOnboardingStep("driver\n"))

        XCTAssertTrue(Grammar.isOnboardingReason("no_kext"))
        XCTAssertFalse(Grammar.isOnboardingReason("no_kext\n"))

        XCTAssertTrue(Grammar.isPropKey("license"))
        XCTAssertFalse(Grammar.isPropKey("license\n"))

        XCTAssertTrue(Grammar.isInstallPropValue("trial"))
        XCTAssertFalse(Grammar.isInstallPropValue("trial\n"))

        XCTAssertTrue(Grammar.isClientVersion("swift/0.1.0"))
        XCTAssertFalse(Grammar.isClientVersion("swift/0.1.0\n"))

        XCTAssertTrue(Grammar.isAppSlug("mac"))
        XCTAssertFalse(Grammar.isAppSlug("mac\n"))

        XCTAssertTrue(Grammar.isJSONNumberLiteral("1.5"))
        XCTAssertFalse(Grammar.isJSONNumberLiteral("1.5\n"))
    }


    func testBoundaryLengths() {
        XCTAssertTrue(Grammar.isEventName(String(repeating: "a", count: 64)))
        XCTAssertFalse(Grammar.isEventName(String(repeating: "a", count: 65)))

        XCTAssertTrue(Grammar.isPropKey(String(repeating: "a", count: 32)))
        XCTAssertFalse(Grammar.isPropKey(String(repeating: "a", count: 33)))

        XCTAssertTrue(Grammar.isInstallPropValue(String(repeating: "a", count: 24)))
        XCTAssertFalse(Grammar.isInstallPropValue(String(repeating: "a", count: 25)))

        XCTAssertTrue(Grammar.isOnboardingStep(String(repeating: "a", count: 32)))
        XCTAssertFalse(Grammar.isOnboardingStep(String(repeating: "a", count: 33)))

        XCTAssertTrue(Grammar.isAppSlug(String(repeating: "a", count: 32)))
        XCTAssertFalse(Grammar.isAppSlug(String(repeating: "a", count: 33)))

        XCTAssertTrue(Grammar.isClientVersion("a/" + String(repeating: "a", count: 24)))
        XCTAssertFalse(Grammar.isClientVersion("a/" + String(repeating: "a", count: 25)))

        // reason 64/65: WireGate.onboarding's own cap, not Grammar.isOnboardingReason's --
        // the grammar itself has no upper bound (`^[a-z0-9_.-]+$`).
        let (log64, _) = debugLog()
        XCTAssertNotNil(WireGate.onboarding(step: "x", status: "ok", reason: String(repeating: "a", count: 64), log: log64))
        let (log65, _) = debugLog()
        XCTAssertNil(WireGate.onboarding(step: "x", status: "ok", reason: String(repeating: "a", count: 65), log: log65))

        XCTAssertFalse(Grammar.isEventName(""))
        XCTAssertFalse(Grammar.isPropKey(""))
        XCTAssertFalse(Grammar.isInstallPropValue(""))
        XCTAssertFalse(Grammar.isOnboardingStep(""))
        XCTAssertFalse(Grammar.isOnboardingReason(""))
        XCTAssertFalse(Grammar.isClientVersion(""))
        XCTAssertFalse(Grammar.isAppSlug(""))
        XCTAssertFalse(Grammar.isJSONNumberLiteral(""))

        // isClientVersion's total-length clause (round-2 note 1).
        XCTAssertTrue(Grammar.isClientVersion(String(repeating: "a", count: 24) + "/1.0.0")) // 30 total
        XCTAssertFalse(Grammar.isClientVersion(String(repeating: "a", count: 27) + "/1.0.0")) // 33 total
    }

    // The SDK's own `v` satisfies W4's global check.

    func testSDKClientVersionSatisfiesItsOwnGrammar() {
        XCTAssertTrue(Grammar.isClientVersion(Wire.sdkClientVersion))
    }


    func testJSONNumberLiteralAcceptReject() {
        for accept in ["0", "-1", "1.5", "29.90", "1e3", "-2.5E-4", "99999999999999999999"] {
            XCTAssertTrue(Grammar.isJSONNumberLiteral(accept), accept)
        }
        for reject in ["", "01", "+1", ".5", "1.", "0x10", "1,5", "NaN", "1 2"] {
            XCTAssertFalse(Grammar.isJSONNumberLiteral(reject), reject)
        }
    }

    // W2 -- eventName.

    func testW2EventNameGate() {
        let (log1, collector1) = debugLog()
        XCTAssertNil(WireGate.eventName("Bad Name!", log: log1))
        XCTAssertTrue(collector1.text.contains("^[a-z0-9_:.-]{1,64}$"))

        let (log2, collector2) = debugLog()
        XCTAssertEqual(WireGate.eventName("good_name", log: log2), "good_name")
        XCTAssertTrue(collector2.isEmpty)
    }

    // W3 -- validateTrackProps.

    func testW3ValidateTrackProps() {
        let (log, collector) = debugLog()
        let longValue = String(repeating: "a", count: 201)
        XCTAssertFalse(WireGate.validateTrackProps(["k": .string(longValue)], eventName: "x", log: log))

        var manyKeys: [String: WireValue] = [:]
        for i in 1...21 { manyKeys["k\(i)"] = .string("a") }
        XCTAssertFalse(WireGate.validateTrackProps(manyKeys, eventName: "y", log: log))

        XCTAssertTrue(collector.text.contains("spec/wire-v1.md §3 caps a string at 200"))
        XCTAssertTrue(collector.text.contains("spec/wire-v1.md §3 caps them at 20"))

        let (log2, _) = debugLog()
        XCTAssertTrue(WireGate.validateTrackProps(nil, eventName: "z", log: log2))
    }

    // C20b -- onboarding.

    func testC20bOnboardingGate() {
        let (log, collector) = debugLog()
        XCTAssertNil(WireGate.onboarding(step: "Bad Step!", status: "ok", reason: nil, log: log))
        XCTAssertNil(WireGate.onboarding(step: "x", status: "ok", reason: "Free text reason", log: log))
        XCTAssertTrue(collector.text.contains("^[a-z0-9_-]{1,32}$"))
        XCTAssertTrue(collector.text.contains("^[a-z0-9_.-]+$"))
    }

    // C22c -- installProps.

    func testC22cInstallPropsGate() {
        let (log, collector) = debugLog()
        XCTAssertTrue(WireGate.installProps(["Email": "x@y.z"], log: log).isEmpty)
        let longValue = String(repeating: "a", count: 30)
        XCTAssertTrue(WireGate.installProps(["license": longValue], log: log).isEmpty)
        XCTAssertTrue(collector.text.contains("^[a-z0-9_]{1,32}$"))
        XCTAssertTrue(collector.text.contains("^[a-z0-9_.-]{1,24}$"))

        let (log2, collector2) = debugLog()
        let accepted = WireGate.installProps(["license": "trial", "edition": "pro"], log: log2)
        XCTAssertEqual(accepted, ["license": "trial", "edition": "pro"])
        XCTAssertTrue(collector2.isEmpty)
    }

    // W4 -- clientVersion.

    func testW4ClientVersionGate() {
        let (log1, _) = debugLog()
        XCTAssertEqual(WireGate.clientVersion(override: nil, log: log1), Wire.sdkClientVersion)

        let (log2, collector2) = debugLog()
        XCTAssertNil(WireGate.clientVersion(override: "1.2.0", log: log2))
        XCTAssertTrue(collector2.text.contains("^[a-z]+/[0-9A-Za-z.+-]{1,24}$"))

        let (log3, _) = debugLog()
        XCTAssertNil(WireGate.clientVersion(override: "Electron/1.0", log: log3))

        let (log4, collector4) = debugLog()
        XCTAssertNil(WireGate.clientVersion(override: "", log: log4))
        XCTAssertTrue(collector4.isEmpty)

        let (log5, collector5) = debugLog()
        XCTAssertEqual(WireGate.clientVersion(override: "refhost/0.1.0+conformance", log: log5), "refhost/0.1.0+conformance")
        XCTAssertTrue(collector5.isEmpty)
    }

    // C21 -- appSlug.

    func testC21AppSlugGate() {
        let (log1, _) = debugLog()
        XCTAssertEqual(WireGate.appSlug("mac", log: log1), "mac")

        let (log2, collector2) = debugLog()
        XCTAssertNil(WireGate.appSlug(nil, log: log2))
        XCTAssertTrue(collector2.isEmpty)

        let (log3, collector3) = debugLog()
        XCTAssertNil(WireGate.appSlug("", log: log3))
        XCTAssertTrue(collector3.isEmpty)

        let (log4, collector4) = debugLog()
        XCTAssertNil(WireGate.appSlug("Mac", log: log4))
        XCTAssertTrue(collector4.text.contains("^[a-z0-9-]{1,32}$"))
    }


    func testOnboardingShape() {
        let (log, _) = debugLog()

        let permissions = WireGate.onboarding(step: "permissions", status: "ok", reason: nil, log: log)
        XCTAssertEqual(permissions?.name, "onboarding:permissions")
        XCTAssertEqual(permissions?.props, ["status": .string("ok")])

        let driver = WireGate.onboarding(step: "driver", status: "fail", reason: "no_kext", log: log)
        XCTAssertEqual(driver?.name, "onboarding:driver")
        XCTAssertEqual(driver?.props, ["status": .string("fail"), "reason": .string("no_kext")])

        let tour = WireGate.onboarding(step: "tour", status: "skip", reason: nil, log: log)
        XCTAssertEqual(tour?.props.count, 1)

        XCTAssertNil(WireGate.onboarding(step: "x", status: "done", reason: nil, log: log))
    }


    func testDisabledDebugLogWritesNothing() {
        let (log, collector) = debugLog(enabled: false)
        log.log("x")
        log.payload(Data("{}".utf8))
        XCTAssertTrue(collector.isEmpty)
    }


    func testEnablingAfterConstructionTurnsWritingOn() {
        let (log, collector) = debugLog(enabled: false)
        log.log("first")
        XCTAssertTrue(collector.isEmpty)
        log.isEnabled = true
        log.log("second")
        XCTAssertFalse(collector.isEmpty)
    }


    func testLogWritesExactLine() {
        let (log, collector) = debugLog()
        log.log("hello")
        XCTAssertEqual(collector.text, "jelto: hello\n")
    }

    // C17 -- payload contains the body verbatim.

    func testPayloadContainsBodyVerbatim() {
        let (log, collector) = debugLog()
        var body = Data("{\"k\":\"v\\\"\\\\\"}".utf8)
        body.append(contentsOf: "é".utf8)
        body.append(Data(repeating: 0x61, count: 60_000))
        log.payload(body)
        XCTAssertNotNil(collector.data.range(of: body))
    }


    func testDisplayCollapsesControlCharactersAndTruncatesNoNewline() {
        let input = "a\u{0000}b\n" + String(repeating: "x", count: 200)
        let result = DebugLog.display(input)
        XCTAssertFalse(result.contains("\n"))
        XCTAssertTrue(result.hasPrefix("\"a?b?"))
        XCTAssertTrue(result.hasSuffix("…\""))
    }

    // C15b -- t is the literal, raw.

    func testC15bBigPositiveLiteralOnWire() {
        let t = Instant(decimal: "99999999999999999999")!
        let event = QueuedEvent(id: "id", name: "x", t: t, props: nil, isHeartbeat: false)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"t\":99999999999999999999"))
    }

    func testC15bNegativeLiteralOnWire() {
        let t = Instant(decimal: "-14256000000")!
        let event = QueuedEvent(id: "id", name: "x", t: t, props: nil, isHeartbeat: false)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"t\":-14256000000"))
    }

    func testNormalInstantEmitsDescriptionExactly() {
        let t = Instant(1_788_134_400_000)
        let event = QueuedEvent(id: "id", name: "x", t: t, props: nil, isHeartbeat: false)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"t\":\(t.description)"))
    }

    // W1 -- prop number literals kept unrounded.

    func testPropNumberLiteralsKeptUnrounded() {
        let e1 = QueuedEvent(id: "id", name: "x", t: Instant(0), props: ["n": .number("1.5")], isHeartbeat: false)
        let b1 = Envelope.event(e1, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: b1, as: UTF8.self).contains("\"n\":1.5"))

        let e2 = QueuedEvent(id: "id", name: "x", t: Instant(0), props: ["n": .number("29.90")], isHeartbeat: false)
        let b2 = Envelope.event(e2, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: b2, as: UTF8.self).contains("\"n\":29.90"))
    }

    // C20 -- onboarding/track congruence.

    func testC20Congruence() {
        let (log, _) = debugLog()
        guard let built = WireGate.onboarding(step: "permissions", status: "ok", reason: nil, log: log) else {
            return XCTFail("onboarding should not be rejected")
        }
        let platform = testPlatform()
        let installID = "iid-fixed"
        let clientVersion = Wire.sdkClientVersion

        let eventA = QueuedEvent(id: "id-a", name: built.name, t: Instant(1_000), props: built.props, isHeartbeat: false)
        let eventB = QueuedEvent(id: "id-b", name: "onboarding:permissions", t: Instant(2_000), props: ["status": .string("ok")], isHeartbeat: false)

        let bodyA = Envelope.event(eventA, platform: platform, clientVersion: clientVersion, installID: installID, installProps: [:])
        let bodyB = Envelope.event(eventB, platform: platform, clientVersion: clientVersion, installID: installID, installProps: [:])

        let objA = try! JSONSerialization.jsonObject(with: bodyA) as! [String: Any]
        let objB = try! JSONSerialization.jsonObject(with: bodyB) as! [String: Any]

        let keys = Set(objA.keys).union(objB.keys)
        for key in keys where key != "id" && key != "t" {
            XCTAssertEqual("\(objA[key] ?? "<absent>")", "\(objB[key] ?? "<absent>")", "key \(key) differs")
        }

        XCTAssertEqual(rawPropsSubstring(bodyA), rawPropsSubstring(bodyB))
        XCTAssertNotNil(rawPropsSubstring(bodyA))
    }


    func testDeterministicPropsOrder() {
        var propsA: [String: WireValue] = [:]
        propsA["b"] = .string("2")
        propsA["a"] = .string("1")
        propsA["c"] = .number("3")

        var propsB: [String: WireValue] = [:]
        propsB["c"] = .number("3")
        propsB["a"] = .string("1")
        propsB["b"] = .string("2")

        let platform = testPlatform()
        let eventA = QueuedEvent(id: "id", name: "x", t: Instant(0), props: propsA, isHeartbeat: false)
        let eventB = QueuedEvent(id: "id", name: "x", t: Instant(0), props: propsB, isHeartbeat: false)

        let bodyA = Envelope.event(eventA, platform: platform, clientVersion: nil, installID: "iid", installProps: [:])
        let bodyB = Envelope.event(eventB, platform: platform, clientVersion: nil, installID: "iid", installProps: [:])

        XCTAssertEqual(bodyA, bodyB)
    }


    func testJSONEscapingRoundTrips() {
        let original = "a\"b\\c\n\td\u{0000}\u{001F}\u{007F}é😀"
        let props: [String: WireValue] = ["k": .string(original)]
        let event = QueuedEvent(id: "id", name: "x", t: Instant(0), props: props, isHeartbeat: false)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])

        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let propsObj = obj["props"] as! [String: Any]
        XCTAssertEqual(propsObj["k"] as? String, original)
    }

    // C22c -- props absence, never `{}`.

    func testAbsentPropsKeyWhenEmpty() {
        let platform = testPlatform()

        let heartbeat = QueuedEvent(id: "id1", name: "heartbeat", t: Instant(0), props: nil, isHeartbeat: true)
        let heartbeatBody = Envelope.event(heartbeat, platform: platform, clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: heartbeatBody, as: UTF8.self).contains("\"props\""))

        let nilProps = QueuedEvent(id: "id2", name: "x", t: Instant(0), props: nil, isHeartbeat: false)
        let nilBody = Envelope.event(nilProps, platform: platform, clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: nilBody, as: UTF8.self).contains("\"props\""))

        let emptyProps = QueuedEvent(id: "id3", name: "x", t: Instant(0), props: [:], isHeartbeat: false)
        let emptyBody = Envelope.event(emptyProps, platform: platform, clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: emptyBody, as: UTF8.self).contains("\"props\""))
    }

    // C22 resolution -- heartbeat vs non-heartbeat props source.

    func testHeartbeatUsesInstallPropsIgnoresEventProps() {
        let event = QueuedEvent(id: "id", name: "heartbeat", t: Instant(0), props: ["ignored": .string("x")], isHeartbeat: true)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: ["license": "trial"])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"license\":\"trial\""))
        XCTAssertFalse(text.contains("ignored"))
    }

    func testNonHeartbeatUsesEventPropsIgnoresInstallProps() {
        let event = QueuedEvent(id: "id", name: "x", t: Instant(0), props: ["k": .string("v")], isHeartbeat: false)
        let body = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: ["license": "trial"])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"k\":\"v\""))
        XCTAssertFalse(text.contains("license"))
    }

    // C21 / W4 -- field presence.

    func testSlugAndClientVersionFieldPresence() {
        let event = QueuedEvent(id: "id", name: "x", t: Instant(0), props: nil, isHeartbeat: false)

        let withSlug = Envelope.event(event, platform: testPlatform(slug: "mac"), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: withSlug, as: UTF8.self).contains("\"a\":\"mac\""))

        let withoutSlug = Envelope.event(event, platform: testPlatform(slug: nil), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: withoutSlug, as: UTF8.self).contains("\"a\":"))

        let noCV = Envelope.event(event, platform: testPlatform(), clientVersion: nil, installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: noCV, as: UTF8.self).contains("\"v\":"))

        let emptyCV = Envelope.event(event, platform: testPlatform(), clientVersion: "", installID: "iid", installProps: [:])
        XCTAssertFalse(String(decoding: emptyCV, as: UTF8.self).contains("\"v\":"))

        let withCV = Envelope.event(event, platform: testPlatform(), clientVersion: "refhost/0.1.0+conformance", installID: "iid", installProps: [:])
        XCTAssertTrue(String(decoding: withCV, as: UTF8.self).contains("\"v\":\"refhost/0.1.0+conformance\""))
    }


    func testEveryEventCarriesAppFields() {
        let platform = testPlatform()
        let events: [QueuedEvent] = [
            QueuedEvent(id: "1", name: "heartbeat", t: Instant(0), props: nil, isHeartbeat: true),
            QueuedEvent(id: "2", name: "install", t: Instant(0), props: nil, isHeartbeat: false),
            QueuedEvent(id: "3", name: "onboarding:permissions", t: Instant(0), props: ["status": .string("ok")], isHeartbeat: false),
            QueuedEvent(id: "4", name: "custom_event", t: Instant(0), props: nil, isHeartbeat: false),
        ]
        for event in events {
            let body = Envelope.event(event, platform: platform, clientVersion: nil, installID: "iid-value", installProps: [:])
            let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(obj["s"] as? String, "app")
            XCTAssertEqual(obj["iid"] as? String, "iid-value")
            XCTAssertEqual(obj["av"] as? String, platform.appVersion)
            XCTAssertEqual(obj["os"] as? String, platform.os)
            XCTAssertEqual(obj["osv"] as? String, platform.osVersion)
            XCTAssertEqual(obj["arch"] as? String, platform.arch)
        }
    }


    func testEnvelopeCaps250SmallEvents() {
        let events = (0..<250).map { _ in paddedEventJSON(targetBytes: 330) }
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: events)
        XCTAssertEqual(used, 100)
        XCTAssertLessThanOrEqual(body.count, Wire.maxBodyBytes)
        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual((obj["e"] as! [Any]).count, used)
    }

    func testEnvelopeCaps200MediumEvents() {
        let events = (0..<200).map { _ in paddedEventJSON(targetBytes: 1_500) }
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: events)
        XCTAssertLessThan(used, 100)
        XCTAssertLessThanOrEqual(body.count, Wire.maxBodyBytes)
        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual((obj["e"] as! [Any]).count, used)
    }

    func testEnvelopeZeroEvents() {
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: [])
        XCTAssertEqual(used, 0)
        XCTAssertTrue(body.isEmpty)
    }

    func testEnvelopeOneOversizedEvent() {
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: [paddedEventJSON(targetBytes: 70_000)])
        XCTAssertEqual(used, 0)
        XCTAssertTrue(body.isEmpty)
    }


    func testEnvelopeShapePrefixSuffix() {
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: [paddedEventJSON(targetBytes: 50)])
        XCTAssertEqual(used, 1)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"v\":1,\"p\":\"prd_conform001\",\"e\":["))
        XCTAssertTrue(text.hasSuffix("]}"))
    }

    func testEnvelopeProductKeyEscaped() {
        let (body, used) = Envelope.envelope(productKey: "prd_\"quote\"", events: [paddedEventJSON(targetBytes: 50)])
        XCTAssertEqual(used, 1)
        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["p"] as? String, "prd_\"quote\"")
    }


    func testPlatformDetectOnThisMachine() {
        let (log, collector) = debugLog()
        let platform = Platform.detect(appVersion: nil, slug: nil, log: log)
        XCTAssertNotNil(platform)
        guard let platform else { return }
        XCTAssertEqual(platform.os, "macos")
        XCTAssertTrue(["arm64", "x64"].contains(platform.arch))
        XCTAssertFalse(platform.appVersion.isEmpty)
        XCTAssertLessThanOrEqual(platform.appVersion.unicodeScalars.count, 32)
        XCTAssertNotNil(platform.osVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression))
        XCTAssertLessThanOrEqual(platform.osVersion.unicodeScalars.count, 32)
        XCTAssertNil(platform.slug)
        XCTAssertTrue(collector.isEmpty)
    }


    func testPlatformAppVersionTruncationAndFallback() {
        let (log, _) = debugLog()

        let long = Platform.detect(appVersion: String(repeating: "9", count: 40), slug: nil, log: log)
        XCTAssertEqual(long?.appVersion.unicodeScalars.count, 32)

        let whitespaceOnly = Platform.detect(appVersion: "   ", slug: nil, log: log)
        XCTAssertEqual(whitespaceOnly?.appVersion.isEmpty, false)

        let empty = Platform.detect(appVersion: "", slug: nil, log: log)
        XCTAssertEqual(empty?.appVersion.isEmpty, false)

        let none = Platform.detect(appVersion: nil, slug: nil, log: log)
        XCTAssertEqual(none?.appVersion.isEmpty, false)
    }
}
