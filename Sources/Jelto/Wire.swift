// Validates and encodes spec/wire-v1.md events. WireValue numbers remain literal
// strings throughout validation, queue storage, and encoding.

import Foundation

/// The numeric limits of spec/wire-v1.md §2/§3/§4, and the SDK's own `v`.
enum Wire {
    static let maxBodyBytes = 65_536 // §2, and W1's "body <= 64 KB"
    static let maxEvents = 100 // §2
    static let maxProps = 20 // §3, and §4's heartbeat cap since wire rev 0.16
    static let maxPropString = 200 // §3
    static let maxReasonChars = 64 // §4

    /// The SDK's own `v`. Must itself satisfy `Grammar.isClientVersion` — asserted by a unit test.
    static let sdkClientVersion = "swift/0.2.1"

    /// Ascending UTF-8 byte order, used for prop-key iteration so two encodings of the same map
    /// are byte-identical (C20's congruence check) and so a rejection log picks a deterministic
    /// first key.
    static func byUTF8Bytes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}


/// The patterns of spec/wire-v1.md, compiled from the document as hand-written scans over
/// `String.unicodeScalars` — never `NSRegularExpression` and never
/// `range(of:options:.regularExpression)`. ICU's `$` matches before a single trailing line
/// terminator, so `"good_name\n"` would satisfy `^[a-z0-9_:.-]{1,64}$` under ICU and then produce
/// an `n` the wire schema rejects. A scan has no such hole.
///
/// Length is counted in unicode scalars (`s.unicodeScalars.count`), never `s.count`: the runner
/// validates with a JSON-schema library whose `maxLength` counts code points, and every one of
/// these grammars is ASCII-only, so a scalar `> 0x7F` is rejected outright by every predicate
/// below. Empty string fails every predicate; `""` meaning *absent* is a `WireGate` rule, never a
/// `Grammar` rule.
enum Grammar {
    /// `^[a-z0-9_:.-]{1,64}$`
    static func isEventName(_ s: String) -> Bool {
        matches(s, min: 1, max: 64) {
            isLowerAlpha($0) || isDigit($0) || $0 == 0x5F || $0 == 0x3A || $0 == 0x2E || $0 == 0x2D
        }
    }

    /// `^[a-z0-9_]{1,32}$`
    static func isPropKey(_ s: String) -> Bool {
        matches(s, min: 1, max: 32) { isLowerAlpha($0) || isDigit($0) || $0 == 0x5F }
    }

