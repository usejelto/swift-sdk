import XCTest
@_spi(Conformance) @testable import Jelto

final class EventQueueTests: XCTestCase {
    private func freshFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("queue.jsonl")
    }

    private func removeQuietly(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func event(_ name: String, ms: Int64, props: [String: WireValue]? = nil) -> QueuedEvent {
        QueuedEvent(id: UUID().uuidString, name: name, t: Instant(ms), props: props, isHeartbeat: false)
    }

    func testAcknowledgementAfterEvictionKeepsUnsentUpdateAcrossReload() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }
        let queue = EventQueue(fileURL: fileURL)
        for index in 0..<1_000 { queue.append(event("old", ms: Int64(index))) }
        let sentIDs = Set(queue.head(100).map(\.id))
        // While POST is blocked, the caller appends enough events to evict its
        // entire batch and put an unsent transition at the new queue head.
        let update = event("app_updated", ms: 2_000,
            props: ["from_version": .string("A"), "to_version": .string("B")])
        queue.append(update)
        for index in 0..<999 { queue.append(event("new", ms: Int64(2_001 + index))) }
        queue.remove(ids: sentIDs)
        XCTAssertEqual(queue.head(1).first?.id, update.id)
        let restored = EventQueue(fileURL: fileURL)
        restored.load()
        XCTAssertEqual(restored.head(1).first?.id, update.id)
        XCTAssertEqual(restored.count, 1_000)
    }

    func testDiscardedTransitionReceiptSurvivesEmptyQueueCompaction() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }
        let queue = EventQueue(fileURL: fileURL)
        let update = event("app_updated", ms: 2_000,
            props: ["from_version": .string("A"), "to_version": .string("B")])
        XCTAssertTrue(queue.persistTransition(update))
        XCTAssertTrue(queue.discardTransitions())

        let restored = EventQueue(fileURL: fileURL)
        restored.load() // Empty queues compact; the receipt must survive that rewrite.
        XCTAssertTrue(restored.persistTransition(update))
        XCTAssertEqual(restored.count, 0)
        XCTAssertEqual(restored.byteCount, 0)
    }

    func testFailedTransitionCheckpointDoesNotPublishReceiptOrEvent() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }
        let queue = EventQueue(fileURL: fileURL)
        let first = event("app_updated", ms: 2_000,
            props: ["from_version": .string("A"), "to_version": .string("B")])
        let next = event("app_updated", ms: 3_000,
            props: ["from_version": .string("B"), "to_version": .string("C")])
        XCTAssertTrue(queue.persistTransition(first))
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        XCTAssertFalse(queue.persistTransition(next))
        XCTAssertEqual(queue.head(10).map(\.id), [first.id])

        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(queue.persistTransition(next))
        let restored = EventQueue(fileURL: fileURL)
        restored.load()
        XCTAssertEqual(restored.head(10).map(\.id), [first.id, next.id])
    }

    // C5 — nothing before init.

    func testNothingTouchedBeforeUsingNonexistentDirectory() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        queue.load()

        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.byteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    // C6 — the row this slice is for.

    func testCapDropsOldestByCountAndBytes() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        var lastDrop = -1
        for i in 0..<1_500 {
            lastDrop = queue.append(event("x\(i)", ms: Int64(1_000_000 + i)))
            if i < 1_000 {
                XCTAssertEqual(lastDrop, 0, "append \(i) should not have dropped")
            } else {
                XCTAssertEqual(lastDrop, 1, "append \(i) should have dropped exactly one")
            }
        }

        XCTAssertEqual(queue.count, 1_000)

        let exported = queue.exportedEvents()
        XCTAssertEqual(exported.first?.name, "x500")
        XCTAssertEqual(exported.last?.name, "x1499")

        let names = Set(exported.map { $0.name })
        XCTAssertTrue(names.contains("x500"))
        XCTAssertTrue(names.contains("x1499"))
        XCTAssertFalse(names.contains("x0"))
        XCTAssertFalse(names.contains("x499"))

        XCTAssertGreaterThan(queue.byteCount, 0)
        XCTAssertLessThanOrEqual(queue.byteCount, 1_048_576)

        // `bytes` is not a `stat`: the dropped lines and their acks are still on disk.
        let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        XCTAssertNotNil(onDiskSize)
        XCTAssertGreaterThan(onDiskSize ?? 0, queue.byteCount)
    }


    func testByteCapBindsBeforeCountCap() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        let bigValue = String(repeating: "a", count: 200)
        var props: [String: WireValue] = [:]
        for i in 0..<20 {
            props["k\(i)"] = .string(bigValue)
        }

        var droppedAny = false
        var i = 0
        while !droppedAny {
            let dropped = queue.append(event("y\(i)", ms: Int64(2_000_000 + i), props: props))
            if dropped > 0 {
                droppedAny = true
            }
            i += 1
            XCTAssertLessThan(i, 1_000, "byte cap should bind well before 1000 events")
        }

        XCTAssertLessThan(queue.count, 1_000)
        XCTAssertLessThanOrEqual(queue.byteCount, 1_048_576)
        XCTAssertFalse(queue.contains(name: "y0"))
    }


    func testAppendOnlyNeverRewrites() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        _ = queue.append(event("first", ms: 3_000_000))

        let firstAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let firstInode = firstAttrs[.systemFileNumber] as? Int else {
            XCTFail("expected a system file number")
            return
        }

        var previousSize = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        var previousBytes = queue.byteCount

        for i in 1..<200 {
            _ = queue.append(event("e\(i)", ms: Int64(3_000_000 + i)))

            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let inode = attrs[.systemFileNumber] as? Int else {
                XCTFail("expected a system file number")
                return
            }
            XCTAssertEqual(inode, firstInode, "a rewrite would change the inode")

            let size = (attrs[.size] as? Int) ?? 0
            let bytes = queue.byteCount
            XCTAssertEqual(size - previousSize, bytes - previousBytes, "size must grow by exactly byteCount's increase")
            previousSize = size
            previousBytes = bytes
        }
    }


    func testHeadRemovesNothing() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        for i in 0..<20 {
            _ = queue.append(event("h\(i)", ms: Int64(4_000_000 + i)))
        }

        let first = queue.head(10).map { $0.id }
        let second = queue.head(10).map { $0.id }

        XCTAssertEqual(first, second)
        XCTAssertEqual(queue.count, 20)
    }


    func testRemoveSurvivesRelaunch() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue1 = EventQueue(fileURL: fileURL)
        for i in 0..<20 {
            _ = queue1.append(event("r\(i)", ms: Int64(5_000_000 + i)))
        }
        queue1.remove(5)
        let byteCountAfterRemove = queue1.byteCount

        let queue2 = EventQueue(fileURL: fileURL)
        queue2.load()

        XCTAssertEqual(queue2.count, 15)
        XCTAssertEqual(queue2.exportedEvents().first?.name, "r5")
        XCTAssertEqual(queue2.byteCount, byteCountAfterRemove)
    }


    func testReloadIsByteIdentical() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue1 = EventQueue(fileURL: fileURL)
        var expected: [(id: String, name: String, t: String, props: [String: WireValue]?)] = []
        for i in 0..<300 {
            let props: [String: WireValue]
            switch i % 3 {
            case 0: props = ["s": .string("paid")]
            case 1: props = ["n": .number("1.5")]
            default: props = ["b": .bool(true)]
            }
            let e = event("m\(i)", ms: Int64(6_000_000 + i), props: props)
            expected.append((id: e.id, name: e.name, t: e.t.description, props: e.props))
            _ = queue1.append(e)
        }
        let byteCountBefore = queue1.byteCount

        let queue2 = EventQueue(fileURL: fileURL)
        queue2.load()

        XCTAssertEqual(queue2.count, 300)
        let got = queue2.exportedEvents()
        XCTAssertEqual(got.count, expected.count)
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.id, e.id)
            XCTAssertEqual(g.name, e.name)
            XCTAssertEqual(g.t.description, e.t)
        }
        XCTAssertEqual(queue2.byteCount, byteCountBefore)
    }


    func testTornLastLineCostsOneEvent() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue1 = EventQueue(fileURL: fileURL)
        for i in 0..<10 {
            _ = queue1.append(event("t\(i)", ms: Int64(7_000_000 + i)))
        }

        let data = try Data(contentsOf: fileURL)
        let truncated = data.prefix(data.count - 5)
        try truncated.write(to: fileURL)

        let queue2 = EventQueue(fileURL: fileURL)
        queue2.load()
        XCTAssertEqual(queue2.count, 9)
        XCTAssertEqual(queue2.exportedEvents().last?.name, "t8")

        _ = queue2.append(event("extra0", ms: 7_000_100))
        _ = queue2.append(event("extra1", ms: 7_000_101))

        let queue3 = EventQueue(fileURL: fileURL)
        queue3.load()
        XCTAssertEqual(queue3.count, 11)
        let names = queue3.exportedEvents().map { $0.name }
        XCTAssertEqual(names.suffix(2), ["extra0", "extra1"])
    }


    func testLoadIsIdempotent() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue1 = EventQueue(fileURL: fileURL)
        for i in 0..<10 {
            _ = queue1.append(event("d\(i)", ms: Int64(8_000_000 + i)))
        }

        let queue2 = EventQueue(fileURL: fileURL)
        queue2.load()
        let countAfterFirstLoad = queue2.count
        let bytesAfterFirstLoad = queue2.byteCount

        queue2.load()

        XCTAssertEqual(countAfterFirstLoad, 10)
        XCTAssertEqual(queue2.count, 10)
        XCTAssertEqual(queue2.byteCount, bytesAfterFirstLoad)
    }


    func testCompactionIsBoundedAndLossless() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        for i in 0..<50 {
            _ = queue.append(event("c\(i)", ms: Int64(9_000_000 + i)))
        }
        queue.remove(50)
        for i in 0..<5 {
            _ = queue.append(event("after\(i)", ms: Int64(9_001_000 + i)))
        }

        XCTAssertEqual(queue.count, 5)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        // 5 live lines plus a small constant — nowhere near what 50+50 dropped/ack lines would be.
        XCTAssertLessThan(size, queue.byteCount + 4_096)

        let queue2 = EventQueue(fileURL: fileURL)
        queue2.load()
        XCTAssertEqual(queue2.count, 5)
        XCTAssertEqual(queue2.exportedEvents().map { $0.name }, (0..<5).map { "after\($0)" })
    }


    func testContainsName() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        _ = queue.append(event("install", ms: 10_000_000))
        XCTAssertTrue(queue.contains(name: "install"))

        queue.remove(1)
        XCTAssertFalse(queue.contains(name: "install"))
    }


    func testDelete() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        for i in 0..<5 {
            _ = queue.append(event("del\(i)", ms: Int64(11_000_000 + i)))
        }

        queue.delete()

        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.byteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + ".tmp"))

        _ = queue.append(event("recreated", ms: 11_000_100))
        XCTAssertEqual(queue.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }


    func testExportQueueHalf() {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        let bigInstant = Instant(decimal: "99999999999999999999")!
        let bigEvent = QueuedEvent(id: "big-id", name: "big", t: bigInstant, props: nil, isHeartbeat: false)
        _ = queue.append(bigEvent)
        _ = queue.append(event("small", ms: 12_000_000))

        let export = StateExport(state: PersistedState(), queueBytes: queue.byteCount, queueEvents: queue.exportedEvents())
        let text = String(decoding: export.jsonData(), as: UTF8.self)

        XCTAssertTrue(text.contains("\"bytes\":\(queue.byteCount)"), text)
        XCTAssertTrue(text.contains("\"99999999999999999999\""), text)
        XCTAssertFalse(text.contains("\"props\""), text)
        XCTAssertFalse(text.contains("\"hb\""), text)

        queue.delete()
        let emptyExport = StateExport(state: PersistedState(), queueBytes: queue.byteCount, queueEvents: queue.exportedEvents())
        let emptyText = String(decoding: emptyExport.jsonData(), as: UTF8.self)
        XCTAssertTrue(emptyText.contains("\"queue\":{\"bytes\":0,\"events\":[]}"), emptyText)
    }

    // A `queue.jsonl` on disk is not trusted input, and a forged
    // `.number` literal must cost only its own line, never be replayed straight into a future
    // request body.

    func testForgedNumberLiteralInReplayDropsThatLineButKeepsTheHonestOne() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        let honest = event("honest_event", ms: 1_000)
        _ = queue.append(honest)

        // A hand-crafted line whose `.number` literal is not RFC 8259 digits (Wire.swift's
        // `appendJSONValue` writes it raw) — if replay trusted it, a future envelope would carry
        // `"amount":1,"iid":"forged"` straight into the wire, splicing an extra key into the body.
        let forgedLine = #"{"hb":false,"id":"forged-id","n":"forged_event","p":{"amount":{"n":"1,\"iid\":\"forged\""}},"t":"2000"}"#
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data((forgedLine + "\n").utf8))
        try handle.close()

        let restored = EventQueue(fileURL: fileURL)
        restored.load()

        XCTAssertEqual(restored.count, 1)
        let ids = restored.exportedEvents().map(\.id)
        XCTAssertEqual(ids, [honest.id])
        XCTAssertFalse(ids.contains("forged-id"))

        let rendered = restored.head(10).map {
            Envelope.event(
                $0, platform: Platform(appVersion: "1.0.0", os: "macos", osVersion: "1", arch: "arm64", slug: nil),
                clientVersion: nil, installID: "install", installProps: [:]
            )
        }
        let (body, used) = Envelope.envelope(productKey: "prd_conform001", events: rendered)
        XCTAssertEqual(used, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: body))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("forged"))
    }

    /// The same replay gate applied to the event NAME: a tampered `n` outside wire §3's grammar
    /// must cost only that line.
    func testForgedEventNameInReplayDropsThatLine() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }

        let queue = EventQueue(fileURL: fileURL)
        let honest = event("honest_event", ms: 1_000)
        _ = queue.append(honest)

        let forgedLine = #"{"hb":false,"id":"forged-name","n":"Not A Valid Name!","p":null,"t":"2000"}"#
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data((forgedLine + "\n").utf8))
        try handle.close()

        let restored = EventQueue(fileURL: fileURL)
        restored.load()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.exportedEvents().map(\.id), [honest.id])
    }

    // The directory mode and every file's mode are RE-ASSERTED, not
    // merely set at creation, and compaction survives a `replaceItemAt` failure without leaving
    // a stray temp file behind.

    func testEveryFileIs0600AfterCompactionAndDirectoryModeIsReasserted() throws {
        let fileURL = freshFileURL()
        let directory = fileURL.deletingLastPathComponent()
        defer { removeQuietly(fileURL) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let queue = EventQueue(fileURL: fileURL)
        for i in 0..<50 {
            _ = queue.append(event("m\(i)", ms: Int64(13_000_000 + i)))
        }
        queue.remove(50) // an empty live set with dead bytes -- `considerCompactionLocked`'s other branch.
        _ = queue.append(event("after", ms: 13_001_000)) // a second append/compaction cycle.

        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)

        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
    }

    // A `queue.jsonl` far past its legitimate ceiling is treated as
    // corrupt: an empty queue, never a crash, never an unbounded read.

    func testOversizedQueueFileLoadsAsEmptyWithoutCrashing() throws {
        let fileURL = freshFileURL()
        defer { removeQuietly(fileURL) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x61, count: 5 << 20) // 5 MiB, past the 4 MiB ceiling.
        try garbage.write(to: fileURL)

        let queue = EventQueue(fileURL: fileURL)
        queue.load()

        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.byteCount, 0)
    }
}
