// Persists state as a binary plist. StoredState encodes instants as decimal strings
// so plist integer and floating-point limits cannot round C15b values.

import Foundation

/// Shared by `Store` and `EventQueue` (spec/sdk-conformance.md §5): `FileManager`'s
/// `createDirectory(at:withIntermediateDirectories:attributes:)` only ever applies `attributes`
/// to a directory it actually creates — a directory that already exists (world-writable because
/// an older SDK build made it, or because anything else did) keeps whatever mode it already had.
/// The spec requires the mode RE-ASSERTED, not just set at creation, so this always follows up
/// with an explicit, unconditional `setAttributes` regardless of which branch `createDirectory`
/// took. Every failure is swallowed — the SDK never throws into the host app: an unwritable
/// directory costs state, not a crash.
enum StateDirectory {
    static func ensureMode0700(_ directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

/// A write-ahead intent is committed atomically with the new baseline. Its timestamp is
/// a decimal string for arbitrary-precision conformance clocks and plist compatibility.
struct AppUpdateIntent: Sendable, Codable {
    let id: String
    let timestamp: String
    let fromVersion: String
    let toVersion: String
    let context: EventContext

    var event: QueuedEvent? {
        guard let instant = Instant(decimal: timestamp) else { return nil }
        return QueuedEvent(id: id, name: "app_updated", t: instant,
            props: ["from_version": .string(fromVersion), "to_version": .string(toVersion)],
            isHeartbeat: false, context: context)
    }
}

struct PersistedState: Sendable {
    var lastAppVersion: String? = nil
    var pendingUpdate: AppUpdateIntent? = nil
    var installID: String = ""
    var installOrigin: String? = nil
    var lastHeartbeatDay: String? = nil
    var installClaimed: Bool = false
    var installDueAt: Instant? = nil
    var installFirstTry: Instant? = nil
    var installProps: [String: String] = [:]
    var backoffStepMS: Int = 0
    var backoffNextAt: Instant? = nil
    var stopUntil: Instant? = nil
    var stopProbeDue: Bool = false
    // Ours: recomputable from `backoff_step_ms`, no rule asks an SDK to keep it. Persisted and
    // NOT exported — Export.swift must not read this field (§3.2).
    var consecutiveRefusals: Int = 0

    init() {}
}

/// The plist DTO. Every `Instant`-valued field becomes a decimal `String`; everything else is
/// the same shape as `PersistedState`. Key names here are ours, not a contract, and are
/// deliberately not named after §3.2's export keys so nobody later "fixes" the export by
/// renaming a plist key.
private struct StoredState: Codable {
    var lastAppVersion: String?
    var pendingUpdate: AppUpdateIntent?
    var installID: String
    var installOrigin: String?
    var lastHeartbeatDay: String?
    var installClaimed: Bool
    var installDueAt: String?
    var installFirstTry: String?
    var installProps: [String: String]
    var backoffStepMS: Int
    var backoffNextAt: String?
    var stopUntil: String?
    var stopProbeDue: Bool
    var consecutiveRefusals: Int

    init(_ state: PersistedState) {
        lastAppVersion = state.lastAppVersion
        pendingUpdate = state.pendingUpdate
        installID = state.installID
        installOrigin = state.installOrigin
        lastHeartbeatDay = state.lastHeartbeatDay
        installClaimed = state.installClaimed
        installDueAt = state.installDueAt?.description
        installFirstTry = state.installFirstTry?.description
        installProps = state.installProps
        backoffStepMS = state.backoffStepMS
        backoffNextAt = state.backoffNextAt?.description
        stopUntil = state.stopUntil?.description
        stopProbeDue = state.stopProbeDue
        consecutiveRefusals = state.consecutiveRefusals
    }

    /// `Instant(decimal:)` returning `nil` on load leaves that one field `nil` — "not set" is the
    /// safe direction for every instant-valued field, and it costs a deadline rather than the file.
    var asPersistedState: PersistedState {
        var s = PersistedState()
        s.lastAppVersion = lastAppVersion
        s.pendingUpdate = pendingUpdate
        s.installID = installID
        s.installOrigin = installOrigin.map { Jelto.InstallOrigin(rawValue: $0)?.rawValue ?? "unknown" }
        s.lastHeartbeatDay = lastHeartbeatDay
        s.installClaimed = installClaimed
        s.installDueAt = installDueAt.flatMap { Instant(decimal: $0) }
        s.installFirstTry = installFirstTry.flatMap { Instant(decimal: $0) }
        s.installProps = installProps
        s.backoffStepMS = backoffStepMS
        s.backoffNextAt = backoffNextAt.flatMap { Instant(decimal: $0) }
        s.stopUntil = stopUntil.flatMap { Instant(decimal: $0) }
        s.stopProbeDue = stopProbeDue
        s.consecutiveRefusals = consecutiveRefusals
        return s
    }

    private enum CodingKeys: String, CodingKey {
        case lastAppVersion, pendingUpdate
        case installID, installOrigin, lastHeartbeatDay, installClaimed, installDueAt, installFirstTry
        case installProps, backoffStepMS, backoffNextAt, stopUntil, stopProbeDue
        case consecutiveRefusals
    }

    // Hand-written, not synthesised: Swift's synthesised decoder throws when a non-optional key
    // is missing, which would turn a plist written by an older or interrupted build into a total
    // loss instead of a partial one. Every key falls back to the empty-state default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let empty = PersistedState()
        lastAppVersion = try c.decodeIfPresent(String.self, forKey: .lastAppVersion)
        pendingUpdate = try c.decodeIfPresent(AppUpdateIntent.self, forKey: .pendingUpdate)
        installID = try c.decodeIfPresent(String.self, forKey: .installID) ?? empty.installID
        installOrigin = try c.decodeIfPresent(String.self, forKey: .installOrigin)
        lastHeartbeatDay = try c.decodeIfPresent(String.self, forKey: .lastHeartbeatDay)
        installClaimed = try c.decodeIfPresent(Bool.self, forKey: .installClaimed) ?? empty.installClaimed
        installDueAt = try c.decodeIfPresent(String.self, forKey: .installDueAt)
        installFirstTry = try c.decodeIfPresent(String.self, forKey: .installFirstTry)
        installProps = try c.decodeIfPresent([String: String].self, forKey: .installProps) ?? empty.installProps
        backoffStepMS = try c.decodeIfPresent(Int.self, forKey: .backoffStepMS) ?? empty.backoffStepMS
        backoffNextAt = try c.decodeIfPresent(String.self, forKey: .backoffNextAt)
        stopUntil = try c.decodeIfPresent(String.self, forKey: .stopUntil)
        stopProbeDue = try c.decodeIfPresent(Bool.self, forKey: .stopProbeDue) ?? empty.stopProbeDue
        consecutiveRefusals = try c.decodeIfPresent(Int.self, forKey: .consecutiveRefusals) ?? empty.consecutiveRefusals
    }

    // Synthesised is fine for encoding: every field is present, so there is nothing for
    // synthesis to get wrong the way the decoder can.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastAppVersion, forKey: .lastAppVersion)
        try c.encodeIfPresent(pendingUpdate, forKey: .pendingUpdate)
        try c.encode(installID, forKey: .installID)
        try c.encodeIfPresent(installOrigin, forKey: .installOrigin)
        try c.encodeIfPresent(lastHeartbeatDay, forKey: .lastHeartbeatDay)
        try c.encode(installClaimed, forKey: .installClaimed)
        try c.encodeIfPresent(installDueAt, forKey: .installDueAt)
        try c.encodeIfPresent(installFirstTry, forKey: .installFirstTry)
        try c.encode(installProps, forKey: .installProps)
        try c.encode(backoffStepMS, forKey: .backoffStepMS)
        try c.encodeIfPresent(backoffNextAt, forKey: .backoffNextAt)
        try c.encodeIfPresent(stopUntil, forKey: .stopUntil)
        try c.encode(stopProbeDue, forKey: .stopProbeDue)
        try c.encode(consecutiveRefusals, forKey: .consecutiveRefusals)
    }
}

