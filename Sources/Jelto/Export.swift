// Encodes the semantic state export of spec/sdk-conformance.md §3.2.
// It reads only held state: no loading, persistence, defaults, or inferred missing values.

import Foundation

struct ExportedEvent: Encodable {
    let id: String
    let n: String
    let t: String // decimal string — never a JSON number (C15b)
}

struct QueueExport: Encodable {
    let bytes: Int
    let events: [ExportedEvent]
}

/// Checked against `runner/checks.go`: `checkStateJSON` compares against the raw JSON text,
/// `checkStateDeadline` parses a decimal (accepting a JSON string), `isEmptyExported` treats `""`,
/// `null`, `0`, `false`, `{}`, `[]` as empty, and `checkQueueFile` decodes
/// `{bytes:int, events:[{id,n,t}]}` with `t` a string.
///
/// Three traps, each with a row behind it: `backoff_step_ms` is a NUMBER (C8c asserts against
/// raw JSON text — a quoted `"2000"` fails); `install_claimed` is a BOOL (C4, C4b); every instant
/// is a STRING (C4c, C8c read them through `math/big` on both sides — a JSON number would already
/// have been rounded into a float64).
///
/// `state.consecutiveRefusals` is never read here: it is C8c arm D's own bookkeeping and §3.2
/// rules it out of the export in as many words.
struct StateExport: Encodable {
    private let state: PersistedState
    private let queueBytes: Int
    private let queueEvents: [(id: String, name: String, t: Instant)]

    init(state: PersistedState, queueBytes: Int, queueEvents: [(id: String, name: String, t: Instant)]) {
        self.state = state
        self.queueBytes = queueBytes
        self.queueEvents = queueEvents
    }

    private enum CodingKeys: String, CodingKey {
        case lastAppVersion = "last_app_version"
        case installID = "install_id"
        case lastHeartbeatDay = "last_heartbeat_day"
        case installClaimed = "install_claimed"
        case installDueAt = "install_due_at"
        case installFirstTry = "install_first_try"
        case installProps = "install_props"
        case backoffStepMS = "backoff_step_ms"
        case backoffNextAt = "backoff_next_at"
        case stopUntil = "stop_until"
        case stopProbeDue = "stop_probe_due"
        case queue
    }

    // Hand-written, not synthesised, so "emitted when" is visible in the code and cannot drift.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encodeIfPresent(state.lastAppVersion, forKey: .lastAppVersion)
        try c.encode(state.installID, forKey: .installID) // always; "" when unset
        if let day = state.lastHeartbeatDay {
            try c.encode(day, forKey: .lastHeartbeatDay) // already a decimal string
        }
        try c.encode(state.installClaimed, forKey: .installClaimed) // always, a bool
        if let dueAt = state.installDueAt {
            try c.encode(dueAt.description, forKey: .installDueAt)
        }
        if let firstTry = state.installFirstTry {
            try c.encode(firstTry.description, forKey: .installFirstTry)
        }
        if !state.installProps.isEmpty {
            try c.encode(state.installProps, forKey: .installProps)
        }
        if state.backoffStepMS > 0 {
            try c.encode(state.backoffStepMS, forKey: .backoffStepMS) // an integer, not a string
        }
        if let nextAt = state.backoffNextAt {
            try c.encode(nextAt.description, forKey: .backoffNextAt)
        }
        if let stopUntil = state.stopUntil {
            try c.encode(stopUntil.description, forKey: .stopUntil)
        }
        try c.encode(state.stopProbeDue, forKey: .stopProbeDue) // always, a bool

        let events = queueEvents.map { ExportedEvent(id: $0.id, n: $0.name, t: $0.t.description) }
        try c.encode(QueueExport(bytes: queueBytes, events: events), forKey: .queue) // always
    }

    /// The `state` object's bytes; the host splices them into its reply line. On the encode
    /// failure that cannot happen for a struct of `String`/`Int`/`Bool` (§8.3 item 10), returns
    /// `{}` rather than throwing into the host.
    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