    /// `^[a-z0-9_.-]{1,24}$`
    static func isInstallPropValue(_ s: String) -> Bool {
        matches(s, min: 1, max: 24) {
            isLowerAlpha($0) || isDigit($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D
        }
    }

    /// `^[a-z0-9_-]{1,32}$`
    static func isOnboardingStep(_ s: String) -> Bool {
        matches(s, min: 1, max: 32) { isLowerAlpha($0) || isDigit($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// `^[a-z0-9_.-]+$` — no upper bound in the grammar itself; the 64-scalar cap on `reason` is
    /// `WireGate.onboarding`'s to enforce (§4.4), not this predicate's.
    static func isOnboardingReason(_ s: String) -> Bool {
        matchesUnbounded(s, min: 1) {
            isLowerAlpha($0) || isDigit($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D
        }
    }

    /// `^[a-z]+/[0-9A-Za-z.+-]{1,24}$`, **and** the whole value must be <= 32 unicode scalars
    /// total (round-2 note 1): `[a-z]+` alone is unbounded, so the pattern alone does not cap it.
    static func isClientVersion(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count <= 32 else { return false }

        var i = 0
        var prefixCount = 0
        while i < scalars.count, isLowerAlpha(scalars[i].value) {
            prefixCount += 1
            i += 1
        }
        guard prefixCount >= 1, i < scalars.count, scalars[i].value == 0x2F /* / */ else {
            return false
        }
        i += 1

        let tailStart = i
        while i < scalars.count {
            let v = scalars[i].value
            guard isDigit(v) || isUpperAlpha(v) || isLowerAlpha(v) || v == 0x2E || v == 0x2B || v == 0x2D else {
                return false
            }
            i += 1
        }
        let tailCount = i - tailStart
        return tailCount >= 1 && tailCount <= 24 && i == scalars.count
    }

    /// `^[a-z0-9-]{1,32}$`
    static func isAppSlug(_ s: String) -> Bool {
        matches(s, min: 1, max: 32) { isLowerAlpha($0) || isDigit($0) || $0 == 0x2D }
    }

    /// `^prd_[a-z0-9]{10}$` (spec/wire-v1.md §2's `p`). A hand-written scan, not a `matches`
    /// closure, because the fixed `prd_` prefix is not expressible as a per-scalar predicate.
    static func isProductKey(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count == 14,
              scalars[0].value == 0x70, scalars[1].value == 0x72,
              scalars[2].value == 0x64, scalars[3].value == 0x5F else { return false }
        for i in 4..<14 {
            let v = scalars[i].value
            guard isLowerAlpha(v) || isDigit(v) else { return false }
        }
        return true
    }

    /// wire §5.2's `os` enum: macos|windows|linux.
    static func isPlatformOS(_ s: String) -> Bool {
        s == "macos" || s == "windows" || s == "linux"
    }

    /// wire §5.2's `arch` enum: arm64|x64|x86.
    static func isPlatformArch(_ s: String) -> Bool {
        s == "arm64" || s == "x64" || s == "x86"
    }

    /// RFC 8259 §6: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. `WireValue.number` carries a
    /// *literal string* that the encoder writes raw; without this predicate a caller could inject
    /// arbitrary bytes into the body.
    static func isJSONNumberLiteral(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        guard n > 0 else { return false }

        var i = 0
        if scalars[i].value == 0x2D /* - */ {
            i += 1
        }
        guard i < n else { return false }

        if scalars[i].value == 0x30 /* 0 */ {
            i += 1
        } else if isDigit19(scalars[i].value) {
            i += 1
            while i < n, isDigit(scalars[i].value) { i += 1 }
        } else {
            return false
        }

        if i < n, scalars[i].value == 0x2E /* . */ {
            i += 1
            guard i < n, isDigit(scalars[i].value) else { return false }
            while i < n, isDigit(scalars[i].value) { i += 1 }
        }

        if i < n, scalars[i].value == 0x65 /* e */ || scalars[i].value == 0x45 /* E */ {
            i += 1
            if i < n, scalars[i].value == 0x2B /* + */ || scalars[i].value == 0x2D /* - */ {
                i += 1
            }
            guard i < n, isDigit(scalars[i].value) else { return false }
            while i < n, isDigit(scalars[i].value) { i += 1 }
        }

        return i == n
    }

    private static func isLowerAlpha(_ v: UInt32) -> Bool { v >= 0x61 && v <= 0x7A }
    private static func isUpperAlpha(_ v: UInt32) -> Bool { v >= 0x41 && v <= 0x5A }
    private static func isDigit(_ v: UInt32) -> Bool { v >= 0x30 && v <= 0x39 }
    private static func isDigit19(_ v: UInt32) -> Bool { v >= 0x31 && v <= 0x39 }

    private static func matches(_ s: String, min: Int, max: Int, allowed: (UInt32) -> Bool) -> Bool {
        var count = 0
        for scalar in s.unicodeScalars {
            count += 1
            if count > max { return false }
            if !allowed(scalar.value) { return false }
        }
        return count >= min
    }

    private static func matchesUnbounded(_ s: String, min: Int, allowed: (UInt32) -> Bool) -> Bool {
        var count = 0
        for scalar in s.unicodeScalars {
            count += 1
            if !allowed(scalar.value) { return false }
        }
        return count >= min
    }
}


struct Platform: Sendable, Codable {
    var appVersion: String
    var os: String
    var osVersion: String
    var arch: String
    var slug: String?

    /// `nil` means: this build has no legal `os`/`arch` under spec/wire-v1.md §5.2, and nothing
    /// may be invented. `slug` is taken already gated (`WireGate.appSlug` ran first) and is not
    /// re-validated here.
    static func detect(appVersion: String?, slug: String?, log: DebugLog) -> Platform? {
        let os: String
        #if os(macOS)
        os = "macos"
        #elseif os(Windows)
        os = "windows"
        #elseif os(Linux)
        os = "linux"
        #else
        log.log("spec/wire-v1.md §5.2 `os` is macos|windows|linux; this build is none of them, so nothing can be sent")
        return nil
        #endif

        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x64"
        #elseif arch(i386)
        arch = "x86"
        #else
        log.log("spec/wire-v1.md §5.2 `arch` is arm64|x64|x86; this build is none of them, so nothing can be sent")
        return nil
        #endif

        return Platform(
            appVersion: Platform.resolveAppVersion(appVersion),
            os: os,
            osVersion: Platform.detectOSVersion(),
            arch: arch,
            slug: slug
        )
    }

    /// `ProcessInfo.processInfo.operatingSystemVersion`, never `operatingSystemVersionString`
    /// (which returns `"Version 15.1 (Build 24B83)"`), truncated to the first 32 scalars.
    private static func detectOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let s = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return Platform.truncated(s, to: 32)
    }

    /// The observation is separate from ordinary wire fallback metadata. Unknown versions
    /// must not manufacture a baseline, and valid opaque strings are never normalized.
    static func observedAppVersion(_ argument: String?) -> String? {
        let raw = argument ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        guard let raw, raw.unicodeScalars.count <= 32,
              raw.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return nil }
        return raw
    }

    private static func resolveAppVersion(_ argument: String?) -> String {
        if let observed = observedAppVersion(argument) { return observed }
        // Retain the legacy wire fallback for ordinary events, never for observation.
        let raw = argument ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        if let raw, let trimmed = nonEmptyTrimmed(raw) { return truncated(trimmed, to: 32) }
        return "1.0.0"
    }

    private static func nonEmptyTrimmed(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ s: String, to max: Int) -> String {
        guard s.unicodeScalars.count > max else { return s }
        var view = String.UnicodeScalarView()
        for (i, scalar) in s.unicodeScalars.enumerated() {
            if i >= max { break }
            view.append(scalar)
        }
        return String(view)
    }
}


/// Validate-and-log entry points. A refusal costs the whole **event**, not the field, and writes
/// exactly one line from the table below. No function here re-validates what `Envelope.event`
/// then trusts; gating is this file's job, at the call site where a log line has a meaning.
enum WireGate {
    /// One check, one message: `Grammar.isEventName` fails -> the name may not be sent. Nothing
    /// else — the struck schema-shadow refusals (reserved web/app names, a malformed
    /// `onboarding:` tail) are not this function's job; the schema's web-surface rules apply only
    /// `if s == "web"`, so an app event legitimately named e.g. `install` validates fine and it is
    /// the *server* that answers `unknown_event`.
    static func eventName(_ name: String, log: DebugLog) -> String? {
        guard Grammar.isEventName(name) else {
            log.log("drop event \(DebugLog.display(name)): spec/wire-v1.md §3 `n` is ^[a-z0-9_:.-]{1,64}$")
            return nil
        }
        return name
    }

    /// `nil` or empty props -> `true`. Otherwise, over the props sorted by key so the *first*
    /// failure logged is deterministic, in this order: the total count; every key's grammar; every
    /// string value's length; every number value's literal. There is no fifth check — the struck
    /// `status`-required rule for a raw `track` into the `onboarding:` namespace is not this
    /// function's job.
    static func validateTrackProps(_ props: [String: WireValue]?, eventName: String, log: DebugLog) -> Bool {
        guard let props, !props.isEmpty else { return true }

        if let origin = props["install_origin"] {
            guard eventName == "install", case .string(let value) = origin,
                  Jelto.InstallOrigin(rawValue: value) != nil else {
                log.log("drop event: install_origin is reserved for install and must be new, existing or unknown")
                return false
            }
        }

        if props.count > Wire.maxProps {
            log.log("drop event \(DebugLog.display(eventName)): props has \(props.count) keys, spec/wire-v1.md §3 caps them at \(Wire.maxProps)")
            return false
        }

        let keys = props.keys.sorted(by: Wire.byUTF8Bytes)

        for key in keys {
            guard Grammar.isPropKey(key) else {
                log.log("drop event \(DebugLog.display(eventName)): props key \(DebugLog.display(key)) does not match spec/wire-v1.md §3's ^[a-z0-9_]{1,32}$")
                return false
            }
        }

        for key in keys {
            if case .string(let s) = props[key]! {
                let n = s.unicodeScalars.count
                if n > Wire.maxPropString {
                    log.log("drop event \(DebugLog.display(eventName)): props value for \(DebugLog.display(key)) is \(n) chars, spec/wire-v1.md §3 caps a string at \(Wire.maxPropString)")
                    return false
                }
            }
        }

        for key in keys {
            if case .number(let literal) = props[key]!, !Grammar.isJSONNumberLiteral(literal) {
                log.log("drop event \(DebugLog.display(eventName)): props value for \(DebugLog.display(key)) is not a JSON number; spec/wire-v1.md §3 allows a string, a number or a boolean")
                return false
            }
        }

        return true
    }

    /// §8.1's sugar, and the trap C20 exercises. Returns `("onboarding:" + step, props)` and does
    /// nothing else: no extra key, no `i`, no timestamp, no marker, no ordering difference — the
    /// runner's congruence check compares an onboarding event against a `track` of the same name
    /// and props field by field.
    static func onboarding(step: String, status: String, reason: String?, log: DebugLog) -> (name: String, props: [String: WireValue])? {
        guard Grammar.isOnboardingStep(step) else {
            log.log("drop onboarding step \(DebugLog.display(step)): spec/wire-v1.md §4 `<step>` is ^[a-z0-9_-]{1,32}$")
            return nil
        }
        guard status == "ok" || status == "fail" || status == "skip" else {
            log.log("drop onboarding step \(DebugLog.display(step)): spec/wire-v1.md §4 `status` is ok|fail|skip, not \(DebugLog.display(status))")
            return nil
        }

        var props: [String: WireValue] = ["status": .string(status)]
        if let reason, !reason.isEmpty {
            guard Grammar.isOnboardingReason(reason), reason.unicodeScalars.count <= Wire.maxReasonChars else {
                log.log("drop onboarding step \(DebugLog.display(step)): spec/wire-v1.md §4 `reason` is ^[a-z0-9_.-]+$ and <= \(Wire.maxReasonChars) chars, not \(DebugLog.display(reason))")
                return nil
            }
            props["reason"] = .string(reason)
        }

        return (name: "onboarding:" + step, props: props)
    }

    /// Filters `raw` key by key, keeping only pairs where the key **and** the value pass their
    /// grammars. Order matters for C22c: the key first, then the value, `continue` on either
    /// failure so at most one line is logged per rejected key.
    static func installProps(_ raw: [String: String], log: DebugLog) -> [String: String] {
        var result: [String: String] = [:]
        for key in raw.keys.sorted(by: Wire.byUTF8Bytes) {
            guard key != "install_origin" else {
                log.log("drop install property: supply install_origin through initialization, not heartbeat properties")
                continue
            }
            guard Grammar.isPropKey(key) else {
                log.log("drop install property \(DebugLog.display(key)): spec/wire-v1.md §3 `props` keys are ^[a-z0-9_]{1,32}$")
                continue
            }
            let value = raw[key]!
            guard Grammar.isInstallPropValue(value) else {
                log.log("drop install property \(DebugLog.display(key)): spec/wire-v1.md §4 install-property values are ^[a-z0-9_.-]{1,24}$, not \(DebugLog.display(value))")
                continue
            }
            result[key] = value
        }
        return result
    }

    /// The cap check lives here so §3's number lives in one file; the merge itself lives elsewhere.
    static func withinPropCap(_ merged: [String: String], log: DebugLog) -> Bool {
        guard merged.count > Wire.maxProps else { return true }
        log.log("drop setprops: \(merged.count) install properties, spec/wire-v1.md §3 caps them at \(Wire.maxProps)")
        return false
    }

    /// The three-way distinction of W4: `nil` (env unset) -> the SDK's own `v`, silently.
    /// `""` (env set-but-empty) -> `nil`, **silently** — an empty `v` is an absent `v`, and W4's
    /// third arm asserts an empty sink alongside it. Anything else matching the grammar -> itself.
    /// Anything else -> `nil` with a log line. Never falls back to a bare number.
    static func clientVersion(override: String?, log: DebugLog) -> String? {
        guard let override else { return Wire.sdkClientVersion }
        if override.isEmpty { return nil }
        if Grammar.isClientVersion(override) { return override }
        log.log("client version \(DebugLog.display(override)) does not match spec/wire-v1.md §3's ^[a-z]+/[0-9A-Za-z.+-]{1,24}$; `v` is omitted")
        return nil
    }

    /// spec/wire-v1.md §2's `p`: `^prd_[a-z0-9]{10}$`. `init` is refused outright — not
    /// queued, not retried — when the caller's key does not match, with one debug line naming
    /// the rule.
    static func productKey(_ key: String, log: DebugLog) -> String? {
        guard Grammar.isProductKey(key) else {
            log.log("drop init: product key must match ^prd_[a-z0-9]{10}$")
            return nil
        }
        return key
    }

    /// `nil` for `nil` and for `""` (§5.2: an empty `a` is an absent `a`), the value when it
    /// passes the grammar, `nil` with a log line otherwise — dropped, never sent, because the
    /// server would answer `invalid_field` for every event carrying it.
    static func appSlug(_ raw: String?, log: DebugLog) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard Grammar.isAppSlug(raw) else {
            log.log("drop app slug \(DebugLog.display(raw)): spec/wire-v1.md §5.2 `a` is ^[a-z0-9-]{1,32}$")
            return nil
        }
        return raw
    }
}


/// A hand-written writer. `JSONSerialization` cannot be used for the body: it has no way to emit
/// `t` as `99999999999999999999`, it would round a prop literal, and its key order is unspecified.
private func appendJSONString(_ s: String, to data: inout Data) {
    data.append(UInt8(ascii: "\""))
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: data.append(contentsOf: [0x5C, 0x22]) // \"
        case 0x5C: data.append(contentsOf: [0x5C, 0x5C]) // \\
        case 0x08: data.append(contentsOf: Array("\\b".utf8))
        case 0x0C: data.append(contentsOf: Array("\\f".utf8))
        case 0x0A: data.append(contentsOf: Array("\\n".utf8))
        case 0x0D: data.append(contentsOf: Array("\\r".utf8))
        case 0x09: data.append(contentsOf: Array("\\t".utf8))
        case 0..<0x20:
            let hi = UInt8(scalar.value >> 4)
            let lo = UInt8(scalar.value & 0xF)
            data.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hexDigit(hi), hexDigit(lo)])
        default:
            data.append(contentsOf: Array(String(scalar).utf8))
        }
    }
    data.append(UInt8(ascii: "\""))
}

