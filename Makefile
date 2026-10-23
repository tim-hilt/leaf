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

# App tests: ONLY narrows to a suite or test, e.g. ONLY=LeafTests/ReaderPDFViewTests.
ONLY ?= LeafTests
SIM ?= iPad Pro 13-inch (M5)
XCTEST = scripts/apple-test.sh -only-testing:$(ONLY)

.PHONY: test lint fmt apple apple-core apple-project apple-build apple-test apple-test-ios clean

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

apple-test: apple-core apple-build
	$(XCTEST) -destination 'platform=macOS'

# The same tests on an iOS Simulator, for iOS-only code. SIM picks the device.
apple-test-ios: apple-core apple-project
	$(XCTEST) -destination 'platform=iOS Simulator,name=$(SIM)'

clean:
	cargo clean
	rm -rf $(APPLE_GEN) apple/Leaf.xcodeproj apple/LeafCore/.build
