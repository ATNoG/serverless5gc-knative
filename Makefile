.PHONY: test test-unit test-integration build lint clean build-functions build-images build-proxy

MODULE := github.com/haidinhtuan/serverless5gc

test-unit:
	go test ./... -v -count=1

test-integration:
	go test ./... -v -count=1 -tags=integration

test: test-unit

build-proxy:
	go build -o bin/sctp-proxy ./cmd/sctp-proxy/

build-functions:
	deploy/knative/build-images.sh

build-images: build-functions

lint:
	golangci-lint run ./...

clean:
	rm -rf bin/
