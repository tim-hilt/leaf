# Core reaches Apple clients as a generated Swift package

`make apple-core` compiles the core for every Apple target and writes an XCFramework plus UniFFI Swift bindings into the local `apple/LeafCore` package (generated parts not committed). Apps and future extensions (e.g. Share) just depend on `LeafCore`. We avoid running cargo from an Xcode build phase, because Xcode's environment lacks the Rust toolchain and script sandboxing makes that fragile.

## Consequences

- Run `make apple-core` after changing Rust code.
- Only Apple silicon is built (`arm64`); Intel Macs and Intel simulators are unsupported.
