APP_NAME  = Slackpad
BUILD_LOG = ./build.log

.PHONY: lint
lint:
	swiftlint lint --strict

.PHONY: build
build:
	set -o pipefail && xcodebuild build \
		-project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-destination 'generic/platform=macOS' \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO \
		| tee $(BUILD_LOG)

.PHONY: swiftlint-analyze
swiftlint-analyze: build
	swiftlint analyze --strict --compiler-log-path $(BUILD_LOG)

.PHONY: clean
clean:
	rm -f $(BUILD_LOG)
