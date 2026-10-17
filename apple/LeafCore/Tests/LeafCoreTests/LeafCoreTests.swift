import LeafCore
import Testing

/// Exercises the whole binding pipeline: the XCFramework links and UniFFI's
/// startup checksum check passes, i.e. bindings and library match.
@Test func coreIsCallableFromSwift() {
    #expect(!coreVersion().isEmpty)
}
