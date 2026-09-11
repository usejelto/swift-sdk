# Jelto Swift SDK

Privacy-focused desktop analytics for Swift apps on macOS 12 or later.
The standalone Swift 6 package contains the `Jelto` library, unit tests and a
`conformance-host` executable for SDK verification.

## Install locally

Version 0.1.0 is prepared for release; a public SwiftPM release is not yet
available. In Xcode, add this checkout as a local package dependency and link
the `Jelto` library product to your app target. For a source archive, run
`make package` and extract `artifacts/jelto-swift-0.1.0.zip` first.

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
See [RELEASING.md](RELEASING.md) for initial publication, trusted publishing,
version tags, and retries. Publishing stays disabled until explicitly configured.

## Community and license

Questions, bug reports and documentation improvements are welcome. See
[Support](https://github.com/usejelto/swift-sdk/blob/main/SUPPORT.md),
[Contributing](https://github.com/usejelto/swift-sdk/blob/main/CONTRIBUTING.md),
[Code of Conduct](https://github.com/usejelto/swift-sdk/blob/main/CODE_OF_CONDUCT.md), and
[Security policy](https://github.com/usejelto/swift-sdk/blob/main/SECURITY.md).
Until the public repository is available, these files are also included in the
source root; contact [taha@jelto.io](mailto:taha@jelto.io) for help.

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
