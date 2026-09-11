// Implements spec/sdk-conformance.md §3 commands against Jelto. Props and dumpstate
// retain raw number literals instead of passing through JSONSerialization.
// Top-level host state is MainActor-isolated; SDK work remains in Sources/Jelto.

@_spi(Conformance) import Jelto
import Dispatch
import Foundation


// Swift's `print` is block-buffered when stdout is a pipe, and the runner drives the host
// through a pipe. Every reply goes through FileHandle.standardOutput.write(_:), an unbuffered
// write(2). Do not call `print` anywhere in this file.
func writeReply(_ reply: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    data.append(0x0A) // "\n"
    FileHandle.standardOutput.write(data)
}

func writeStderrLine(_ message: String) {
    // The only lines this file itself ever writes to stderr: the three fatal-misconfiguration
    // lines below (each followed by exit(2)) and §5.2's one settle-timeout line. Everything else
    // on stderr is the SDK's own `DebugLog`.
    let data = (message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
}


struct HostEnvironment {
    let endpoint: String
    let stateDir: String
    let now: String? // presence is the pin; nil means unset
    let debug: Bool
    let mock: String?
    let clientVersion: String?
}

func readEnvironment() -> HostEnvironment {
    let env = ProcessInfo.processInfo.environment

    guard let endpoint = env["JELTO_ENDPOINT"], !endpoint.isEmpty else {
        writeStderrLine("JELTO_ENDPOINT is required")
        exit(2)
    }
    guard let stateDir = env["JELTO_STATE_DIR"], !stateDir.isEmpty else {
        writeStderrLine("JELTO_STATE_DIR is required")
        exit(2)
    }

    // `environment["JELTO_NOW"]` is nil when unset and "" when set-but-empty; presence is the pin.
    let now = env["JELTO_NOW"]
    let debug = env["JELTO_DEBUG"] == "1"
    let mock = env["JELTO_MOCK"]
    let clientVersion = env["JELTO_CLIENT_VERSION"]

    return HostEnvironment(
        endpoint: endpoint,
        stateDir: stateDir,
        now: now,
        debug: debug,
        mock: mock,
        clientVersion: clientVersion
    )
}

let hostEnvironment = readEnvironment()
// This command-line host has a known application version even without a bundle.
if ProcessInfo.processInfo.environment["JELTO_APP_VERSION"] == nil {
    setenv("JELTO_APP_VERSION", "1.0.0", 1)
}

// The host and the SDK share ONE clock: `Jelto.conformanceClock` is the engine's own instance,
// not a private copy. Touching it for the first time here
// lazily constructs `Engine`, which reads `JELTO_NOW` itself (Engine.swift §2.0) and pins to the
// same value validated below; the explicit `.pin(to:)` call keeps this host's own fatal
// misconfiguration check — which must run BEFORE anything is committed — in the same shape plan 1
// left it in.
if let now = hostEnvironment.now {
    let trimmed = now.trimmingCharacters(in: .whitespaces)
    guard let parsed = Instant(decimal: trimmed) else {
        writeStderrLine("JELTO_NOW is not a valid decimal instant")
        exit(2)
    }
    Jelto.conformanceClock.pin(to: parsed)
}

//
// Ports refhost/main.go's `tokenize` exactly:
//   1. Skip runs of spaces and tabs between tokens.
//   2. A token beginning with `"` runs to the next unescaped `"`; a backslash escapes the next
//      byte; the quotes are not part of the token.
//   3. A token beginning with `{` or `[` takes the rest of the line, whitespace-trimmed, and
//      tokenizing stops there.
//   4. Otherwise the token runs to the next space or tab.
// Operates on UTF-8 bytes, not Characters, so a multi-byte value cannot split a token.
func tokenize(_ line: String) -> [String] {
    let bytes = Array(line.utf8)
    var tokens: [String] = []
    var i = 0
    let n = bytes.count
    let space = UInt8(ascii: " ")
    let tab = UInt8(ascii: "\t")
    let quote = UInt8(ascii: "\"")
    let backslash = UInt8(ascii: "\\")
    let openBrace = UInt8(ascii: "{")
    let openBracket = UInt8(ascii: "[")

    func isSpace(_ b: UInt8) -> Bool { b == space || b == tab }

    while i < n {
        while i < n && isSpace(bytes[i]) {
            i += 1
        }
        guard i < n else { break }

        if bytes[i] == quote {
            i += 1
            var tokenBytes: [UInt8] = []
            while i < n && bytes[i] != quote {
                if bytes[i] == backslash && i + 1 < n {
                    tokenBytes.append(bytes[i + 1])
                    i += 2
                } else {
                    tokenBytes.append(bytes[i])
                    i += 1
                }
            }
            if i < n {
                i += 1 // skip closing quote
            }
            tokens.append(String(decoding: tokenBytes, as: UTF8.self))
        } else if bytes[i] == openBrace || bytes[i] == openBracket {
            let rest = Array(bytes[i...])
            var trimmedStart = 0
            var trimmedEnd = rest.count
            while trimmedStart < trimmedEnd && isSpace(rest[trimmedStart]) {
                trimmedStart += 1
            }
            while trimmedEnd > trimmedStart && isSpace(rest[trimmedEnd - 1]) {
                trimmedEnd -= 1
            }
            tokens.append(String(decoding: rest[trimmedStart..<trimmedEnd], as: UTF8.self))
            i = n
        } else {
            var tokenBytes: [UInt8] = []
            while i < n && !isSpace(bytes[i]) {
                tokenBytes.append(bytes[i])
                i += 1
            }
            tokens.append(String(decoding: tokenBytes, as: UTF8.self))
        }
    }
    return tokens
}

//
// `JSONSerialization` would re-render `{"n":29.90}` as `29.9`, destroying the exact `Double`
// round-trip `WireValue.number` exists to preserve. This scanner never
// parses a number into a `Double`/`Int`/`NSNumber`/`Decimal` at any point: it captures the run of
// `[-+.0-9eE]` characters and hands the literal straight through — `Grammar.isJSONNumberLiteral`,
// inside the SDK, is what later judges whether it is legal (spec/sdk-conformance.md §5's own
// wording). `nil` means the token is not a well-formed JSON object; that is the ONE new condition
// this host may answer `ok:false` to.

private let byteQuote = UInt8(ascii: "\"")
private let byteBackslash = UInt8(ascii: "\\")
private let byteColon = UInt8(ascii: ":")
private let byteComma = UInt8(ascii: ",")
private let byteOpenBrace = UInt8(ascii: "{")
private let byteCloseBrace = UInt8(ascii: "}")
private let byteOpenBracket = UInt8(ascii: "[")
private let byteCloseBracket = UInt8(ascii: "]")

private func isJSONWhitespace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

private func hexDigitValue(_ b: UInt8) -> UInt16? {
    switch b {
    case 0x30...0x39: return UInt16(b - 0x30)
    case 0x41...0x46: return UInt16(b - 0x41 + 10)
    case 0x61...0x66: return UInt16(b - 0x61 + 10)
    default: return nil
    }
}

func scanProps(_ text: String) -> [String: WireValue]? {
    let bytes = Array(text.utf8)
    var i = 0
    let n = bytes.count

    func skipWhitespace() {
        while i < n, isJSONWhitespace(bytes[i]) { i += 1 }
    }

    func matchLiteral(_ literal: String) -> Bool {
        let litBytes = Array(literal.utf8)
        guard i + litBytes.count <= n else { return false }
        for k in 0..<litBytes.count where bytes[i + k] != litBytes[k] {
            return false
        }
        i += litBytes.count
        return true
    }

    func hex4() -> UInt16? {
        guard i + 4 <= n else { return nil }
        var value: UInt16 = 0
        for k in 0..<4 {
            guard let d = hexDigitValue(bytes[i + k]) else { return nil }
            value = value << 4 | d
        }
        i += 4
        return value
    }

    // A JSON string, standard escapes included (`\" \\ \/ \b \f \n \r \t \uXXXX`, with surrogate
    // pairs reassembled). `nil` on anything malformed or unterminated.
    func scanString() -> String? {
        guard i < n, bytes[i] == byteQuote else { return nil }
        i += 1
        var result = Data()
        while true {
            guard i < n else { return nil } // unterminated
            let b = bytes[i]
            if b == byteQuote {
                i += 1
                return String(decoding: result, as: UTF8.self)
            }
            if b == byteBackslash {
                guard i + 1 < n else { return nil }
                let escape = bytes[i + 1]
                switch escape {
                case byteQuote: result.append(byteQuote); i += 2
                case byteBackslash: result.append(byteBackslash); i += 2
                case UInt8(ascii: "/"): result.append(UInt8(ascii: "/")); i += 2
                case UInt8(ascii: "b"): result.append(0x08); i += 2
                case UInt8(ascii: "f"): result.append(0x0C); i += 2
                case UInt8(ascii: "n"): result.append(0x0A); i += 2
                case UInt8(ascii: "r"): result.append(0x0D); i += 2
                case UInt8(ascii: "t"): result.append(0x09); i += 2
                case UInt8(ascii: "u"):
                    i += 2
                    guard let unit1 = hex4() else { return nil }
                    var scalarValue = UInt32(unit1)
                    if unit1 >= 0xD800, unit1 <= 0xDBFF {
                        guard i + 1 < n, bytes[i] == byteBackslash, bytes[i + 1] == UInt8(ascii: "u") else {
                            return nil
                        }
                        i += 2
                        guard let unit2 = hex4(), unit2 >= 0xDC00, unit2 <= 0xDFFF else { return nil }
                        scalarValue = 0x10000 + (UInt32(unit1 - 0xD800) << 10) + UInt32(unit2 - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
                    result.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            } else if b < 0x20 {
                return nil // a raw control character in a JSON string is invalid
            } else {
                result.append(b)
                i += 1
            }
        }
    }

    // Captures the run of `[-+.0-9eE]` verbatim, never validating the shape itself — the SDK's
    // `Grammar.isJSONNumberLiteral` is what decides legality, and does so per key (dropping only
    // that one event, not the whole command) rather than this scanner failing the whole object.
    func scanNumberLiteral() -> String? {
        let start = i
        while i < n {
            let b = bytes[i]
            let isNumberChar = (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: "-") || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
                || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
            guard isNumberChar else { break }
            i += 1
        }
        guard i > start else { return nil }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    // Skips one JSON value this scanner cannot represent (`null`, a nested object, an array),
    // respecting strings nested inside so a `}`/`]` inside one cannot end the skip early.
    func skipBalanced(open: UInt8, close: UInt8) -> Bool {
        guard i < n, bytes[i] == open else { return false }
        var depth = 0
        while i < n {
            let b = bytes[i]
            if b == byteQuote {
                guard scanString() != nil else { return false }
                continue
            }
            if b == open {
                depth += 1
                i += 1
                continue
            }
            if b == close {
                depth -= 1
                i += 1
                if depth == 0 { return true }
                continue
            }
            i += 1
        }
        return false
    }

    skipWhitespace()
    guard i < n, bytes[i] == byteOpenBrace else { return nil }
    i += 1
    var result: [String: WireValue] = [:]

    skipWhitespace()
    if i < n, bytes[i] == byteCloseBrace {
        i += 1
    } else {
        while true {
            skipWhitespace()
            guard let key = scanString() else { return nil }
            skipWhitespace()
            guard i < n, bytes[i] == byteColon else { return nil }
            i += 1
            skipWhitespace()
            guard i < n else { return nil }

            switch bytes[i] {
            case byteQuote:
                guard let s = scanString() else { return nil }
                result[key] = .string(s)
            case UInt8(ascii: "t"):
                guard matchLiteral("true") else { return nil }
                result[key] = .bool(true)
            case UInt8(ascii: "f"):
                guard matchLiteral("false") else { return nil }
                result[key] = .bool(false)
            case UInt8(ascii: "n"):
                // `null` -> the key is dropped; `WireValue` has no case for it (§5.0).
                guard matchLiteral("null") else { return nil }
            case byteOpenBrace:
                guard skipBalanced(open: byteOpenBrace, close: byteCloseBrace) else { return nil }
            case byteOpenBracket:
                guard skipBalanced(open: byteOpenBracket, close: byteCloseBracket) else { return nil }
            default:
                guard let literal = scanNumberLiteral() else { return nil }
                result[key] = .number(literal)
            }

            skipWhitespace()
            guard i < n else { return nil }
            if bytes[i] == byteComma {
                i += 1
                continue
            }
            if bytes[i] == byteCloseBrace {
                i += 1
                break
            }
            return nil
        }
    }

    skipWhitespace()
    guard i == n else { return nil } // trailing bytes after the object
    return result
}


private let settleBudgetSeconds: TimeInterval = 30

private func settle(until deadline: Date) -> Bool {
    let seq = Jelto.openBarrier()
    let remainingMS = max(0, Int(deadline.timeIntervalSinceNow * 1000))
    if Jelto.awaitBarrier(seq, timeoutMS: remainingMS) {
        return true
    }
    writeStderrLine("conformance-host: sleep did not settle within 30 s of real time")
    return false
}

func handleSleep(_ ms: Int64) {
    guard Jelto.isClockPinned else {
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
        return
    }
    let deadline = Date().addingTimeInterval(settleBudgetSeconds)
    guard settle(until: deadline) else { return }
    Jelto.conformanceClock.advance(by: ms)
    _ = settle(until: deadline)
}


func errorReply(_ cmd: String, _ error: String) -> [String: Any] {
    ["cmd": cmd, "ok": false, "error": error]
}

func okReply(_ cmd: String) -> [String: Any] {
    ["cmd": cmd, "ok": true]
}

/// `dumpstate`'s reply is assembled by hand as bytes, not through `JSONSerialization`: the
/// export's instants are decimal STRINGS and re-encoding them through a JSON library that treats
/// them as text is fine, but the safest way to guarantee no byte moves is to splice the SDK's own
/// already-serialized `state` object straight in (§5's carve-out).
func writeDumpstateReply() {
    var data = Data("{\"cmd\":\"dumpstate\",\"ok\":true,\"state\":".utf8)
    data.append(Jelto.stateExportJSON())
    data.append(UInt8(ascii: "}"))
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

while let rawLine = readLine(strippingNewline: true) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") {
        continue
    }

    let tokens = tokenize(line)
    guard let cmd = tokens.first else { continue }

    switch cmd {
    case "init":
        if tokens.count >= 2 {
            let key = tokens[1]
            let app = tokens.count > 2 ? tokens[2] : nil
            let start = DispatchTime.now().uptimeNanoseconds
            Jelto.initialize(key: key, app: app)
            let elapsedNS = DispatchTime.now().uptimeNanoseconds - start
            let us = Int(elapsedNS / 1_000)
            writeReply(["cmd": "init", "ok": true, "us": us])
        } else {
            writeReply(errorReply("init", "init <key> [app]"))
        }

    case "track":
        guard tokens.count >= 2 else {
            writeReply(errorReply("track", "track <name> [json-props]"))
            break
        }
        let name = tokens[1]
        if tokens.count > 2 {
            guard let props = scanProps(tokens[2]) else {
                writeReply(errorReply("track", "track <name> [json-props]"))
                break
            }
            Jelto.track(name, wireProps: props)
        } else {
            Jelto.track(name, wireProps: nil)
        }
        writeReply(okReply("track"))

    case "onboarding":
        // The host validates nothing here: C20b's two bad calls must reach the SDK, which is what
        // logs the two asserted regexes.
        if tokens.count >= 3 {
            let reason = tokens.count > 3 ? tokens[3] : nil
            Jelto.onboarding(tokens[1], status: tokens[2], reason: reason)
            writeReply(okReply("onboarding"))
        } else {
            writeReply(errorReply("onboarding", "onboarding <step> <ok|fail|skip> [reason]"))
        }

    case "setprops":
        guard tokens.count >= 2 else {
            writeReply(errorReply("setprops", "setprops <json>"))
            break
        }
        guard let scanned = scanProps(tokens[1]) else {
            writeReply(errorReply("setprops", "setprops <json>"))
            break
        }
        // §8.1 types the API [String: String]; a non-string value has no representation there.
        var stringProps: [String: String] = [:]
        for (key, value) in scanned {
            if case .string(let s) = value {
                stringProps[key] = s
            }
        }
        Jelto.setProps(stringProps)
        writeReply(okReply("setprops"))

    case "installid":
        writeReply(["cmd": "installid", "ok": true, "value": Jelto.installId])

    case "dumpstate":
        writeDumpstateReply()

    case "legacyversion":
        writeReply(["cmd": "legacyversion", "ok": Jelto.legacyVersion()])

    case "reset":
        Jelto.reset()
        writeReply(okReply("reset"))

    case "disable":
        Jelto.disable()
        writeReply(okReply("disable"))

    case "sleep":
        if tokens.count >= 2, let ms = Int64(tokens[1]), ms >= 0 {
            handleSleep(ms)
            writeReply(okReply("sleep"))
        } else {
            writeReply(errorReply("sleep", "sleep <ms>: a whole number >= 0"))
        }

    case "exit":
        Jelto.terminate()
        writeReply(okReply("exit"))
        exit(0)

    default:
        writeReply(errorReply(
            cmd,
            "unknown command; spec/sdk-conformance.md §3 has init, track, onboarding, setprops, installid, dumpstate, reset, disable, sleep, exit"
        ))
    }
}

// EOF — the runner killed the host. §3.1 allows exactly one line per command and EOF is not a
// command, so nothing is printed here (a deliberate departure from refhost's `eof` reply, which
// the runner never reads after closing stdin).
exit(0)