private func hexDigit(_ v: UInt8) -> UInt8 {
    v < 10 ? UInt8(ascii: "0") + v : UInt8(ascii: "a") + (v - 10)
}

/// `.string` through `appendJSONString`; `.bool` as `true`/`false`; `.number(literal)` written
/// raw — the ASCII bytes of the literal and nothing else. §3: the server stores a property's JSON
/// text unquoted and unrounded.
private func appendJSONValue(_ v: WireValue, to data: inout Data) {
    switch v {
    case .string(let s):
        appendJSONString(s, to: &data)
    case .bool(let b):
        data.append(contentsOf: Array((b ? "true" : "false").utf8))
    case .number(let literal):
        data.append(contentsOf: Array(literal.utf8))
    }
}

/// Keys sorted ascending by their UTF-8 bytes, so two encodings of the same map are
/// byte-identical — C20 compares the two `props` objects as raw JSON substrings.
private func appendProps(_ props: [String: WireValue], to data: inout Data) {
    data.append(UInt8(ascii: "{"))
    let keys = props.keys.sorted(by: Wire.byUTF8Bytes)
    for (i, key) in keys.enumerated() {
        if i > 0 { data.append(UInt8(ascii: ",")) }
        appendJSONString(key, to: &data)
        data.append(UInt8(ascii: ":"))
        appendJSONValue(props[key]!, to: &data)
    }
    data.append(UInt8(ascii: "}"))
}


