import CoreGraphics

/// The text size of EPUBs, as a multiple of the size the book is designed for.
/// One per Device, shared by all EPUBs.
enum TextSize {
    /// The size the book is designed for.
    static let normal: CGFloat = 1
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3
    /// How much each ⌘+ / ⌘− step grows or shrinks the text.
    static let keyboardStep: CGFloat = 1.25

    static func clamped(_ size: CGFloat) -> CGFloat { min(max(size, minimum), maximum) }
    static func zoomedIn(from size: CGFloat) -> CGFloat { clamped(size * keyboardStep) }
    static func zoomedOut(from size: CGFloat) -> CGFloat { clamped(size / keyboardStep) }
}
