.DEFAULT_GOAL := test
.PHONY: build test conformance package
JELTO_CONTRACTS_DIR ?=
JELTO_CONTRACTS_VERSION = $(shell python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$(JELTO_CONTRACTS_DIR)/spec/contracts/manifest.json")

build:
	swift build

test:
	swift test

conformance: build
	@test -n "$(JELTO_CONTRACTS_DIR)" || { echo 'Set JELTO_CONTRACTS_DIR to a verified Jelto contracts archive.' >&2; exit 1; }
	go -C "$(JELTO_CONTRACTS_DIR)" run ./spec/conformance/runner -contracts-version "$(JELTO_CONTRACTS_VERSION)" -host "$$(swift build --show-bin-path)/conformance-host"

package:
	python3 package.py
