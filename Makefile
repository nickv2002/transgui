.PHONY: release build notarize install test generate

VERSION ?= $(shell scripts/next_version.sh)

# Full release pipeline: build → sign → notarize → changelog → tag → push → GitHub release → install
release:
	scripts/release.sh

# Archive and export a Developer-ID-signed Release build
build:
	scripts/build_release.sh

# Notarize, staple, and zip (requires VERSION, e.g. make notarize VERSION=2026.06.23.1)
notarize:
	scripts/notarize.sh "$(VERSION)"

# Install the exported .app to /Applications
install:
	scripts/install_local.sh

# Run unit tests
test:
	xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
		-configuration Debug test

# Regenerate the Xcode project from project.yml
generate:
	xcodegen generate
