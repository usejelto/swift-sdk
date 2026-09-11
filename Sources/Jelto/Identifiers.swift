// Generates wire event and install UUIDs with SystemRandomNumberGenerator.

enum Identifiers {
    /// W1 rejects `00000000-0000-0000-0000-000000000000` in `id`, and the schema rejects it in
    /// `iid` (wire rev 0.14). Structurally the version nibble makes it unreachable from either
    /// generator below; named here so the guard in each generator can be read against it, and so
    /// the code can be seen never to send it.
    static let nilUUID = "00000000-0000-0000-0000-000000000000"

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    /// C2 asserts a v4 specifically:
    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`.
    static func uuidV4() -> String {
        var bytes = randomBytes16()
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let result = render(bytes)
        // Unreachable: the version nibble above makes the nil UUID structurally impossible from
        // this path. A rule with no enforcement is a comment, so the guard stays anyway.
        if result == nilUUID { return uuidV4() }
        return result
    }

    /// Bytes 0...5 are `at.low48` big-endian (masked with `0xFFFF_FFFF_FFFF` defensively); byte 6
    /// carries version 7, byte 8 the same RFC 4122 variant as `uuidV4()`. The 48-bit timestamp
    /// comes from `Instant.low48` so C15b's pre-epoch and past-`Int64` clocks still yield a
    /// well-formed non-nil v7 — an `id` is a dedup key, not a second timestamp, and the SDK must
    /// not move the clock to make one pretty.
    static func uuidV7(at instant: Instant) -> String {
        var bytes = randomBytes16()
        let ts = instant.low48 & 0xFFFF_FFFF_FFFF
        bytes[0] = UInt8((ts >> 40) & 0xFF)
        bytes[1] = UInt8((ts >> 32) & 0xFF)
        bytes[2] = UInt8((ts >> 24) & 0xFF)
        bytes[3] = UInt8((ts >> 16) & 0xFF)
        bytes[4] = UInt8((ts >> 8) & 0xFF)
        bytes[5] = UInt8(ts & 0xFF)
        bytes[6] = (bytes[6] & 0x0F) | 0x70 // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let result = render(bytes)
        if result == nilUUID { return uuidV7(at: instant) }
        return result
    }

    private static func randomBytes16() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return bytes
    }

    /// A 36-byte formatter over the lower-case hex alphabet with dashes at 8, 13, 18, 23. Never
    /// `Foundation.UUID().uuidString`, which is UPPERCASE and C2's regexes are `[0-9a-f]`.
    private static func render(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(36)
        for (i, b) in bytes.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 {
                out.append(UInt8(ascii: "-"))
            }
            out.append(hexAlphabet[Int(b >> 4)])
            out.append(hexAlphabet[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
