all: build

clean:
	rm -f *.so

lint:
	golangci-lint run

build:
	go mod tidy
	go build -buildmode=plugin -o agent.so *.go

# `make test` — hermetic.  Replays HTTP fixtures from
# test/fixtures/<provider>/.  No API keys required.  This is what CI runs.
test: build
	make -C test

# `make test-live` — every test against the real provider.  Requires
# AGENT_LIVE_TESTS=1 and the relevant API key envs (ANTHROPIC_API_KEY).
# Run before a release cut to verify fixtures haven't drifted.
test-live: build
	AGENT_TEST_MODE=live AGENT_LIVE_TESTS=1 make -C test

# `make refresh-fixtures` — make real HTTP calls and overwrite each
# fixture file with the captured response.  Use after a wire-format
# change or when first capturing fixtures.  Same env-var requirements
# as test-live.  Commit any resulting deltas in test/fixtures/.
refresh-fixtures: build
	AGENT_TEST_MODE=record AGENT_LIVE_TESTS=1 make -C test

.PHONY: all build clean lint test test-live refresh-fixtures
