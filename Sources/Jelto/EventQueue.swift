// Append-only queue with an in-memory mirror, capped at 1 MB or 1,000 events with the oldest
// dropped first (C11).

import Foundation

/// A single property value, keeping the literal it was given rather than a parsed `Double` — W1
/// sends `{"n":1.5}` and nothing in this SDK turns a wire number into a `Double`. `Codable` here
/// is this file's queue-line encoding (`{"s":...}` / `{"n":...}` / `{"b":...}`), not the wire
/// encoding, which is a separate function.
@_spi(Conformance) public enum WireValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case bool(Bool)
}

extension WireValue: Codable {
    private enum CodingKeys: String, CodingKey { case s, n, b }

    @_spi(Conformance) public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .s) {
            self = .string(s)
        } else if let n = try c.decodeIfPresent(String.self, forKey: .n) {
            self = .number(n)
        } else if let b = try c.decodeIfPresent(Bool.self, forKey: .b) {
            self = .bool(b)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .s, in: c, debugDescription: "WireValue: none of s/n/b present"
            )
        }
    }

    @_spi(Conformance) public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try c.encode(v, forKey: .s)
        case .number(let v): try c.encode(v, forKey: .n)
        case .bool(let v): try c.encode(v, forKey: .b)
        }
    }
}

/// `id`, `name`, `t` are fixed at enqueue and are never regenerated: wire §6 makes a retry resend
/// the same batch with the same `id`s. `isHeartbeat` marks the events whose install properties
/// are resolved at SEND time, never frozen here (C22's first heartbeat carries a `license` set
/// after it was enqueued) — this file stores the flag and does nothing else with it.
struct EventContext: Sendable, Codable {
    let platform: Platform
    let clientVersion: String?
    // Only transitions freeze identity. Reset keeps existing ordinary-event behavior.
    var installID: String? = nil
}

struct QueuedEvent: Sendable {
    let id: String
    let name: String
    let t: Instant
    let props: [String: WireValue]?
    let isHeartbeat: Bool
    var context: EventContext? = nil
}

/// One JSON object per line. `p` is omitted (not `null`) when `props` is nil — Swift's
/// synthesised `Codable` calls `encodeIfPresent`/`decodeIfPresent` for `Optional` stored
/// properties, so this is safe to leave synthesised. `t` is a decimal string, never a JSON
/// number (C15b).
private struct QueueEventLine: Codable {
    var hb: Bool
    var id: String
    var n: String
    var p: [String: WireValue]?
    var t: String
    var context: EventContext? = nil
}

/// "The first `n` live events are gone, forever." Both ways an event leaves the head — `remove`
/// after a `202`/final refusal, and the cap dropping the oldest — append one of these.
private struct QueueAckLine: Codable {
    var ack: Int
}

/// The latest intent installed in the queue. It survives removal of that event so recovery
/// can distinguish an intentionally evicted transition from one never committed to the queue.
/// Only one state intent is outstanding at a time, so one receipt is sufficient.
private struct QueueTransitionReceipt: Codable {
    var transitionID: String
}

