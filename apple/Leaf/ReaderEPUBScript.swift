import CoreGraphics
import Foundation

/// The script `ReaderEPUBView` injects into the page that stacks the chapter frames: `ReaderEPUB.js`,
/// which documents the page's contract, after the book's configuration as `window.leafConfig`.
enum ReaderEPUBScript {
    static let channel = "reader"

    /// `ReaderEPUB.js`, read once. A missing file is a broken build.
    private static let pageScript: String = {
        guard let url = Bundle.main.url(forResource: "ReaderEPUB", withExtension: "js"),
            let script = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("ReaderEPUB.js is missing from the app bundle") }
        return script
    }()

    /// `appearance` as the page's JSON: the Page Colors as CSS colors, or null for Light Pages.
    static func appearance(of appearance: PageAppearance) -> Any {
        guard case .dark(let colors) = appearance else { return NSNull() }
        func css(_ color: RGB) -> String {
            let byte = { (value: Double) in Int((value * 255).rounded()) }
            return "rgb(\(byte(color.r)), \(byte(color.g)), \(byte(color.b)))"
        }
        return ["paper": css(colors.paper), "ink": css(colors.ink)]
    }

    /// The script for the chapters whose texts are `lengths` long (UTF-16 units) at `textSize`
    /// (`TextSize`) in `appearance`; it opens at the position `start` (chapter index, offset).
    static func source(
        lengths: [UInt64], start: (chapter: Int, offset: Int)?, textSize: CGFloat, appearance: PageAppearance
    ) -> String {
        let startJSON: Any = if let start { [start.chapter, start.offset] } else { NSNull() }
        let configuration: [String: Any] = [
            "channel": channel,
            "lengths": lengths,
            "start": startJSON,
            "textSize": Double(textSize),
            "appearance": self.appearance(of: appearance),
        ]
        // Only JSON-safe values, so serializing cannot fail.
        let json = try! JSONSerialization.data(withJSONObject: configuration)
        return "window.leafConfig = \(String(decoding: json, as: UTF8.self));\n" + pageScript
    }
}
