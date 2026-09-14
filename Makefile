.DEFAULT_GOAL := test
.PHONY: build test conformance conformance-run conformance-twice package
JELTO_CONTRACTS_DIR ?=
JELTO_CONTRACTS_VERSION = $(shell python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$(JELTO_CONTRACTS_DIR)/spec/contracts/manifest.json")

build:
	swift build

test:
	swift test

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
