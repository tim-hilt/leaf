# LeafPDF

## Setup

Requires macOS on Apple silicon.

1. Install [Xcode](https://developer.apple.com/xcode/) and select it:
   `sudo xcode-select -s /Applications/Xcode.app`
2. Install [rustup](https://rustup.rs). The toolchain and Apple targets in `rust-toolchain.toml` are installed on first use.
3. Install XcodeGen: `brew install xcodegen`

## Core

```sh
make test   # run tests
make lint   # rustfmt + clippy
```

## Apple clients (iOS, iPadOS, macOS)

```sh
make apple                    # build core into apple/LeafCore, generate the Xcode project
open apple/LeafPDF.xcodeproj  # run the LeafPDF scheme on a simulator or "My Mac"
```

- After changing Rust code: `make apple-core`
- After adding/removing Swift files or editing `apple/project.yml`: `make apple-project`
- Swift binding tests: `make apple-test`
- Debug build of the core: `make apple-core PROFILE=dev`
- Running on a device: create `apple/Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team ID>`

Command-line builds:

```sh
xcodebuild -project apple/LeafPDF.xcodeproj -scheme LeafPDF -destination 'platform=macOS' build
xcodebuild -project apple/LeafPDF.xcodeproj -scheme LeafPDF -destination 'generic/platform=iOS Simulator' build
```
