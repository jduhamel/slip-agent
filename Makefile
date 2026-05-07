all: build

clean:
	rm -f *.so

lint:
	golangci-lint run

build:
	go mod tidy
	go build -buildmode=plugin -o agent.so *.go

test: build
	make -C test

test-live: build
	AGENT_LIVE_TESTS=1 make -C test

refresh-fixtures: build
	AGENT_TEST_MODE=record AGENT_LIVE_TESTS=1 make -C test

.PHONY: all build clean lint test test-live refresh-fixtures
