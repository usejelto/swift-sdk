// Arbitrary-precision signed milliseconds (C15b, RFC-0001 §8.5), represented as
// sign-and-magnitude with base-10^9 little-endian UInt32 limbs. Constructors enforce:
// - every limb is below 1,000,000,000;
// - zero has an empty magnitude, otherwise the highest limb is nonzero;
// - zero is never negative.
// No instant is converted through floating point.
@_spi(Conformance) public struct Instant: Equatable, Comparable, CustomStringConvertible, Sendable {
    // Keep representation private so callers cannot create negative zero and break synthesized equality.
    private var negative: Bool
    private var limbs: [UInt32] // limbs[0] is the least significant; each limb < 1_000_000_000

    private static let base: UInt64 = 1_000_000_000

    private init(negative: Bool, limbs: [UInt32]) {
        self.negative = negative
        self.limbs = limbs
        self.normalize()
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
        if limbs.isEmpty {
            negative = false
        }
    }

    /// Sign from the value, magnitude from `milliseconds.magnitude` — never `-milliseconds`,
    /// which traps on `Int64.min`.
    init(_ milliseconds: Int64) {
        let neg = milliseconds < 0
        var mag = milliseconds.magnitude
        var limbs: [UInt32] = []
        while mag > 0 {
            limbs.append(UInt32(mag % Instant.base))
            mag /= Instant.base
        }
        self.negative = limbs.isEmpty ? false : neg
        self.limbs = limbs
    }

    /// Grammar: an optional single leading `+` or `-`, then one or more ASCII digits, and
    /// nothing else. Does not trim whitespace. Leading zeros are accepted and normalised away.
    /// Chunks the digit string from the right in groups of nine into limbs.
    @_spi(Conformance) public init?(decimal: String) {
        let bytes = Array(decimal.utf8)
        guard !bytes.isEmpty else { return nil }

        var idx = 0
        var neg = false
        let plus = UInt8(ascii: "+")
        let minus = UInt8(ascii: "-")
        if bytes[0] == plus || bytes[0] == minus {
            neg = bytes[0] == minus
            idx = 1
        }
        guard idx < bytes.count else { return nil }

        let zero = UInt8(ascii: "0")
        let nine = UInt8(ascii: "9")
        for i in idx..<bytes.count {
            guard bytes[i] >= zero && bytes[i] <= nine else { return nil }
        }

        var limbs: [UInt32] = []
        var end = bytes.count
        while end > idx {
            let begin = Swift.max(idx, end - 9)
            var value: UInt32 = 0
            for i in begin..<end {
                value = value * 10 + UInt32(bytes[i] - zero)
            }
            limbs.append(value)
            end = begin
        }

        self.negative = neg
        self.limbs = limbs
        self.normalize()
    }

    /// The canonical decimal literal: `"0"` for zero, a leading `"-"` only when negative, the
    /// most significant limb printed with no padding and every lower limb padded to exactly nine
    /// digits. Round-trips `init?(decimal:)` exactly.
    public var description: String {
        guard !limbs.isEmpty else { return "0" }
        var result = negative ? "-" : ""
        result += String(limbs[limbs.count - 1])
        if limbs.count > 1 {
            for i in stride(from: limbs.count - 2, through: 0, by: -1) {
                result += Instant.padded9(limbs[i])
            }
        }
        return result
    }

    private static func padded9(_ value: UInt32) -> String {
        let s = String(value)
        if s.count >= 9 { return s }
        return String(repeating: "0", count: 9 - s.count) + s
    }

    /// Use magnitude to avoid negating Int64.min; opposite signs subtract magnitudes.
    func adding(_ milliseconds: Int64) -> Instant {
        let addendNegative = milliseconds < 0
        var mag = milliseconds.magnitude
        var addendLimbs: [UInt32] = []
        while mag > 0 {
            addendLimbs.append(UInt32(mag % Instant.base))
            mag /= Instant.base
        }

        if negative == addendNegative {
            let sum = Instant.addMagnitudes(limbs, addendLimbs)
            return Instant(negative: negative, limbs: sum)
        }

        let cmp = Instant.compareMagnitudes(limbs, addendLimbs)
        if cmp == 0 {
            return Instant(negative: false, limbs: [])
        } else if cmp > 0 {
            let diff = Instant.subtractMagnitudes(limbs, addendLimbs)
            return Instant(negative: negative, limbs: diff)
        } else {
            let diff = Instant.subtractMagnitudes(addendLimbs, limbs)
            return Instant(negative: addendNegative, limbs: diff)
        }
    }

    private static func addMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        let count = Swift.max(a.count, b.count)
        result.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let av: UInt64 = i < a.count ? UInt64(a[i]) : 0
            let bv: UInt64 = i < b.count ? UInt64(b[i]) : 0
            let sum = av + bv + carry
            result.append(UInt32(sum % Instant.base))
            carry = sum / Instant.base
        }
        if carry > 0 {
            result.append(UInt32(carry))
        }
        return result
    }

    /// Assumes `a`'s magnitude is >= `b`'s.
    private static func subtractMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(a.count)
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let av = Int64(a[i])
            let bv: Int64 = i < b.count ? Int64(b[i]) : 0
            var diff = av - bv - borrow
            if diff < 0 {
                diff += Int64(Instant.base)
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt32(diff))
        }
        return result
    }

    private static func compareMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count {
            return a.count < b.count ? -1 : 1
        }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            if a[i] != b[i] {
                return a[i] < b[i] ? -1 : 1
            }
        }
        return 0
    }

    /// floor(value / 86_400_000). Each division step is at most
    /// (86_400_000 - 1) * 10^9 + (10^9 - 1), which fits UInt64.
    var utcDayIndex: Instant {
        let divisor: UInt64 = 86_400_000
        let (q, r) = Instant.divideMagnitude(limbs, by: divisor)
        if negative && r != 0 {
            let qPlus1 = Instant.addMagnitudes(q, [1])
            return Instant(negative: true, limbs: qPlus1)
        }
        return Instant(negative: negative, limbs: q)
    }

    /// Base-10^9 long division. divisor must be <= 18_446_744_072 to keep
    /// remainder * base inside UInt64; the only caller passes 86_400_000.
    private static func divideMagnitude(_ limbs: [UInt32], by divisor: UInt64) -> (quotient: [UInt32], remainder: UInt64) {
        guard !limbs.isEmpty else { return ([], 0) }
        var quotient = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let dividend = remainder * Instant.base + UInt64(limbs[i])
            quotient[i] = UInt32(dividend / divisor)
            remainder = dividend % divisor
        }
        while let last = quotient.last, last == 0 {
            quotient.removeLast()
        }
        return (quotient, remainder)
    }

    /// The value reduced modulo 2^48 into `[0, 2^48)` — a Euclidean modulus, so a negative
    /// instant yields a non-negative residue. Horner from the most significant limb using
    /// wrapping `&*`/`&+` (exact because 2^48 divides 2^64), then masked to 48 bits.
    var low48: UInt64 {
        var r: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            r = r &* Instant.base &+ UInt64(limbs[i])
        }
        r &= 0xFFFF_FFFF_FFFF
        if negative && r != 0 {
            return 0x1_0000_0000_0000 - r
        }
        return r
    }

    /// Compares exact instants chronologically.
    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        if lhs.negative != rhs.negative {
            return lhs.negative
        }
        let cmp = Instant.compareMagnitudes(lhs.limbs, rhs.limbs)
        if lhs.negative {
            return cmp > 0
        }
        return cmp < 0
    }
}
