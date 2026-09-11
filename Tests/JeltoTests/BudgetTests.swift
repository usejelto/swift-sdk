import Darwin
import XCTest
@testable import Jelto

// Verify C11's RSS delta <= 2 MiB and per-track p99 <= 1 ms over 10,000 events.
// The shared harness skips C11; these tests enforce the Swift SDK budget.
// Pinned clocks prevent flush deadlines from advancing, and endpoints use a closed local port.
final class BudgetTests: XCTestCase {
    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Same shape as `EngineTests.makeEngine`: a closed port so nothing ever leaves the machine,
    /// and a pinned clock so no timer ever fires.
    private func makeEngine(stateDir: URL, nowMS: Int64) -> Engine {
        setenv("JELTO_STATE_DIR", stateDir.path, 1)
        setenv("JELTO_NOW", String(nowMS), 1)
        setenv("JELTO_ENDPOINT", "http://127.0.0.1:1/v1/e", 1) // a closed port; nothing leaves the machine.
        unsetenv("JELTO_DEBUG")
        unsetenv("JELTO_MOCK")
        unsetenv("JELTO_CLIENT_VERSION")
        return Engine()
    }

    /// Resident size in KiB via `mach_task_basic_info`, compiled and proved on this
    /// toolchain. No dependency — `Darwin` is stdlib.
    private func residentSizeKB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            XCTFail("task_info failed with kern_return_t \(kr)")
            return 0
        }
        return UInt64(info.resident_size) / 1024
    }

    //
    // The baseline is sampled AFTER `initialize` has bootstrapped (`exportState()` waits on the
    // ready latch), so the figure is what the SDK itself holds once running — the subject of the
    // 2 MB RSS ceiling — rather than what the Swift runtime costs to start.
    func testRSSDeltaBudget() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)

        engine.initialize(key: "prd_budget0001", app: nil)
        _ = engine.exportState() // waits on the ready latch: bootstrap has finished.

        let baselineKB = residentSizeKB()

        for _ in 0..<10_000 {
            engine.track(name: "x", props: nil)
        }

        let afterKB = residentSizeKB()
        let deltaKB = Int64(afterKB) - Int64(baselineKB)

        // Printed unconditionally (not just on failure): the measured number is the evidence C11
        // is discharged, whether the assertion below passes or not.
        print("BudgetTests.testRSSDeltaBudget: baseline=\(baselineKB) KiB after=\(afterKB) KiB delta=\(deltaKB) KiB (ceiling 2048 KiB)")

        // If the budget does not hold, report the measured number and stop — the ceiling is
        // set by the spec, not this test.
        XCTAssertLessThanOrEqual(
            deltaKB, 2_048,
            "RSS delta \(deltaKB) KiB (baseline \(baselineKB) KiB, after \(afterKB) KiB) exceeds the 2 MB ceiling (the SDK's memory and latency budget)"
        )
    }

    func testPerTrackP99Budget() throws {
        let dir = freshDirectory()
        defer { removeQuietly(dir) }
        let engine = makeEngine(stateDir: dir, nowMS: 1_700_000_000_000)

        engine.initialize(key: "prd_budget0001", app: nil)
        _ = engine.exportState() // waits on the ready latch: bootstrap has finished.

        let iterations = 10_000
        var durationsUS = [Double]()
        durationsUS.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            engine.track(name: "x", props: nil)
            let elapsedNS = DispatchTime.now().uptimeNanoseconds - start
            durationsUS.append(Double(elapsedNS) / 1_000)
        }

        durationsUS.sort()
        let p99Index = min(durationsUS.count - 1, Int(Double(durationsUS.count) * 0.99))
        let p99US = durationsUS[p99Index]

        // Printed unconditionally (not just on failure): the measured number is the evidence C11
        // is discharged, whether the assertion below passes or not.
        print("BudgetTests.testPerTrackP99Budget: iterations=\(iterations) track_p99_us=\(p99US) (ceiling 1000 us)")

        // If the budget does not hold, report the measured number and stop — the ceiling is
        // set by the spec, not this test.
        XCTAssertLessThanOrEqual(
            p99US, 1_000,
            "track p99 \(p99US) us exceeds the 1 ms ceiling (the SDK's memory and latency budget)"
        )
    }
}