enum Envelope {
    /// One JSON object: `id, n, t, s, iid, av, os, osv, arch, [a], [v], [props]`. Trusts its
    /// input and cannot fail — gating already happened in `WireGate`, at the call site where a
    /// log line has a meaning.
    static func event(
        _ e: QueuedEvent,
        platform: Platform,
        clientVersion: String?,
        installID: String,
        installProps: [String: String]
    ) -> Data {
        let platform = e.context?.platform ?? platform
        let clientVersion = e.context.map { $0.clientVersion } ?? clientVersion
        let installID = e.context?.installID ?? installID
        var data = Data()
        data.append(UInt8(ascii: "{"))

        data.append(contentsOf: Array("\"id\":".utf8))
        appendJSONString(e.id, to: &data)

        data.append(contentsOf: Array(",\"n\":".utf8))
        appendJSONString(e.name, to: &data)

        // `t` <- the ASCII bytes of `e.t.description`, written raw as a JSON number. Never
        // through `Double`, `Int64` or `NumberFormatter`: JSON has no integer type, and the
        // builder emits the digits it was given (C15b).
        data.append(contentsOf: Array(",\"t\":".utf8))
        data.append(contentsOf: Array(e.t.description.utf8))

        // This is the app SDK; §5.1 has no path here.
        data.append(contentsOf: Array(",\"s\":\"app\"".utf8))

        data.append(contentsOf: Array(",\"iid\":".utf8))
        appendJSONString(installID, to: &data)

        data.append(contentsOf: Array(",\"av\":".utf8))
        appendJSONString(platform.appVersion, to: &data)

        data.append(contentsOf: Array(",\"os\":".utf8))
        appendJSONString(platform.os, to: &data)

        data.append(contentsOf: Array(",\"osv\":".utf8))
        appendJSONString(platform.osVersion, to: &data)

        data.append(contentsOf: Array(",\"arch\":".utf8))
        appendJSONString(platform.arch, to: &data)

        // Emitted only when non-`nil`: a present `"a":""` fails `checkEventField(absent: true)`
        // just as much as a present value would.
        if let slug = platform.slug {
            data.append(contentsOf: Array(",\"a\":".utf8))
            appendJSONString(slug, to: &data)
        }

        if let clientVersion, !clientVersion.isEmpty {
            data.append(contentsOf: Array(",\"v\":".utf8))
            appendJSONString(clientVersion, to: &data)
        }

        // A heartbeat carries the app's CURRENT install properties, resolved by the caller at
        // send time — `e.props` is ignored for a heartbeat. Otherwise `e.props`, and
        // `installProps` is ignored. Emitted only when the chosen map is non-empty: an empty map
        // produces no `props` key at all, never `{}`.
        let chosenProps: [String: WireValue] = e.isHeartbeat
            ? installProps.mapValues { .string($0) }
            : (e.props ?? [:])
        if !chosenProps.isEmpty {
            data.append(contentsOf: Array(",\"props\":".utf8))
            appendProps(chosenProps, to: &data)
        }

        data.append(UInt8(ascii: "}"))
        return data
    }

