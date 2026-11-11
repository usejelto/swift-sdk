import Foundation

func contractsDirectory() -> URL? {
    // ruleid: jelto-contracts-from-env-only
    let sibling = URL(fileURLWithPath: "../contracts")
    // ruleid: jelto-contracts-from-env-only
    let nested = URL(fileURLWithPath: #filePath).appendingPathComponent("../../jelto-contracts/spec")
    // ruleid: jelto-contracts-from-env-only
    let joined = URL(fileURLWithPath: "..").appendingPathComponent("contracts")
    // ruleid: jelto-contracts-from-env-only
    let appended = URL(fileURLWithPath: "..").appending(path: "contracts")
    _ = (sibling, nested, joined, appended)

    // ok: jelto-contracts-from-env-only
    let fromEnv = ProcessInfo.processInfo.environment["JELTO_CONTRACTS_DIR"].map { URL(fileURLWithPath: $0) }
    // ok: jelto-contracts-from-env-only
    let local = URL(fileURLWithPath: ".contracts").appendingPathComponent("spec")
    // ok: jelto-contracts-from-env-only
    let vendored = URL(fileURLWithPath: "../vendor/quality/quality.mk")
    _ = (local, vendored)
    return fromEnv
}
