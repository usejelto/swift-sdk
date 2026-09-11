import Foundation
import XCTest
@_spi(Conformance) @testable import Jelto

final class AppUpdateTests: XCTestCase {
    private let now: Int64 = 1_788_134_400_000

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func engine(_ dir: URL, _ version: String) -> Engine {
        setenv("JELTO_STATE_DIR", dir.path, 1)
        setenv("JELTO_NOW", String(now), 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1)
        setenv("JELTO_APP_VERSION", version, 1)
        unsetenv("JELTO_CLIENT_VERSION")
        let engine = Engine()
        engine.initialize(key: "prd_conform001", app: "desktop")
        _ = engine.exportState()
        return engine
    }

    private func seed(_ dir: URL, version: String? = nil) -> String {
        let id = Identifiers.uuidV4()
        let store = Store(directory: dir)
        XCTAssertTrue(store.commit {
            $0.installID = id
            $0.installClaimed = true
            $0.lastHeartbeatDay = String(now / 86_400_000)
            $0.lastAppVersion = version
            $0.installProps = ["license": "paid"]
        })
        return id
    }

    private func events(_ dir: URL) -> [QueuedEvent] {
        let queue = EventQueue(fileURL: dir.appendingPathComponent("queue.jsonl"))
        queue.load()
        return queue.head(1_000)
    }

    override func tearDown() {
        unsetenv("JELTO_APP_VERSION")
        super.tearDown()
    }

    func testFirstLaunchAndLegacyClaimedInstallOnlyEstablishBaseline() throws {
        for legacy in [false, true] {
            let dir = directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let priorID = legacy ? seed(dir) : nil
            let sdk = engine(dir, "Release A+build.7")
            let state = Store(directory: dir).load()
            XCTAssertEqual(state.lastAppVersion, "Release A+build.7")
            XCTAssertNil(state.pendingUpdate)
            XCTAssertFalse(events(dir).contains { $0.name == "app_updated" })
            if let priorID {
                XCTAssertEqual(sdk.installID(), priorID)
                XCTAssertTrue(state.installClaimed)
                XCTAssertNil(state.installDueAt)
                XCTAssertTrue(events(dir).isEmpty)
            }
        }
    }

