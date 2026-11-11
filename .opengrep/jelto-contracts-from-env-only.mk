# ruleid: jelto-contracts-from-env-only
JELTO_CONTRACTS_DIR ?= $(CURDIR)/../contracts

conformance-run:
	# ruleid: jelto-contracts-from-env-only
	go -C ../contracts run ./spec/conformance/runner
	# ok: jelto-contracts-from-env-only
	go -C "$(JELTO_CONTRACTS_DIR)" run ./spec/conformance/runner
