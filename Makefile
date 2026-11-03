# Build entry points for the core and its clients. See README.md.

# Cargo profile for the Apple core build. Use PROFILE=dev for debug symbols.
PROFILE ?= release
PROFILE_DIR := $(if $(filter dev,$(PROFILE)),debug,$(PROFILE))

APPLE_TARGETS := aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
FFI_LIB := libleaf_ffi.a
APPLE_GEN := apple/LeafCore/Generated
SWIFT_SRC := apple/Leaf apple/LeafTests
XCODEBUILD := cd apple && xcodebuild -quiet -scheme Leaf
CORE_SRC := $(shell find core ffi -type f) Cargo.toml Cargo.lock rust-toolchain.toml Makefile
CORE_STAMP := $(APPLE_GEN)/.built-$(PROFILE)

# App tests: ONLY narrows to suites or tests, e.g. ONLY="LeafTests/ReaderPDFViewTests LeafTests/ThemeAppearanceTests".
ONLY ?= LeafTests
XCTEST = scripts/apple-test.sh $(foreach t,$(ONLY),'-only-testing:$(t)')

# The simulated devices; SIM picks one, e.g. SIM='$(SIM_IPHONE)'. The iPad stands in for
# the 3rd generation, which the iOS 27 runtime can't simulate.
SIM_IPHONE := iPhone 15 Pro
SIM_IPAD := iPad Pro (12.9-inch) (4th generation)
SIM ?= $(SIM_IPAD)

.PHONY: test lint fmt apple apple-core apple-project apple-build apple-ipa apple-test apple-test-ios apple-sim apple-run clean

## Rust core

test:
	cargo test --workspace

lint:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	swift format lint --strict -r $(SWIFT_SRC)

fmt:
	cargo fmt --all
	swift format -i -r $(SWIFT_SRC)

## Apple clients (iOS, iPadOS, macOS)

apple: apple-core apple-project

# Builds the core for every Apple target and packages it, together with the
# generated Swift bindings, into the LeafCore Swift package. Skipped while the
# Rust sources are unchanged. Deployment targets match apple/project.yml, so C
# dependencies link without warnings. The path remap keeps home directories
# out of panic messages in the shipped binary.
apple-core: $(CORE_STAMP)

$(CORE_STAMP): $(CORE_SRC)
	IPHONEOS_DEPLOYMENT_TARGET=26.0 MACOSX_DEPLOYMENT_TARGET=27.0 \
	RUSTFLAGS="--remap-path-prefix=$(HOME)=~" \
		cargo build -p leaf-ffi --profile $(PROFILE) $(addprefix --target ,$(APPLE_TARGETS))
	rm -rf $(APPLE_GEN)
	cargo run -q -p leaf-ffi --features cli --bin uniffi-bindgen -- generate \
		--library target/aarch64-apple-darwin/$(PROFILE_DIR)/$(FFI_LIB) \
		--language swift --out-dir $(APPLE_GEN)/headers
	mkdir -p $(APPLE_GEN)/Swift
	mv $(APPLE_GEN)/headers/LeafCore.swift $(APPLE_GEN)/Swift/
	mv $(APPLE_GEN)/headers/LeafCoreFFI.modulemap $(APPLE_GEN)/headers/module.modulemap
	xcodebuild -create-xcframework \
		$(foreach t,$(APPLE_TARGETS),-library target/$(t)/$(PROFILE_DIR)/$(FFI_LIB) -headers $(APPLE_GEN)/headers) \
		-output $(APPLE_GEN)/LeafCoreFFI.xcframework
	rm -rf $(APPLE_GEN)/headers
	swift test --package-path apple/LeafCore
	touch $@

apple-project:
	cd apple && xcodegen generate --quiet

# Builds the app for macOS and the iOS Simulator. Regenerates the project
# first, so new Swift files are picked up.
apple-build: apple-project
	$(XCODEBUILD) build -destination 'platform=macOS'
	$(XCODEBUILD) build -destination 'generic/platform=iOS Simulator'

# Builds an unsigned Leaf.ipa for sideloading (SideStore resigns it on the device).
# Generated with CODE_SIGNING_ALLOWED=NO, so no provisioning profile travels along.
IpaProduct := apple/build/Build/Products/Release-iphoneos
apple-ipa: apple-core apple-project
	$(XCODEBUILD) build -configuration Release -destination 'generic/platform=iOS' \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO
	rm -rf apple/build/Payload apple/build/Leaf.ipa
	mkdir -p apple/build/Payload
	cp -R $(IpaProduct)/Leaf.app apple/build/Payload/
	cd apple/build && zip -qry Leaf.ipa Payload
	@echo "apple/build/Leaf.ipa"

apple-test: apple-core apple-build
	$(XCTEST) -destination 'platform=macOS'

# The same tests on an iOS Simulator, for iOS-only code. One at a time: web views on
# screen at once disturb each other's scrolling there.
apple-test-ios: apple-core apple-project apple-sim
	$(XCTEST) -parallel-testing-enabled NO -destination 'platform=iOS Simulator,name=$(SIM)'

# Creates the SIM device unless it exists.
apple-sim:
	xcrun simctl list devices available | grep -qF '    $(SIM) (' || xcrun simctl create '$(SIM)' '$(SIM)'

# Builds the app and launches it on SIM, to look at it:
# xcrun simctl io booted screenshot /tmp/leaf.png
# xcrun simctl ui booted appearance dark|light
apple-run: apple-core apple-project apple-sim
	$(XCODEBUILD) build -destination 'platform=iOS Simulator,name=$(SIM)'
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	xcrun simctl install '$(SIM)' "$$($(XCODEBUILD) -showBuildSettings -destination 'platform=iOS Simulator,name=$(SIM)' | awk '$$1 == "CODESIGNING_FOLDER_PATH" { print $$3 }')"
	xcrun simctl launch --terminate-running-process '$(SIM)' com.timhilt.leaf

clean:
	cargo clean
	rm -rf $(APPLE_GEN) apple/Leaf.xcodeproj apple/LeafCore/.build
