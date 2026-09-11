// Decodes actionable response fields. Invalid, empty, or truncated JSON yields nil;
// {} yields an empty response and must not be logged as malformed.

import Foundation

struct ServerResponse: Sendable {
    struct Rejection: Sendable {
        var index: Int
        var reason: String
        var field: String?
    }

    struct Stop: Sendable {
        var until: Instant
        var scope: String
    }

    var rejected: [Rejection]
    var stop: Stop?
    var error: String?

    /// `until` is whole seconds and must not be routed through a `Double`. Decoded as `Int64`
    /// through `JSONDecoder`, which reads the digits of an integer literal exactly and throws on
    /// a fraction, then built into an `Instant` with an overflow-checked `Int64` multiply by
    /// 1 000. On a fractional `until`, a non-integer, or an overflow, the stop alone is dropped
    /// (`stop == nil`) and the rest of the body still parses — `RawResponse.init(from:)` below is
    /// what isolates that one field's failure from the rest of the document. Unknown keys and
    /// unknown `rejected` entries are ignored: wire §10's versioning policy only ever appends
    /// fields, and an SDK that failed on an unknown one would break on the next revision.
    static func parse(_ body: Data) -> ServerResponse? {
        guard !body.isEmpty else { return nil }
        guard let raw = try? JSONDecoder().decode(RawResponse.self, from: body) else { return nil }

        let rejected = raw.rejected.map {
            Rejection(index: $0.i, reason: $0.reason, field: $0.field)
        }

        var stop: Stop?
        if let rawStop = raw.stop {
            let (ms, overflow) = rawStop.until.multipliedReportingOverflow(by: 1_000)
            if !overflow {
                stop = Stop(until: Instant(ms), scope: rawStop.scope)
            }
        }

        return ServerResponse(rejected: rejected, stop: stop, error: raw.error)
    }
}

/// The wire shape, decoded field by field so that a malformed `stop` (in particular a fractional
/// `until`, which `Int64` decoding throws on) cannot take the rest of the document down with it.
/// `JSONDecoder`'s default keyed decoding already ignores unknown keys within `RawStop`; the
/// custom `init(from:)` here exists ONLY to isolate `stop`'s own decode from `rejected` and
/// `error`, not to relax anything else.
private struct RawResponse: Decodable {
    struct RawRejection: Decodable {
        let i: Int
        let reason: String
        let field: String?
    }

    struct RawStop: Decodable {
        let until: Int64
        let scope: String
    }

    private enum CodingKeys: String, CodingKey { case rejected, stop, error }

    let rejected: [RawRejection]
    let stop: RawStop?
    let error: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rejected = try container.decodeIfPresent([RawRejection].self, forKey: .rejected) ?? []
        // A `stop` present but unparseable (fractional/non-integer `until`, or absent `until`)
        // is swallowed here rather than propagated — the rest of the body still parses.
        stop = try? container.decodeIfPresent(RawStop.self, forKey: .stop)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
