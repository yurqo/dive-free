TEAM_ID := $(shell security find-generic-password -s "apple-team-id" -w 2>/dev/null)
WORKSPACE := DiveFree.xcworkspace
SIM_IOS := platform=iOS Simulator,name=iPhone 17
XCFLAGS := CODE_SIGNING_ALLOWED=NO EXCLUDED_ARCHS=x86_64

.PHONY: generate build test clean testflight release

generate:
	TUIST_DEVELOPMENT_TEAM=$(TEAM_ID) tuist generate --no-open

build:
	set -o pipefail && xcodebuild build \
		-workspace $(WORKSPACE) \
		-scheme DiveFree \
		-destination "generic/platform=iOS Simulator" \
		$(XCFLAGS) | xcbeautify

test:
	tuist test

clean:
	rm -rf DiveFree.xcodeproj DiveFree.xcworkspace Derived

# Trigger a signed delivery via GitHub Actions (auto version bump + build number).
# testflight = patch bump (beta); release = minor bump (you submit for review by hand).
testflight:
	gh workflow run testflight.yml -f bump=patch

release:
	gh workflow run testflight.yml -f bump=minor
