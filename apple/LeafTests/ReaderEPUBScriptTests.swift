import Foundation
import Testing

@testable import Leaf

@Suite struct ReaderEPUBScriptTests {
    @Test func theConfigurationCarriesTheBooksValues() throws {
        let config = try configuration(
            of: ReaderEPUBScript.source(lengths: [120, 7], start: (1, 40), textSize: 1.25, appearance: .light))

        #expect(config["lengths"] as? [Int] == [120, 7])
        #expect(config["start"] as? [Int] == [1, 40])
        #expect(config["textSize"] as? Double == 1.25)
        #expect(config["appearance"] is NSNull)
        #expect(config["channel"] as? String == ReaderEPUBScript.channel)
    }

    @Test func noStartIsNullAndDarkPagesCarryTheirColorsAsCSS() throws {
        let colors = PageColors(paper: RGB(0.5, 0, 1), ink: RGB(1, 1, 1))
        let config = try configuration(
            of: ReaderEPUBScript.source(lengths: [], start: nil, textSize: 1, appearance: .dark(colors)))

        #expect(config["start"] is NSNull)
        #expect(
            config["appearance"] as? [String: String] == ["paper": "rgb(128, 0, 255)", "ink": "rgb(255, 255, 255)"])
    }

    /// The configuration the script sets: the JSON of its `window.leafConfig` line.
    private func configuration(of source: String) throws -> [String: Any] {
        let line = try #require(source.split(separator: "\n", maxSplits: 1).first)
        let json = line.dropFirst("window.leafConfig = ".count).dropLast()
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
