import Foundation
import XCTest
@_spi(Conformance) @testable import Jelto

final class InstallOriginTests: XCTestCase {
    private let now: Int64 = 1_788_134_400_000

    private func engine(_ directory: URL, origin: Jelto.InstallOrigin = .unknown) -> Engine {
        setenv("JELTO_STATE_DIR", directory.path, 1)
        setenv("JELTO_NOW", String(now), 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1)
        setenv("JELTO_APP_VERSION", "1.6.0", 1)
        unsetenv("JELTO_MOCK")
        let sdk = Engine()
        sdk.initialize(key: "prd_conform001", app: "desktop", installOrigin: origin)
        _ = sdk.exportState()
        return sdk
    }

    private func events(_ directory: URL) -> [QueuedEvent] {
        let queue = EventQueue(fileURL: directory.appendingPathComponent("queue.jsonl"))
        queue.load()
        return queue.head(1_000)
    }

    override func tearDown() {
        unsetenv("JELTO_APP_VERSION")
        super.tearDown()
    }

    func testEachOriginIsCapturedOnTheImmediateClaimAndEncodedOnInstallOnly() throws {
        for origin in [Jelto.InstallOrigin.new, .existing, .unknown] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sdk = engine(directory, origin: origin)
            let state = Store(directory: directory).load()
            XCTAssertEqual(state.installOrigin, origin.rawValue)
            XCTAssertEqual(state.installDueAt?.description, String(now))
            let claim = try XCTUnwrap(events(directory).first { $0.name == "install" })
            XCTAssertEqual(claim.props, ["install_origin": .string(origin.rawValue)])
            let context = try XCTUnwrap(claim.context)
            let encoded = Envelope.event(claim, platform: context.platform, clientVersion: context.clientVersion,
                installID: sdk.installID(), installProps: ["license": "paid"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(json["props"] as? [String: String], ["install_origin": origin.rawValue])
            let heartbeat = try XCTUnwrap(events(directory).first { $0.isHeartbeat })
            XCTAssertNil(heartbeat.props?["install_origin"])
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: sdk.exportState()) as? [String: Any])
            XCTAssertEqual(exported["install_origin"] as? String, origin.rawValue)
        }
    }

    func testRelaunchAndRepeatedInitializationCannotReclassifyAQueuedClaim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = engine(directory, origin: .existing)
        let id = first.installID()
        let claim = try XCTUnwrap(events(directory).first { $0.name == "install" })
        first.initialize(key: "prd_conform001", app: "desktop", installOrigin: .new)
        _ = first.exportState()
        let resumed = engine(directory, origin: .new)
        XCTAssertEqual(resumed.installID(), id)
        XCTAssertEqual(Store(directory: directory).load().installOrigin, "existing")
        let retried = try XCTUnwrap(events(directory).first { $0.name == "install" })
        XCTAssertEqual(retried.id, claim.id)
        XCTAssertEqual(retried.t, claim.t)
        XCTAssertEqual(retried.props, claim.props)
        XCTAssertEqual(events(directory).filter { $0.name == "install" }.count, 1)
    }

    func testLegacyPendingAndClaimedStateStayUnknownWithoutChangingTheQueuedEvent() throws {
        for claimed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let id = Identifiers.uuidV4()
            let store = Store(directory: directory)
            XCTAssertTrue(store.commit {
                $0.installID = id
                $0.installClaimed = claimed
                $0.installDueAt = Instant(now - 10_000)
                $0.lastHeartbeatDay = String(now / 86_400_000)
            })
            let queue = EventQueue(fileURL: directory.appendingPathComponent("queue.jsonl"))
            let legacy = QueuedEvent(id: Identifiers.uuidV7(at: Instant(now - 10_000)), name: "install",
                t: Instant(now - 10_000), props: nil, isHeartbeat: false)
            if !claimed { queue.append(legacy) }
            let sdk = engine(directory, origin: .new)
            XCTAssertEqual(sdk.installID(), id)
            XCTAssertEqual(Store(directory: directory).load().installOrigin, "unknown")
            let claims = events(directory).filter { $0.name == "install" }
            XCTAssertEqual(claims.count, claimed ? 0 : 1)
            if !claimed {
                XCTAssertEqual(claims.first?.id, legacy.id)
                XCTAssertNil(claims.first?.props)
            }
        }
    }

    func testResetUsesUnknownAndDisableReinitializationCanCaptureAnotherOrigin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sdk = engine(directory, origin: .new)
        let oldID = sdk.installID()
        sdk.reset()
        _ = sdk.exportState()
        XCTAssertNotEqual(sdk.installID(), oldID)
        XCTAssertEqual(Store(directory: directory).load().installOrigin, "unknown")
        let claims = events(directory).filter { $0.name == "install" }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.props?["install_origin"], .string("unknown"))
        sdk.disable()
        sdk.initialize(key: "prd_conform001", app: "desktop", installOrigin: .existing)
        _ = sdk.exportState()
        XCTAssertEqual(Store(directory: directory).load().installOrigin, "existing")
        XCTAssertEqual(events(directory).first { $0.name == "install" }?.props?["install_origin"], .string("existing"))
    }

    func testOriginIsReservedAndInvalidStoredCategoryDoesNotRotateIdentity() throws {
        let log = DebugLog(enabled: false)
        XCTAssertEqual(WireGate.installProps(["install_origin": "new", "license": "paid"], log: log), ["license": "paid"])
        XCTAssertFalse(WireGate.validateTrackProps(["install_origin": .string("new")], eventName: "heartbeat", log: log))
        XCTAssertFalse(WireGate.validateTrackProps(["install_origin": .string("yesterday")], eventName: "install", log: log))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = Identifiers.uuidV4()
        XCTAssertTrue(Store(directory: directory).commit {
            $0.installID = id
            $0.installOrigin = "not-an-origin"
            $0.installDueAt = Instant(now)
        })
        let sdk = engine(directory, origin: .new)
        XCTAssertEqual(sdk.installID(), id)
        XCTAssertEqual(Store(directory: directory).load().installOrigin, "unknown")
        XCTAssertEqual(events(directory).first { $0.name == "install" }?.props?["install_origin"], .string("unknown"))
    }
}
