.DEFAULT_GOAL := test
.PHONY: build test conformance conformance-run conformance-twice package security check lint

# The shared quality targets (hooks, tools, secrets, osv, workflow-audit, sast)
# arrive from the contracts repository as a checksummed snapshot; `make inputs`
# in the backend refreshes it, and nothing edits it here.
include vendor/quality/quality.mk
# opengrep community rules: every Swift rule (insecure randomness, sensitive
# data in UserDefaults, SQLite injection, WebView JavaScript bridges), and the
# Unicode rule for bidirectional control characters, which covers package.py,
# JSON and YAML (its language list does not include Swift).
QUALITY_COMMUNITY_RULES = swift generic/unicode/security
JELTO_CONTRACTS_DIR ?=
JELTO_CONTRACTS_VERSION = $(shell python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$(JELTO_CONTRACTS_DIR)/spec/contracts/manifest.json")

# Every compiler warning is an error in this repository's own builds. The flag
# lives here, not in Package.swift, because unsafeFlags there would stop other
# packages from depending on this one.
SWIFT_BUILD_FLAGS = -Xswiftc -warnings-as-errors

build:
	swift build $(SWIFT_BUILD_FLAGS)

test:
	swift test $(SWIFT_BUILD_FLAGS)

conformance: build
	$(MAKE) conformance-run

# The runner invocation alone, for a tree `build` has already produced.
conformance-run:
	@test -n "$(JELTO_CONTRACTS_DIR)" || { echo 'Set JELTO_CONTRACTS_DIR to a verified Jelto contracts archive.' >&2; exit 1; }
	go -C "$(JELTO_CONTRACTS_DIR)" run ./spec/conformance/runner -contracts-version "$(JELTO_CONTRACTS_VERSION)" -host "$$(swift build --show-bin-path)/conformance-host"

# spec/sdk-conformance.md §1: every scenario passes on a clean machine, twice.
# The passes share nothing -- each runner starts its own mockd on port 0 with a
# private control socket and gives every scenario a fresh JELTO_STATE_DIR under
# its own temporary directory -- so they run concurrently and the gate takes one
# pass's wall time, not two. The first pass's output is replayed once the second
# has finished so the log reads as two complete passes.
conformance-twice: build
	$(MAKE) conformance-run > "$${TMPDIR:-/tmp}/jelto-conformance-$$$$.log" 2>&1 & pid=$$!; \
	$(MAKE) conformance-run; second=$$?; \
	wait $$pid; first=$$?; \
	echo; echo '--- first pass (ran concurrently with the one above) ---'; \
	cat "$${TMPDIR:-/tmp}/jelto-conformance-$$$$.log"; rm -f "$${TMPDIR:-/tmp}/jelto-conformance-$$$$.log"; \
	test "$$first" -eq 0 && test "$$second" -eq 0

package:
	python3 package.py

# The whole gate: what to run before a pull request, and what CI runs.
# Conformance twice runs beside it in CI on release or on request. The package
# has no dependencies and so no lockfile, which leaves OSV-Scanner nothing to read.
check: lint test build package security

# swift-format (it ships with the Swift toolchain) checks both its rules and
# its layout against .swift-format; `swift format --in-place --recursive Sources
# Tests Package.swift` applies the layout. The JSON file cannot hold comments,
# so its choices are explained here. Layout settings match the existing code:
# four-space indentation, lines up to 200 columns, up to two blank lines
# between declarations, one space before an end-of-line comment, and #if
# bodies not indented. Two default rules are off because the code uses those
# forms on purpose: DoNotUseSemicolons (short statements share a line in case
# tables and one-line accessors) and NoBlockComments (inline /* x */ names
# beside hexadecimal scalar values). NeverForceUnwrap, NeverUseForceTry and
# NeverUseImplicitlyUnwrappedOptionals are on; swift-format itself exempts
# files that import XCTest, so they apply to Sources only.
lint:
	swift format lint --strict --recursive Sources Tests Package.swift

security: secrets workflow-audit sast
