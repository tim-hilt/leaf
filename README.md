[![Build](https://github.com/tim-hilt/leaf/actions/workflows/build.yml/badge.svg)](https://github.com/tim-hilt/leaf/actions/workflows/build.yml)
[![Test](https://github.com/tim-hilt/leaf/actions/workflows/test.yml/badge.svg)](https://github.com/tim-hilt/leaf/actions/workflows/test.yml)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="Leaf Logo" width="150">
  </picture>
</p>

## Intro

Leaf is a minimalistic e-book reader that can be used to read, annotate and sync .pdf and .epub files. The application is implemented with a portable Rust Core and native UI clients. Currently, there are client implementations for iOS, iPadOS and MacOS, as these run on my own devices.

Leaf is an application I wanted to build for quite some time, but the idea of learning native UI stacks and looking deeply into the .pdf file format specification seemed daunting. With the help of AI, anything is possible. The bulk of the current work was done in around a week of investing 2-3 hours per day, but the design and featureset were defined quite some time ago already.

## Features

- Reading .pdf and .epub files
- Annotating text (text-highlight, notes on highlights, free notes on the page)
  - Annotations are lightweight coordinates+metadata rendered on top of the screen. The original book document is never altered
  - Text highlight colors can be customized
- Reading progress is synced and restored across devices
- Customizable dark page rendering for reading at night time
- (Self hostable) cross-device syncing without a sophisticated server - only WebDAV or an authenticated account to Google Drive, One Drive or iCloud Drive are enough
- Local first - all data is on the device **always**. Syncing is done incrementally and the data is saved to a folder you can easily discover. You own the data.

<p align="center">
  <img src="docs/images/light-dark-pages.png" alt="Leaf showing the same page with light and dark pages" width="400">
</p>

## History

During my commute to university, I read [Python for Data Analysis](https://wesmckinney.com/book/) by Wes McKinney (which is a great book by the way - it taught me a lot). I used KDEs Okular PDF reader to annotate and some application (don't remember the name) for syncing to Google Drive. I annotate the books I read heavily. At around 75% of reading the book, the repeated saving and adding notifications slowed down. The document view got white for a few seconds and then it came back and rendered the book. Scrolling became laggy. At some point, I took a look at the file in the Dolphin file explorer and noticed, that the file grew to around 4x its original size, which increased load on the pdf rendering and syncing.

While this might have changed for Okular and other pdf readers, I began my search for the ultimate cross platform pdf editor with annotation, syncing and dark page rendering features. The best one I found was [PDF Viewer by Nutrient](https://apps.apple.com/us/app/pdf-viewer-by-nutrient/id1120099014) (which interestingly was originally built by [Peter Steinberger](https://en.wikipedia.org/wiki/Peter_Steinberger), which I just found out recently).

However, this app is not local-first. It also saves pdf files in place, resulting in big network load for syncing. Syncing is done by just keeping the pdf files in a folder on your device, that is being synced anyways. Starting the app sometimes results in a white page (because something is being downloaded...? I don't know). It also can't handle .epub files, which is another goal I had in mind.

So... Nothing is perfect of course. I'm not putting the blame on the existing products, but on my stubbornness and overspecific requirements. This application might not be suitable for you. But it fits all of *my* use cases perfectly. Developing this thing was mainly bottlenecked by my underpowered base-model MacBook Air M1 and the lack of a paid Apple developer account. Other than that, adding features and debugging went smoothly. And now I have created my perfect pdf editor myself, although I have not written much of the code myself.

## Setup

Requires macOS on Apple silicon.

1. Install [Xcode](https://developer.apple.com/xcode/) and select it:
   `sudo xcode-select -s /Applications/Xcode.app`
2. Install [rustup](https://rustup.rs). The toolchain and Apple targets in `rust-toolchain.toml` are installed on first use.
3. Install XcodeGen: `brew install xcodegen`
4. Enable the pre-commit hook (runs `make lint`): `git config core.hooksPath .githooks`

## Core

```sh
make test   # run tests
make lint   # rustfmt, clippy, swift format
make fmt    # fix formatting (Rust and Swift)
```

## Apple clients (iOS, iPadOS, macOS)

```sh
make apple                    # build core into apple/LeafCore, generate the Xcode project
open apple/Leaf.xcodeproj  # run the Leaf scheme on a simulator or "My Mac"
```

- After changing Rust code: `make apple-core`
- After adding/removing Swift files or editing `apple/project.yml`: `make apple-project`
- Build for macOS and the iOS Simulator: `make apple-build` (regenerates the project first)
- Tests, including both builds: `make apple-test` (macOS)
- Tests on an iOS Simulator, for iOS-only code: `make apple-test-ios` (`SIM=<device name>`)
- Narrow either to a suite or test: `ONLY=LeafTests/ReaderPDFViewTests`. Full log: `/tmp/leaf-test.log`
- Debug build of the core: `make apple-core PROFILE=dev`
- OAuth clients for Google Drive and OneDrive (maintainer, one-off, re-runnable): `scripts/cloud-oauth-wizard.sh`
- Running on a device: create `apple/Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team ID>`

### Install on an iPad without opening Xcode

One-time: enable Developer Mode on the iPad (Settings → Privacy & Security). Connect it by cable and tap Trust. For Wi-Fi installs, tick Xcode → Window → Devices and Simulators → your iPad → **Connect via network** (same Wi-Fi as the Mac).

```sh
make apple
cd apple && xcodebuild -scheme Leaf -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl list devices   # find the iPad
xcrun devicectl device install app --device "<iPad name>" build/Build/Products/Release-iphoneos/Leaf.app
```

Free Apple ID builds expire after 7 days; install again to renew.