/// All state behind one `NSLock`. The SDK never throws into the host —
/// every failure here (missing file, corrupt plist, a full disk) is swallowed; a corrupt state
/// costs an install id, not a crash. No `throws`, no `try!`, no force unwrap in this file.
final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let stateFileURL: URL
    private var state = PersistedState()

    /// `state.plist` is a handful of scalar fields; nothing legitimate approaches this. A file
    /// above it is corrupt or hostile (someone else's data landed in this directory, or an
    /// attacker is trying to make `load()` allocate an unbounded buffer), and is treated exactly
    /// like a missing or undecodable one — an empty `PersistedState()`, never a crash or an
    /// unbounded read.
    private static let maxStateFileBytes = 256 * 1_024 // 256 KiB

    /// Records the directory and the derived `state.plist` URL. Touches the filesystem not at
    /// all (C5).
    init(directory: URL) {
        self.directory = directory
        self.stateFileURL = directory.appendingPathComponent("state.plist")
    }

    /// Reads `state.plist` if it is there. If the file is absent, unreadable, or does not decode,
    /// the in-memory state becomes the empty `PersistedState()` and that is returned. Creates
    /// neither the file nor the directory (C5).
    func load() -> PersistedState {
        lock.lock()
        defer { lock.unlock() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: stateFileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= Store.maxStateFileBytes,
              let data = try? Data(contentsOf: stateFileURL),
              let stored = try? PropertyListDecoder().decode(StoredState.self, from: data) else {
            state = PersistedState()
            return state
        }
        state = stored.asPersistedState
        return state
    }

    /// The in-memory copy, no I/O. This is what `dumpstate` reads.
    func get() -> PersistedState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Mutates and persists under one lock, so a crash between the two is the only way they can
    /// disagree. Every I/O failure is swallowed. Returns the state after mutation.
    @discardableResult
    func update(_ mutate: (inout PersistedState) -> Void) -> PersistedState {
        lock.lock()
        defer { lock.unlock() }

        mutate(&state)

        StateDirectory.ensureMode0700(directory)

        let stored = StoredState(state)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(stored) {
            try? data.write(to: stateFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFileURL.path
            )
        }

        return state
    }

    /// State/intent transaction. Never publish a new baseline in memory on a failed write.
    @discardableResult
    func commit(_ mutate: (inout PersistedState) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var next = state
        mutate(&next)
        do {
            StateDirectory.ensureMode0700(directory)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(StoredState(next)).write(to: stateFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFileURL.path)
            state = next
            return true
        } catch {
            return false
        }
    }

    /// C18's `state_dir_empty` check is a real `os.ReadDir` of the
    /// directory, so resetting the in-memory fields and removing the two known file names is not
    /// enough: every remaining entry in the directory is removed too (the queue file, a stray
    /// compaction temp file, anything else the SDK put there). The directory itself is left in
    /// place — an existing-but-empty directory and a never-created one both pass
    /// `checkStateDirEmpty`. Only entries of the SDK's own state directory are ever removed, and
    /// this never recurses above it.
    ///
    /// Ordering contract with the queue: `EventQueue` holds an open append file
    /// handle. The engine MUST call `queue.delete()` (which closes that handle) BEFORE
    /// `store.wipe()` — `wipe()` does not and cannot close it.
    func wipe() {
        lock.lock()
        defer { lock.unlock() }

        state = PersistedState()
        try? FileManager.default.removeItem(at: stateFileURL)

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