/// NSLock is non-recursive: Locked helpers access stored properties directly.
/// Never call locking accessors from them; public internal entry points acquire the lock once.
final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let tmpFileURL: URL

    // Stored properties (§4.3). Only these are touched by `…Locked` helpers.

    /// Keep events and encoded byte counts, not encoded copies, to avoid doubling queue memory.
    private var entries: [(event: QueuedEvent, lineBytes: Int)] = []
    /// Σ `lineBytes` over `entries` — what `byteCount` returns. Never a `stat`, never derived
    /// from the file, at any point, including after `load()`.
    private var liveBytes: Int = 0
    /// Bytes outside live events: dropped/acked event lines, ack records, and the retained
    /// transition receipt. Invariant at quiescent points: `deadBytes == <file length> − liveBytes`.
    private var deadBytes: Int = 0
    private var lastTransitionID: String?
    /// The lazily-opened append handle, positioned at end. Opened on the first enqueue after
    /// `init`, never before (C5).
    private var handle: FileHandle?

    private static let maxEvents = 1_000
    private static let maxBytes = 1 << 20 // 1_048_576
    private static let compactionFloorBytes = 65_536
    private static let newlineByte: UInt8 = 0x0A
    /// `maxBytes` bounds the LIVE mirror; this bounds the file itself, dead bytes included, so a
    /// forged or corrupted `queue.jsonl` many times that size cannot make `load()` allocate an
    /// unbounded buffer before a single line is even parsed.
    private static let maxQueueFileBytes = 4 << 20 // 4_194_304 (4 MiB)

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        // Determinism is required, not cosmetic: compaction re-encodes live events and the byte
        // count must not move when it does.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.tmpFileURL = fileURL.appendingPathExtension("tmp")
    }

    // internal API — the only lock takers.

    /// Returns how many the cap dropped.
    @discardableResult
    func append(_ event: QueuedEvent) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return appendLocked(event)
    }

    /// Commit a transition to the queue before its state intent can be retired. Replaying
    /// the same intent never appends its ID twice. Failures leave the live mirror unchanged.
    func persistTransition(_ event: QueuedEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var next = entries
        if lastTransitionID != event.id, !next.contains(where: { $0.event.id == event.id }) {
            next.append((event, encodeEventLine(event).bytes))
        }
        var bytes = next.reduce(0) { $0 + $1.lineBytes }
        while next.count > Self.maxEvents || (next.count > 1 && bytes > Self.maxBytes) {
            bytes -= next.removeFirst().lineBytes
        }
        return checkpointLocked(next, transitionID: event.id)
    }

    /// Reset drops only old-identity transitions; other queued events keep legacy semantics.
    func discardTransitions() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries.contains(where: { $0.event.name == "app_updated" }) else { return true }
        return checkpointLocked(entries.filter { $0.event.name != "app_updated" })
    }

    private func checkpointLocked(_ next: [(event: QueuedEvent, lineBytes: Int)], transitionID: String? = nil) -> Bool {
        let receiptID = transitionID ?? lastTransitionID
        let receipt = encodeReceipt(receiptID)
        let data = receipt + Data(next.map { encodeEventLine($0.event).line + "\n" }.joined().utf8)
        do {
            StateDirectory.ensureMode0700(fileURL.deletingLastPathComponent())
            try handle?.close()
            handle = nil
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            entries = next
            liveBytes = next.reduce(0) { $0 + $1.lineBytes }
            lastTransitionID = receiptID
            deadBytes = receipt.count
            return true
        } catch {
            return false
        }
    }

    /// Returns up to `n` from the front and removes nothing: a retry resends the same batch with
    /// the same ids (wire §6); the batch leaves only when it is accepted.
    func head(_ n: Int) -> [QueuedEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard n > 0 else { return [] }
        return entries.prefix(n).map { $0.event }
    }

    /// Drop a positional prefix for local queue maintenance. Network acknowledgements
    /// use IDs because caller-side enqueues can evict the head during a request.
    func remove(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard n > 0, !entries.isEmpty else { return }
        dropAndAckLocked(min(n, entries.count))
        considerCompactionLocked()
    }

    /// The sent batch may have been partly evicted while its POST was in flight.
    /// Only its surviving IDs can be acknowledged. FIFO insertion/eviction means
    /// those survivors are still a prefix; a newly enqueued update cannot be removed.
    func remove(ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let take = entries.prefix { ids.contains($0.event.id) }.count
        guard take > 0 else { return }
        dropAndAckLocked(take)
        considerCompactionLocked()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// What the SDK counts against its OWN cap — never a `stat`.
    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveBytes
    }

    /// C4b/C4's "is an `install` still queued".
    func contains(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.event.name == name }
    }

    func exportedEvents() -> [(id: String, name: String, t: Instant)] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { (id: $0.event.id, name: $0.event.name, t: $0.event.t) }
    }

    /// Reads the file if it exists. Creates neither file nor directory (C5).
    func load(pendingTransitionID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked(pendingTransitionID: pendingTransitionID)
    }

    /// §8.7 item 18's queue half: closes and nils the handle, empties the mirror, removes the
    /// file and its compaction temp file. A later `append` reopens lazily, so `disable()` then
    /// `init()` re-arms with no further wiring.
    func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        entries = []
        liveBytes = 0
        deadBytes = 0
        lastTransitionID = nil
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: tmpFileURL)
    }

    // `…Locked` helpers. Assume the lock is held; touch only the stored properties above.

    private func appendLocked(_ event: QueuedEvent) -> Int {
        let (line, bytes) = encodeEventLine(event)
        entries.append((event: event, lineBytes: bytes))
        liveBytes += bytes
        writeLineLocked(line)
        let dropped = trimLocked()
        considerCompactionLocked()
        return dropped
    }

    /// The queue caps at 1 MB or 1,000 events, oldest dropped first. The
    /// `entries.count > 1` guard on the byte half is deliberate and matches the reference host: a
    /// queue that dropped its only event could never hold a single large one.
    @discardableResult
    private func trimLocked() -> Int {
        var dropped = 0
        while entries.count > Self.maxEvents || (entries.count > 1 && liveBytes > Self.maxBytes) {
            dropAndAckLocked(1)
            dropped += 1
        }
        return dropped
    }

    private func dropAndAckLocked(_ n: Int) {
        guard n > 0, !entries.isEmpty else { return }
        let take = min(n, entries.count)
        var removedBytes = 0
        for i in 0..<take {
            removedBytes += entries[i].lineBytes
        }
        entries.removeFirst(take)
        liveBytes -= removedBytes
        deadBytes += removedBytes

        let (line, ackBytes) = encodeAckLine(take)
        deadBytes += ackBytes
        writeLineLocked(line)
    }

    /// Replay acks without writing another ack. Recompute deadBytes after replay and trimming.
    private func dropForReplayLocked(_ n: Int) {
        guard n > 0, !entries.isEmpty else { return }
        let take = min(n, entries.count)
        var removedBytes = 0
        for i in 0..<take {
            removedBytes += entries[i].lineBytes
        }
        entries.removeFirst(take)
        liveBytes -= removedBytes
    }

    /// Reset before replay so load is idempotent. Truncate a torn tail at the last newline
    /// before appending; otherwise a fragment can consume the next event too.
    /// Replay events and acks, trim to the cap, then recalculate dead bytes and compact.
    private func loadLocked(pendingTransitionID: String?) {
        entries = []
        liveBytes = 0
        deadBytes = 0
        lastTransitionID = nil
        try? handle?.close()
        handle = nil

        // Stat before reading: a `queue.jsonl` many times its legitimate ceiling — corrupt,
        // forged, or someone else's data landed in this directory — must not make `load()`
        // allocate an unbounded buffer before a single line is even parsed.
        // The queue is treated exactly like a missing file: empty, not a crash.
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        guard fileSize <= Self.maxQueueFileBytes else { return }

        guard var data = try? Data(contentsOf: fileURL) else { return }

        if !data.isEmpty, data[data.index(before: data.endIndex)] != Self.newlineByte {
            if let lastNewline = data.lastIndex(of: Self.newlineByte) {
                let keep = data.distance(from: data.startIndex, to: lastNewline) + 1
                data = data.prefix(keep)
            } else {
                data = Data()
            }
            if let writeHandle = try? FileHandle(forWritingTo: fileURL) {
                try? writeHandle.truncate(atOffset: UInt64(data.count))
                try? writeHandle.close()
            }
        }

        replayLocked(data, pendingTransitionID: pendingTransitionID)
        trimLocked()

        let fileLength = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? liveBytes
        deadBytes = max(0, fileLength - liveBytes)

        considerCompactionLocked()
    }

    private func replayLocked(_ data: Data, pendingTransitionID: String?) {
        let decoder = JSONDecoder()
        var lineStart = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == Self.newlineByte {
                if i > lineStart {
                    replayLineLocked(data[lineStart..<i], decoder: decoder, pendingTransitionID: pendingTransitionID)
                }
                lineStart = data.index(after: i)
            }
            i = data.index(after: i)
        }
    }

    /// A line that decodes as neither record type, or whose `t` fails `Instant(decimal:)`, is
    /// skipped (§4.2) — a torn event line costs that event, nothing else. So is one that decodes
    /// cleanly but fails the SAME grammar `WireGate`/`Grammar` enforce on the way IN — a `queue.jsonl`
    /// on disk is not trusted input, and a tampered `n`, a `.number` literal that is not RFC 8259
    /// (the exact hole `Wire.swift`'s `appendJSONValue` writes raw), or a `context.platform` outside
    /// wire §5.2's enums must cost only that one line, not be replayed straight back into a future
    /// request body.
    private func replayLineLocked(_ lineData: Data.SubSequence, decoder: JSONDecoder, pendingTransitionID: String?) {
        let bytes = Data(lineData)
        if let ack = try? decoder.decode(QueueAckLine.self, from: bytes) {
            dropForReplayLocked(ack.ack)
            return
        }
        if let receipt = try? decoder.decode(QueueTransitionReceipt.self, from: bytes) {
            lastTransitionID = receipt.transitionID
            return
        }
        guard let line = try? decoder.decode(QueueEventLine.self, from: bytes),
              let instant = Instant(decimal: line.t),
              Grammar.isEventName(line.n),
              EventQueue.propsAreWellFormed(line.p),
              EventQueue.contextIsWellFormed(line.context) else {
            return
        }
        let event = QueuedEvent(id: line.id, name: line.n, t: instant, props: line.p, isHeartbeat: line.hb, context: line.context)
        // Legacy queues have no receipt line. Seeing the pending ID proves handoff even
        // if a later acknowledgement or startup cap trimming removes that event.
        if lastTransitionID == nil, event.id == pendingTransitionID {
            lastTransitionID = event.id
        }
        let lineBytes = bytes.count + 1 // the line as it was read from disk, plus its newline
        entries.append((event: event, lineBytes: lineBytes))
        liveBytes += lineBytes
    }

    /// Every `.number` literal is the exact ASCII bytes `Wire.swift`'s `appendJSONValue` writes
    /// raw into a future request body; one that is not RFC 8259 §6 could splice arbitrary JSON
    /// into that body, mirroring `WireGate.validateTrackProps`'s own check on
    /// the way in. `nil` and an empty map both pass — nothing to check.
    private static func propsAreWellFormed(_ props: [String: WireValue]?) -> Bool {
        guard let props else { return true }
        for value in props.values {
            if case .number(let literal) = value, !Grammar.isJSONNumberLiteral(literal) {
                return false
            }
        }
        return true
    }

    /// A restored `context.platform.os`/`.arch` must still be one of wire §5.2's enums; anything
    /// else means the line was corrupted or tampered with after `Platform.detect` wrote it.
    /// `nil` passes — an event with no frozen context re-resolves the live platform.
    private static func contextIsWellFormed(_ context: EventContext?) -> Bool {
        guard let context else { return true }
        return Grammar.isPlatformOS(context.platform.os) && Grammar.isPlatformArch(context.platform.arch)
    }

    /// The only whole-file write in this file, triggered after a head advance or after `load()`.
    /// A crash mid-compaction leaves the old file, which still replays to the same live set,
    /// because the swap is atomic (`FileManager.replaceItemAt`).
    private func considerCompactionLocked() {
        let shouldCompact = (deadBytes >= Self.compactionFloorBytes && deadBytes >= liveBytes)
            || (entries.isEmpty && deadBytes > 0)
        guard shouldCompact else { return }
        compactLocked()
    }

    private func compactLocked() {
        let receipt = encodeReceipt(lastTransitionID)
        var buffer = receipt
        for entry in entries {
            let (line, _) = encodeEventLine(entry.event)
            buffer.append(contentsOf: Array((line + "\n").utf8))
        }
        guard (try? buffer.write(to: tmpFileURL, options: [.atomic])) != nil else { return }
        // `.atomic` creates a brand-new file at `tmpFileURL` under the process umask, not 0600 —
        // unlike `openHandleLocked`'s `createFile(…attributes:)`, `write(to:options:.atomic)` has
        // no attributes parameter of its own.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpFileURL.path)

        try? handle?.close()
        handle = nil

        guard (try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmpFileURL)) != nil else {
            // The swap failed; the old `fileURL` (if any) is still authoritative and still
            // replays to the same live set (this function's own doc comment). The half-written
            // temp file must not be left behind to confuse the next compaction attempt or a
            // directory listing a conformance check reads.
            try? FileManager.default.removeItem(at: tmpFileURL)
            return
        }
        // `replaceItemAt` is not documented to preserve the NEW item's mode, only metadata it
        // chooses to carry over from the item being replaced; re-assert explicitly rather than
        // trust it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        deadBytes = receipt.count
        openHandleLocked()
    }

    /// Create the directory (0700) and file (0600) lazily on first enqueue after init (C5).
    private func openHandleLocked() {
        guard handle == nil else { return }
        let directory = fileURL.deletingLastPathComponent()
        StateDirectory.ensureMode0700(directory)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// Append with throwing FileHandle APIs: legacy APIs may raise uncatchable Objective-C exceptions.
    /// On storage failure, retain the in-memory queue and retry persistence on the next call.
    /// Durability is lost on failure; load recalculates disk byte accounting.
    private func writeLineLocked(_ line: String) {
        openHandleLocked()
        guard let handle else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func encodeEventLine(_ event: QueuedEvent) -> (line: String, bytes: Int) {
        let line = QueueEventLine(
            hb: event.isHeartbeat,
            id: event.id,
            n: event.name,
            p: event.props,
            t: event.t.description,
            context: event.context
        )
        let data = (try? Self.jsonEncoder.encode(line)) ?? Data()
        return (String(decoding: data, as: UTF8.self), data.count + 1)
    }

    private func encodeAckLine(_ n: Int) -> (line: String, bytes: Int) {
        let data = (try? Self.jsonEncoder.encode(QueueAckLine(ack: n))) ?? Data()
        return (String(decoding: data, as: UTF8.self), data.count + 1)
    }

    private func encodeReceipt(_ id: String?) -> Data {
        guard let id, var data = try? Self.jsonEncoder.encode(QueueTransitionReceipt(transitionID: id)) else {
            return Data()
        }
        data.append(Self.newlineByte)
        return data
    }
}
