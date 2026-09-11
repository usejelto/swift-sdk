// Debug output is strictly opt-in: disabled logging must leave stderr byte-empty (C10).

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One line on stderr per call, prefixed `jelto: `. `final class … : @unchecked Sendable`
/// guarded by a single `NSLock`, which also serialises writes so two threads cannot interleave
/// halves of a line.
final class DebugLog: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private let sink: @Sendable (Data) -> Void

    /// Appendix A's public shape: `init(enabled:)` delegates to the sink initialiser with the
    /// default stderr sink, so callers outside this file never see the second initialiser.
    convenience init(enabled: Bool) {
        self.init(enabled: enabled, sink: DebugLog.stderrSink)
    }

    /// The internal second initialiser: takes a sink so the unit tests can read
    /// what would have gone to stderr instead of writing to the process's real stderr.
    init(enabled: Bool, sink: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        self.sink = sink
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
        }
    }

    /// One line: `"jelto: "` + `message` + `"\n"`, written in a single call under the lock.
    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        var data = Data("jelto: ".utf8)
        data.append(contentsOf: Array(message.utf8))
        data.append(0x0A)
        sink(data)
    }

    /// One line: `"jelto: POST "` + `body` unaltered + `"\n"`, written in a single call under the
    /// lock. No pretty-printing, no re-encoding, no truncation, no escaping — C17 compares stderr
    /// against the bytes mockd received with `strings.Contains`, so a prefix on the same line is
    /// fine and an altered byte is not.
    func payload(_ body: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        var data = Data("jelto: POST ".utf8)
        data.append(body)
        data.append(0x0A)
        sink(data)
    }

    /// The default sink: `fwrite` to `stderr` followed by `fflush(stderr)`. Not `print`, which is
    /// block-buffered on a pipe; not `FileHandle.write`, which raises an uncatchable
    /// Objective-C exception on a broken pipe and would kill the host mid-run.
    private static let stderrSink: @Sendable (Data) -> Void = { data in
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            fwrite(base, 1, raw.count, stderr)
        }
        fflush(stderr)
    }

    /// Wraps `s` in ASCII double quotes, replaces every scalar `< 0x20` and `0x7F` with `?`, and
    /// truncates the inner text to the first 120 unicode scalars followed by `…`. Every log line
    /// must stay one line — a caller-supplied newline inside a message would split a line the
    /// scenario expects whole. Never applied to `payload`.
    static func display(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        var truncated = false
        for (i, scalar) in s.unicodeScalars.enumerated() {
            if i >= 120 {
                truncated = true
                break
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                view.append(Unicode.Scalar(UInt8(ascii: "?")))
            } else {
                view.append(scalar)
            }
        }
        var inner = String(view)
        if truncated {
            inner += "…"
        }
        return "\"" + inner + "\""
    }
}