    /// Assembles `{"v":1,"p":<key>,"e":[...]}` by hand so the byte budget is measured on the
    /// bytes actually sent, not on an estimate. Walks `events` in order, appending while both
    /// `used < 100` and the running body length (prefix included) plus this event's contribution
    /// stays within `maxBodyBytes`. On the first event that does not fit, **breaks** — never
    /// skips it and continues, because `used` is a *prefix* count the caller feeds to
    /// `queue.remove(used)`. If not even the first event fits, returns `(Data(), 0)`; the caller
    /// must not post an empty body.
    static func envelope(productKey: String, events: [Data]) -> (body: Data, used: Int) {
        var body = Data()
        body.append(contentsOf: Array("{\"v\":1,\"p\":".utf8))
        appendJSONString(productKey, to: &body)
        body.append(contentsOf: Array(",\"e\":[".utf8))

        var used = 0
        for event in events {
            guard used < Wire.maxEvents else { break }
            let extra = (used > 0 ? 1 : 0) + event.count + 2 // comma + event + closing `]}`
            guard body.count + extra <= Wire.maxBodyBytes else { break }

            if used > 0 { body.append(UInt8(ascii: ",")) }
            body.append(event)
            used += 1
        }

        guard used > 0 else { return (Data(), 0) }

        body.append(contentsOf: Array("]}".utf8))
        return (body, used)
    }
}
