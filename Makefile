# Build entry points for the core and its clients. See README.md.

# Cargo profile for the Apple core build. Use PROFILE=dev for debug symbols.
PROFILE ?= release
PROFILE_DIR := $(if $(filter dev,$(PROFILE)),debug,$(PROFILE))

APPLE_TARGETS := aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
FFI_LIB := libleafpdf_ffi.a
APPLE_GEN := apple/LeafCore/Generated

.PHONY: test lint apple apple-core apple-project apple-test clean

## Rust core

test:
	cargo test --workspace

lint:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings

## Apple clients (iOS, iPadOS, macOS)

apple: apple-core apple-project

# Builds the core for every Apple target and packages it, together with the
# generated Swift bindings, into the LeafCore Swift package.
apple-core:
	cargo build -p leafpdf-ffi --profile $(PROFILE) $(addprefix --target ,$(APPLE_TARGETS))
	rm -rf $(APPLE_GEN)
	cargo run -q -p leafpdf-ffi --features cli --bin uniffi-bindgen -- generate \
		--library target/aarch64-apple-darwin/$(PROFILE_DIR)/$(FFI_LIB) \
		--language swift --out-dir $(APPLE_GEN)/headers
	mkdir -p $(APPLE_GEN)/Swift
	mv $(APPLE_GEN)/headers/LeafCore.swift $(APPLE_GEN)/Swift/
	mv $(APPLE_GEN)/headers/LeafCoreFFI.modulemap $(APPLE_GEN)/headers/module.modulemap
	xcodebuild -create-xcframework \
		$(foreach t,$(APPLE_TARGETS),-library target/$(t)/$(PROFILE_DIR)/$(FFI_LIB) -headers $(APPLE_GEN)/headers) \
		-output $(APPLE_GEN)/LeafCoreFFI.xcframework
	rm -rf $(APPLE_GEN)/headers

apple-project:
	cd apple && xcodegen generate

apple-test: apple-core
	swift test --package-path apple/LeafCore

clean:
	cargo clean
	rm -rf $(APPLE_GEN) apple/LeafPDF.xcodeproj apple/LeafCore/.build