    func testSameDayOpaqueChangesDowngradesAndRepeatedLaunches() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = seed(dir, version: "Release B+2")
        for version in ["Release B+2", "Release A", "Release A", "Release B+2", "Release A"] {
            let sdk = engine(dir, version)
            XCTAssertEqual(sdk.installID(), id)
            sdk.initialize(key: "prd_conform001", app: "desktop")
        }
        let queue = events(dir)
        XCTAssertEqual(queue.map(\.name), ["app_updated", "app_updated", "app_updated"])
        XCTAssertEqual(Set(queue.map(\.id)).count, 3)
        XCTAssertEqual(queue.map { $0.props?["to_version"] },
            [.string("Release A"), .string("Release B+2"), .string("Release A")])
        XCTAssertTrue(Store(directory: dir).load().installClaimed)
        XCTAssertEqual(Store(directory: dir).load().lastHeartbeatDay, String(now / 86_400_000))
    }

    func testUnknownVersionDoesNotInventOrEraseBaseline() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir)
        for value in ["", " \n", String(repeating: "x", count: 33)] {
            _ = engine(dir, value)
            XCTAssertNil(Store(directory: dir).load().lastAppVersion)
        }
        _ = engine(dir, "A")
        for value in ["", " \n", String(repeating: "x", count: 33)] {
            _ = engine(dir, value)
            XCTAssertEqual(Store(directory: dir).load().lastAppVersion, "A")
        }
        _ = engine(dir, "B")
        XCTAssertEqual(events(dir).count, 1)
        XCTAssertEqual(events(dir).first?.props?["from_version"], .string("A"))
    }

    func testExactScalarEqualityDoesNotNormalizeUnicodeOrBuildSuffixes() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "é+one")
        _ = engine(dir, "e\u{301}+one")
        _ = engine(dir, "e\u{301}+two")
        XCTAssertEqual(events(dir).count, 2)
        XCTAssertEqual(events(dir).last?.props?["to_version"], .string("e\u{301}+two"))
    }

    func testNonWhitespaceFormatCharacterIsAKnownVersion() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "A")
        // U+200B is not Unicode White_Space, although Foundation's whitespace character
        // set includes it. The server and the SDKs must preserve this valid opaque version.
        _ = engine(dir, "\u{200B}")
        _ = engine(dir, "B")
        let updates = events(dir)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.props?["to_version"], .string("\u{200B}"))
        XCTAssertEqual(updates.last?.props?["from_version"], .string("\u{200B}"))
    }

    func testRecoverIntentBeforeQueueAndKeepMetadataOnLaterLaunch() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = seed(dir, version: "A")
        let queuePath = dir.appendingPathComponent("queue.jsonl")
        // Failed queue persistence leaves the complete B intent and its advanced baseline.
        try FileManager.default.createDirectory(at: queuePath, withIntermediateDirectories: false)
        _ = engine(dir, "B")
        let interrupted = Store(directory: dir).load()
        let intent = try XCTUnwrap(interrupted.pendingUpdate)
        XCTAssertEqual(interrupted.lastAppVersion, "B")
        XCTAssertEqual(intent.context.installID, id)
        try FileManager.default.removeItem(at: queuePath)
        _ = engine(dir, "C")
        let recovered = events(dir)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.first?.id, intent.id)
        XCTAssertEqual(recovered.map { $0.context?.platform.appVersion }, ["B", "C"])
        XCTAssertNil(Store(directory: dir).load().pendingUpdate)
        let later = Platform(appVersion: "Z", os: "windows", osVersion: "changed", arch: "x86", slug: "changed")
        let data = Envelope.event(try XCTUnwrap(recovered.first), platform: later,
            clientVersion: "swift/9", installID: Identifiers.uuidV4(), installProps: [:])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["av"] as? String, "B")
        XCTAssertEqual(body["iid"] as? String, id)
        XCTAssertEqual(body["a"] as? String, "desktop")
        XCTAssertEqual(body["v"] as? String, Wire.sdkClientVersion)
        XCTAssertEqual(body["os"] as? String, intent.context.platform.os)
        XCTAssertEqual(body["osv"] as? String, intent.context.platform.osVersion)
        XCTAssertEqual(body["arch"] as? String, intent.context.platform.arch)
    }

    func testRecoverAlreadyQueuedIntentDoesNotDuplicateItsID() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "A")
        let queuePath = dir.appendingPathComponent("queue.jsonl")
        try FileManager.default.createDirectory(at: queuePath, withIntermediateDirectories: false)
        _ = engine(dir, "B")
        let intent = try XCTUnwrap(Store(directory: dir).load().pendingUpdate)
        try FileManager.default.removeItem(at: queuePath)
        // Crash boundary: queue commit succeeded, intent retirement did not run.
        let queue = EventQueue(fileURL: queuePath)
        XCTAssertTrue(queue.persistTransition(try XCTUnwrap(intent.event)))
        _ = engine(dir, "B")
        _ = engine(dir, "B")
        XCTAssertEqual(events(dir).map(\.id), [intent.id])
        XCTAssertNil(Store(directory: dir).load().pendingUpdate)
    }

    func testFailedStateCommitDoesNotAdvanceInMemoryBaseline() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "A")
        let store = Store(directory: dir)
        _ = store.load()
        let statePath = dir.appendingPathComponent("state.plist")
        try FileManager.default.removeItem(at: statePath)
        try FileManager.default.createDirectory(at: statePath, withIntermediateDirectories: false)
        XCTAssertFalse(store.commit { $0.lastAppVersion = "B" })
        XCTAssertEqual(store.get().lastAppVersion, "A")
        XCTAssertNil(store.get().pendingUpdate)
    }

    func testRecoverCapEvictedIntentDoesNotResurrectTransition() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "A")
        let queuePath = dir.appendingPathComponent("queue.jsonl")
        try FileManager.default.createDirectory(at: queuePath, withIntermediateDirectories: false)
        let blockedSDK = engine(dir, "B")
        XCTAssertTrue(blockedSDK.awaitBarrier(blockedSDK.openBarrier(), timeoutMS: 2_000))
        let intent = try XCTUnwrap(Store(directory: dir).load().pendingUpdate)
        try FileManager.default.removeItem(at: queuePath)

        // The queue commit succeeds, but intent retirement is interrupted. Public track calls
        // can still enqueue while persistence is unavailable and evict the committed update.
        let queue = EventQueue(fileURL: queuePath)
        XCTAssertTrue(queue.persistTransition(try XCTUnwrap(intent.event)))
        for _ in 0..<2_500 {
            queue.append(QueuedEvent(id: Identifiers.uuidV4(), name: "custom", t: Instant(now),
                props: nil, isHeartbeat: false))
        }
        let retainedIDs = queue.head(1_000).map(\.id)
        XCTAssertFalse(retainedIDs.contains(intent.id))

        // Relaunch must retire the intent without reviving an intentionally discarded event
        // or evicting another ordinary event to make room for it (SDK conformance §7).
        _ = engine(dir, "B")
        let recoveredIDs = events(dir).map(\.id)
        XCTAssertFalse(recoveredIDs.contains(intent.id))
        XCTAssertTrue(recoveredIDs.elementsEqual(retainedIDs))
        XCTAssertNil(Store(directory: dir).load().pendingUpdate)
    }

    func testLegacyQueueRecoversReceiptBeforeReplayingCapAcknowledgement() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = seed(dir, version: "A")
        let queuePath = dir.appendingPathComponent("queue.jsonl")
        try FileManager.default.createDirectory(at: queuePath, withIntermediateDirectories: false)
        let blockedSDK = engine(dir, "B")
        XCTAssertTrue(blockedSDK.awaitBarrier(blockedSDK.openBarrier(), timeoutMS: 2_000))
        let intent = try XCTUnwrap(Store(directory: dir).load().pendingUpdate)
        try FileManager.default.removeItem(at: queuePath)

        let queue = EventQueue(fileURL: queuePath)
        XCTAssertTrue(queue.persistTransition(try XCTUnwrap(intent.event)))
        for _ in 0..<1_000 {
            queue.append(QueuedEvent(id: Identifiers.uuidV4(), name: "custom", t: Instant(now),
                props: nil, isHeartbeat: false))
        }
        let retainedIDs = queue.head(1_000).map(\.id)
        // The preceding SDK format has the update line and its cap acknowledgement,
        // but no receipt record. Recovery must remember seeing that ID during replay.
        let data = try Data(contentsOf: queuePath)
        let firstNewline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        try Data(data[data.index(after: firstNewline)...]).write(to: queuePath, options: .atomic)

        _ = engine(dir, "B")
        XCTAssertTrue(events(dir).map(\.id).elementsEqual(retainedIDs))
        XCTAssertNil(Store(directory: dir).load().pendingUpdate)
    }

    func testResetAndDisableDiscardTransitionsAndBaselineNewIdentity() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldID = seed(dir, version: "A")
        let sdk = engine(dir, "B")
        XCTAssertEqual(events(dir).count, 1)
        sdk.reset()
        XCTAssertNotEqual(sdk.installID(), oldID)
        XCTAssertFalse(events(dir).contains { $0.name == "app_updated" })
        XCTAssertEqual(Store(directory: dir).load().lastAppVersion, "B")
        XCTAssertEqual(Store(directory: dir).load().installProps, ["license": "paid"])
        sdk.disable()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        sdk.initialize(key: "prd_conform001", app: "desktop")
        _ = sdk.exportState()
        XCTAssertFalse(events(dir).contains { $0.name == "app_updated" })
        XCTAssertEqual(Store(directory: dir).load().lastAppVersion, "B")
    }

    func testLegacyCommandPreservesClaimAndIdentityAndRequiresInitialization() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = seed(dir, version: "A")
        let sdk = engine(dir, "A")
        XCTAssertTrue(sdk.legacyVersion())
        XCTAssertNil(Store(directory: dir).load().lastAppVersion)
        XCTAssertTrue(Store(directory: dir).load().installClaimed)
        XCTAssertEqual(sdk.installID(), id)
        _ = engine(dir, "B")
        XCTAssertTrue(events(dir).isEmpty)
        XCTAssertFalse(Engine().legacyVersion())
    }
}
