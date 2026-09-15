import Foundation

// The public API forwards to a shared, lazily constructed Engine. Construction
// creates no files or sockets. Conformance-only accessors use SPI.
public enum Jelto {
    /// Host knowledge of the app installation before its first Jelto initialization.
    public enum InstallOrigin: String, Sendable {
        case new, existing, unknown
    }

    private static let engine = Engine()

    /// `endpoint` is for a customer on a first-party subdomain, who serves
    /// `/v1/e` on their own hostname. Omit it and the SDK sends to `spec/wire-v1.md` §1's
    /// production host, which is what every ordinary integration wants: a REQUIRED endpoint is
    /// one more thing every integration can get wrong, and getting it wrong is silent.
    public static func initialize(key: String, app: String? = nil, endpoint: String? = nil, installOrigin: InstallOrigin = .unknown) {
        engine.initialize(key: key, app: app, endpoint: endpoint, installOrigin: installOrigin)
    }

    public static func setProps(_ props: [String: String]) {
        engine.setProps(props)
    }

    /// §4.0: the customer's entry point. Swift *values*, not JSON text — a `Double` spelled
    /// `29.90` IS `29.9`, the literal was consumed by the compiler, and rendering from the value
    /// is the only thing available. Converts and calls `Engine.track(name:props:)` directly —
    /// the SAME function the SPI overload below calls, which is the "one gate" C20's congruence
    /// depends on (`Jelto.swift` is in the `Jelto` module itself, so it can see the internal
    /// `Engine`/`WireValue` types without needing `@_spi`; only the SPI overload's own public
    /// signature, crossing the module boundary to `ConformanceHost`, needs the mirror type below).
    public static func track(_ name: String, props: [String: Any]? = nil) {
        guard let props, !props.isEmpty else {
            engine.track(name: name, props: nil)
            return
        }

        var converted: [String: WireValue] = [:]
        converted.reserveCapacity(props.count)
        for (key, value) in props {
            guard let wireValue = Jelto.wireValue(for: value) else {
                // No `WireValue` case fits and wire §3 admits no other type: drop the WHOLE event,
                // not just this key, with a debug line.
                engine.log.log(
                    "drop event \(DebugLog.display(name)): props value for \(DebugLog.display(key)) has no wire representation; spec/wire-v1.md §3 admits a string, a number or a boolean"
                )
                return
            }
            converted[key] = wireValue
        }
        engine.track(name: name, props: converted)
    }

    public static func onboarding(_ step: String, status: String, reason: String? = nil) {
        engine.onboarding(step: step, status: status, reason: reason)
    }

    public static var installId: String {
        engine.installID()
    }

    public static func reset() {
        engine.reset()
    }

    public static func disable() {
        engine.disable()
    }

    /// §8.7 item 17 names `Jelto.debug = true` explicitly. Initial value is `JELTO_DEBUG == "1"`,
    /// read once at `Engine`'s construction.
    public static var debug: Bool {
        get { engine.log.isEnabled }
        set { engine.log.isEnabled = newValue }
    }

    // NSNumber bridges numeric 1 to Bool and true to Int. Check CFBoolean identity
    // before numeric conversion to preserve the wire value type.
    private static func wireValue(for value: Any) -> WireValue? {
        if let s = value as? String {
            return .string(s)
        }
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            let boolValue = (value as? NSNumber)?.boolValue ?? false
            return .bool(boolValue)
        }
        if let n = value as? NSNumber {
            // A shortest round-trip decimal — no `NumberFormatter`, no `Decimal`. `"\(1.5)"` is
            // `"1.5"`, which is what W1's `{"n":1.5}` needs.
            return .number("\(n)")
        }
        return nil
    }

    // Preserve raw numeric literals for conformance while using the same engine
    // event-name and property gates as the public track API.
    @_spi(Conformance) public static func track(_ name: String, wireProps: [String: WireValue]?) {
        engine.track(name: name, props: wireProps)
    }

    /// The host and the SDK must share ONE clock: this exposes the engine's own instance rather
    /// than a copy, so the host's `JELTO_NOW` pin and `sleep`'s advance move the very clock the
    /// pump reads.
    @_spi(Conformance) public static var conformanceClock: Clock {
        engine.clock
    }

    @_spi(Conformance) public static var isClockPinned: Bool {
        engine.clock.isPinned
    }

    @_spi(Conformance) public static func openBarrier() -> UInt64 {
        engine.openBarrier()
    }

    @_spi(Conformance) public static func awaitBarrier(_ seq: UInt64, timeoutMS: Int) -> Bool {
        engine.awaitBarrier(seq, timeoutMS: timeoutMS)
    }

    @_spi(Conformance) public static func stateExportJSON() -> Data {
        engine.exportState()
    }

    @_spi(Conformance) public static func legacyVersion() -> Bool {
        engine.legacyVersion()
    }

    @_spi(Conformance) public static func terminate() {
        engine.terminate()
    }
}
