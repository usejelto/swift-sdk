# Jelto Swift SDK

Privacy-focused desktop analytics for Swift apps on macOS 12 or later.
The standalone Swift 6 package contains the `Jelto` library, unit tests and a
`conformance-host` executable for SDK verification.

## Install

In Xcode, open **File → Add Package Dependencies**, enter
`https://github.com/usejelto/swift-sdk`, choose the latest release and link the
`Jelto` library product to your app target. In a `Package.swift` manifest, add
the same URL as a package dependency and `Jelto` as a target dependency. For
local development, add this checkout as a local package instead; `make package`
writes a source archive to `artifacts/`.

Initialize once after your app decides analytics may start, then report a
registered action:

```swift
import Jelto

Jelto.initialize(key: "YOUR_PRODUCT_ID", app: "desktop")
Jelto.setProps(["license": "trial"])
Jelto.track("export_finished", props: ["format": "pdf"])
```

Replace the product ID and app slug with your registered values. Register event
and property names in Jelto before sending them. See the
[Swift integration guide](https://jelto.io/docs/sdk/swift) for consent, event
registration, installation identity, reset and disable behavior.

## Apps with existing users

Supply an optional host classification before changing your app's saved first-launch
state:

```swift
Jelto.initialize(key: "YOUR_PRODUCT_ID", app: "desktop", installOrigin: .existing)
```

Use `.new` only when the host knows this is the app installation's first launch,
`.existing` when it predates Jelto, or `.unknown` (the default) when unsure. A
missing onboarding-complete flag alone does not prove a new installation. The SDK
sends only the category on its install claim, never your saved date or onboarding
history. The category stays fixed across retries and relaunches; an older claim
without it stays unknown. `reset()` creates an unknown claim, and `disable()`
followed by initialization can capture a newly supplied category. Do not put
`install_origin` in `setProps`; heartbeats never carry it.

## Development and conformance

From this directory, run `make build` and `make test` (or `swift build` and
`swift test`). Set `JELTO_CONTRACTS_DIR` to an extracted Jelto contracts **0.1.0**
archive, then run `make conformance` twice before certification. The archive
supplies the Go runner, mock server and wire schema without the backend source.

The host exposes only the SDK testing protocol; applications link the `Jelto`
library. See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites and verification.

## Repository CI and releases

The component-owned workflows become active when this directory is the
repository root. CI runs local package tests; release CI additionally requires
conformance twice and the configured contracts pin where applicable.
See [RELEASING.md](https://github.com/usejelto/swift-sdk/blob/main/RELEASING.md) for initial publication, trusted publishing,
version tags, and retries. Publishing stays disabled until explicitly configured.

## Community and license

Questions, bug reports and documentation improvements are welcome. See
[Support](https://github.com/usejelto/swift-sdk/blob/main/SUPPORT.md),
[Contributing](https://github.com/usejelto/swift-sdk/blob/main/CONTRIBUTING.md),
[Code of Conduct](https://github.com/usejelto/swift-sdk/blob/main/CODE_OF_CONDUCT.md), and
[Security policy](https://github.com/usejelto/swift-sdk/blob/main/SECURITY.md).
Contact [taha@jelto.io](mailto:taha@jelto.io) for anything else.

Jelto-owned software and associated documentation use the [MIT license](LICENSE).
Third-party materials retain their own terms, including the Contributor Covenant
attribution. Jelto names, logos, mascots and original brand artwork are excluded
from the software license; no trademark rights are granted.

## Specification references

Source comments cite `spec/wire-v1.md` (the wire contract: envelope, fields, statuses,
retry rules) and `spec/sdk-conformance.md` (the behavioural contract, whose `C…` and `W…`
identifiers name conformance scenarios). Neither file ships in this repository: both live in
the public contracts repository at <https://github.com/usejelto/contracts/tree/main/spec>.
A comment that states a rule in words and then cites a section is pointing at the normative
text for that rule.
