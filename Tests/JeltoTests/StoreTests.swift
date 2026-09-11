import XCTest
@_spi(Conformance) @testable import Jelto

final class StoreTests: XCTestCase {
    /// Do NOT create the directory up front — several tests turn on its absence.
    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // C5 — nothing before init.

    func testNothingTouchedBeforeUsingNonexistentDirectory() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }

        let store = Store(directory: dir)
        let loaded = store.load()
        let got = store.get()

        XCTAssertTrue(statesEqual(loaded, PersistedState()))
        XCTAssertTrue(statesEqual(got, PersistedState()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }


    func testRoundTripAllElevenFields() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }

        let bigInstant = Instant(decimal: "99999999999999999999")!
        let negativeInstant = Instant(decimal: "-14256000000")!

        let store1 = Store(directory: dir)
        store1.update { s in
            s.installID = "install-abc"
            s.lastHeartbeatDay = "19345"
            s.installClaimed = true
            s.installDueAt = bigInstant
            s.installFirstTry = negativeInstant
            s.installProps = ["license": "paid"]
            s.backoffStepMS = 1_024_000
            s.backoffNextAt = bigInstant
            s.stopUntil = negativeInstant
            s.stopProbeDue = true
            s.consecutiveRefusals = 7
        }

        let store2 = Store(directory: dir)
        let loaded = store2.load()

        XCTAssertEqual(loaded.installID, "install-abc")
        XCTAssertEqual(loaded.lastHeartbeatDay, "19345")
        XCTAssertTrue(loaded.installClaimed)
        XCTAssertEqual(loaded.installDueAt?.description, "99999999999999999999")
        XCTAssertEqual(loaded.installFirstTry?.description, "-14256000000")
        XCTAssertEqual(loaded.installProps, ["license": "paid"])
        XCTAssertEqual(loaded.backoffStepMS, 1_024_000)
        XCTAssertEqual(loaded.backoffNextAt?.description, "99999999999999999999")
        XCTAssertEqual(loaded.stopUntil?.description, "-14256000000")
        XCTAssertTrue(loaded.stopProbeDue)
        XCTAssertEqual(loaded.consecutiveRefusals, 7)
    }


    func testCorruptPlistIsAbsentPlist() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }

        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateFile = dir.appendingPathComponent("state.plist")
        try! Data((0..<64).map { _ in UInt8.random(in: 0...255) }).write(to: stateFile)

        let store = Store(directory: dir)
        let loaded = store.load()
        XCTAssertTrue(statesEqual(loaded, PersistedState()))
    }


    func testTruncatedPlistIsAbsentPlist() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }

        let store1 = Store(directory: dir)
        store1.update { s in
            s.installID = "install-xyz"
            s.installClaimed = true
        }

        let stateFile = dir.appendingPathComponent("state.plist")
        let data = try! Data(contentsOf: stateFile)
        try! data.prefix(data.count / 2).write(to: stateFile)

        let store2 = Store(directory: dir)
        let loaded = store2.load()
        XCTAssertTrue(statesEqual(loaded, PersistedState()))
    }


    func testWipeEmptiesTheDirectory() {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }

        let store = Store(directory: dir)
        store.update { s in
            s.installID = "install-1"
        }

        try! Data("queue".utf8).write(to: dir.appendingPathComponent("queue.jsonl"))
        try! Data("tmp".utf8).write(to: dir.appendingPathComponent("queue.jsonl.tmp"))

        store.wipe()

        let contents = try! FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(contents.isEmpty)
        XCTAssertTrue(statesEqual(store.get(), PersistedState()))
    }


    func testExportEmptyState() {
        let export = StateExport(state: PersistedState(), queueBytes: 0, queueEvents: [])
        let text = String(decoding: export.jsonData(), as: UTF8.self)

        XCTAssertTrue(text.contains("\"install_id\":\"\""), text)
        XCTAssertTrue(text.contains("\"install_claimed\":false"), text)
        XCTAssertTrue(text.contains("\"stop_probe_due\":false"), text)
        XCTAssertTrue(text.contains("\"queue\":{\"bytes\":0,\"events\":[]}"), text)

        for absentKey in [
            "last_heartbeat_day", "install_due_at", "install_first_try",
            "install_props", "backoff_step_ms", "backoff_next_at", "stop_until",
        ] {
            XCTAssertFalse(text.contains("\"\(absentKey)\":"), "\(absentKey) should be absent in \(text)")
        }
    }

    func testExportPopulatedStateTypesAndValues() {
        var state = PersistedState()
        state.installID = "install-abc"
        state.lastHeartbeatDay = "19345"
        state.installClaimed = true
        state.installDueAt = Instant(decimal: "99999999999999999999")!
        state.installFirstTry = Instant(decimal: "-14256000000")!
        state.installProps = ["license": "paid"]
        state.backoffStepMS = 1_024_000
        state.backoffNextAt = Instant(decimal: "99999999999999999999")!
        state.stopUntil = Instant(decimal: "-14256000000")!
        state.stopProbeDue = true
        state.consecutiveRefusals = 7

        let export = StateExport(state: state, queueBytes: 0, queueEvents: [])
        let data = export.jsonData()
        let text = String(decoding: data, as: UTF8.self)

        // backoff_step_ms is an integer, not a quoted string.
        XCTAssertTrue(text.contains("\"backoff_step_ms\":1024000"), text)
        XCTAssertFalse(text.contains("\"backoff_step_ms\":\""), text)

        // install_claimed is a bool, not a number or string.
        XCTAssertTrue(text.contains("\"install_claimed\":true"), text)
        XCTAssertFalse(text.contains("\"install_claimed\":1"), text)
        XCTAssertFalse(text.contains("\"install_claimed\":\"true\""), text)

        // Every instant is a string carrying the exact decimal literal.
        XCTAssertTrue(text.contains("\"install_due_at\":\"99999999999999999999\""), text)
        XCTAssertTrue(text.contains("\"install_first_try\":\"-14256000000\""), text)
        XCTAssertTrue(text.contains("\"backoff_next_at\":\"99999999999999999999\""), text)
        XCTAssertTrue(text.contains("\"stop_until\":\"-14256000000\""), text)
        XCTAssertTrue(text.contains("\"last_heartbeat_day\":\"19345\""), text)

        XCTAssertTrue(text.contains("\"install_props\":{\"license\":\"paid\"}"), text)

        // consecutiveRefusals appears nowhere.
        XCTAssertFalse(text.lowercased().contains("refusal"), text)
        XCTAssertFalse(text.contains(":7"), text)
        XCTAssertFalse(text.contains(":7}"), text)
        XCTAssertFalse(text.contains(":7,"), text)
    }
}

/// `PersistedState` is not `Equatable` in the target itself (Appendix A does not ask for it);
/// this is a plain comparison helper for the test file, not a retroactive conformance — an
/// explicit `==` witness for `Equatable` declared from a different module (the test target, via
/// `@testable import`) must be `public` to satisfy the protocol, which an internal type cannot be.
private func statesEqual(_ lhs: PersistedState, _ rhs: PersistedState) -> Bool {
    lhs.installID == rhs.installID
        && lhs.lastHeartbeatDay == rhs.lastHeartbeatDay
        && lhs.installClaimed == rhs.installClaimed
        && lhs.installDueAt == rhs.installDueAt
        && lhs.installFirstTry == rhs.installFirstTry
        && lhs.installProps == rhs.installProps
        && lhs.backoffStepMS == rhs.backoffStepMS
        && lhs.backoffNextAt == rhs.backoffNextAt
        && lhs.stopUntil == rhs.stopUntil
        && lhs.stopProbeDue == rhs.stopProbeDue
        && lhs.consecutiveRefusals == rhs.consecutiveRefusals
}
