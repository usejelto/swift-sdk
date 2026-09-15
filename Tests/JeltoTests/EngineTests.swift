import XCTest
@_spi(Conformance) @testable import Jelto

// Exercise relaunch behavior with multiple engines sharing a directory, plus the pre-init barrier.
// Pinned clocks prevent flush deadlines from advancing; endpoints use a closed local port.
final class EngineTests: XCTestCase {
    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Configures the process environment and constructs a fresh `Engine`. `nowMS` pins the
    /// clock (`Engine.init` reads `JELTO_NOW`'s presence as the pin, per §2.0).
    private func makeEngine(stateDir: URL, nowMS: Int64) -> Engine {
        setenv("JELTO_STATE_DIR", stateDir.path, 1)
        setenv("JELTO_NOW", String(nowMS), 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1) // a closed port; nothing leaves the machine.
        unsetenv("JELTO_DEBUG")
        unsetenv("JELTO_MOCK")
        unsetenv("JELTO_CLIENT_VERSION")
        return Engine()
    }

    /// `exportState()` waits on the ready latch (Appendix C) before reading, so this doubles as
    /// the deterministic "wait for bootstrap to finish" every test needs.
    private func decodeExport(_ engine: Engine) throws -> [String: Any] {
        let data = engine.exportState()
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            struct NotAnObject: Error {}
            throw NotAnObject()
        }
        return dict
    }

    private func queueEvents(_ export: [String: Any]) -> [[String: Any]] {
        (export["queue"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
    }

    private func heartbeatCount(_ export: [String: Any]) -> Int {
        queueEvents(export).filter { ($0["n"] as? String) == "heartbeat" }.count
    }

    // `init` is once-only (C3 asserts it across processes; this is the within-process half).

    func testInitIsOnceOnly() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)

        engine.initialize(key: "prd_conform001", app: nil)
        let export1 = try decodeExport(engine)
        let id1 = export1["install_id"] as? String
        XCTAssertNotNil(id1)
        XCTAssertFalse(id1?.isEmpty ?? true)
        XCTAssertEqual(heartbeatCount(export1), 1)

        engine.initialize(key: "prd_conform001", app: nil) // once-only: must be a no-op.
        let export2 = try decodeExport(engine)
        XCTAssertEqual(export2["install_id"] as? String, id1)
        XCTAssertEqual(heartbeatCount(export2), 1) // still exactly one -- no second bootstrap ran.
    }

    // `disable()` gates, and the next `init` re-arms (§8.7 item 18's second half — C18).

    func testDisableGatesAndReinitReArms() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)

        engine.initialize(key: "prd_conform001", app: nil)
        _ = try decodeExport(engine) // wait for bootstrap.

        engine.disable()
        XCTAssertEqual(engine.installID(), "")
        let contentsAfterDisable = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["not-empty"]
        XCTAssertEqual(contentsAfterDisable, [])

        engine.track(name: "x", props: nil) // must be a no-op: the gate is closed until the next `init`.
        let contentsAfterTrack = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["not-empty"]
        XCTAssertEqual(contentsAfterTrack, [])

        engine.initialize(key: "prd_conform001", app: nil) // the re-arm.
        _ = try decodeExport(engine) // wait for the re-arm's bootstrap.
        XCTAssertFalse(engine.installID().isEmpty)

        engine.track(name: "y", props: nil)
        let export = try decodeExport(engine)
        XCTAssertTrue(queueEvents(export).contains { ($0["n"] as? String) == "y" })
    }

    // The day-rollover heartbeat rule (C3, C22's persistence arm).

    func testDayRolloverHeartbeatRule() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let dayOneMS: Int64 = 1_788_134_400_000 // an exact UTC-midnight boundary.
        let dayTwoMS: Int64 = 1_788_220_800_000 // dayOneMS + 24h.

        let engine1 = makeEngine(stateDir: dir, nowMS: dayOneMS)
        engine1.initialize(key: "prd_conform001", app: nil)
        let export1 = try decodeExport(engine1)
        XCTAssertEqual(heartbeatCount(export1), 1)
        XCTAssertEqual(export1["last_heartbeat_day"] as? String, String(dayOneMS / 86_400_000))

        // A second `Engine`, same directory, same instant: no second heartbeat.
        let engine2 = makeEngine(stateDir: dir, nowMS: dayOneMS)
        engine2.initialize(key: "prd_conform001", app: nil)
        let export2 = try decodeExport(engine2)
        XCTAssertEqual(heartbeatCount(export2), 1)

        // A third `Engine`, same directory, the next UTC day: a second heartbeat.
        let engine3 = makeEngine(stateDir: dir, nowMS: dayTwoMS)
        engine3.initialize(key: "prd_conform001", app: nil)
        let export3 = try decodeExport(engine3)
        XCTAssertEqual(heartbeatCount(export3), 2)
        XCTAssertEqual(export3["last_heartbeat_day"] as? String, String(dayTwoMS / 86_400_000))
    }

    // The install deadline persists across a relaunch (C4c — a deadline, not a countdown).

    func testInstallDeadlinePersists() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let t0: Int64 = 1_700_000_000_000

        let engine1 = makeEngine(stateDir: dir, nowMS: t0)
        engine1.initialize(key: "prd_conform001", app: nil)
        let export1 = try decodeExport(engine1)
        guard let dueAtString = export1["install_due_at"] as? String, let dueAt = Int64(dueAtString) else {
            XCTFail("install_due_at missing from the export")
            return
        }
        XCTAssertEqual(dueAt, t0)

        let engine2 = makeEngine(stateDir: dir, nowMS: t0 + 25_200_000)
        engine2.initialize(key: "prd_conform001", app: nil)
        let export2 = try decodeExport(engine2)
        XCTAssertEqual(export2["install_due_at"] as? String, dueAtString) // UNCHANGED.
    }

    // The install is enqueued once, and stays once (C4, C4b).

    func testInstallEnqueuedOnce() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let t0: Int64 = 1_700_000_000_000

        let engine1 = makeEngine(stateDir: dir, nowMS: t0)
        engine1.initialize(key: "prd_conform001", app: nil)
        _ = try decodeExport(engine1) // bootstrap draws an immediate deadline at t0.

        // Settle the pump deterministically through the same idle barrier the host uses, rather
        // than a sleep: "tick until quiet."
        let firstSeq = engine1.openBarrier()
        XCTAssertTrue(engine1.awaitBarrier(firstSeq, timeoutMS: 2_000))

        let export = try decodeExport(engine1)
        let installEvents = queueEvents(export).filter { ($0["n"] as? String) == "install" }
        XCTAssertEqual(installEvents.count, 1)

        // Tick again: still exactly one.
        let secondSeq = engine1.openBarrier()
        XCTAssertTrue(engine1.awaitBarrier(secondSeq, timeoutMS: 2_000))
        let export2 = try decodeExport(engine1)
        let installEvents2 = queueEvents(export2).filter { ($0["n"] as? String) == "install" }
        XCTAssertEqual(installEvents2.count, 1)
    }

    // `setProps` with an unchanged value sends no heartbeat (C22b).

    func testSetPropsUnchangedSendsNoHeartbeat() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)
        engine.initialize(key: "prd_conform001", app: nil)
        let baseline = heartbeatCount(try decodeExport(engine)) // 1, from bootstrap's own day heartbeat.

        engine.setProps(["license": "paid"])
        let export1 = try decodeExport(engine)
        XCTAssertEqual(heartbeatCount(export1), baseline + 1)

        engine.setProps(["license": "paid"]) // the SAME value again.
        let export2 = try decodeExport(engine)
        XCTAssertEqual(heartbeatCount(export2), baseline + 1) // unchanged: not a change, no heartbeat.
    }

    // The barrier answers before `init` (§3.7 — this test is the behaviour's only coverage).

    func testBarrierAnswersBeforeInit() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)
        // Deliberately never `initialize`d.

        let seq = engine.openBarrier()
        let start = Date()
        XCTAssertTrue(engine.awaitBarrier(seq, timeoutMS: 100))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5) // "at once", generously bounded.
    }
}
