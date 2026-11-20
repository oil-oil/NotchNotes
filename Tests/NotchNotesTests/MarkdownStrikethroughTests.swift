import AppKit
import XCTest
@testable import MarkdownEngine

final class MarkdownStrikethroughTests: XCTestCase {
    func testParsesStrikethroughTokenWithMarkers() throws {
        let text = "a ~~ddd~~ b"
        let tokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .strikethrough }

        let token = try XCTUnwrap(tokens.first)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(token.range, NSRange(location: 2, length: 7))
        XCTAssertEqual(token.contentRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(token.markerRanges, [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2)])
    }

    func testIgnoresInvalidStrikethroughDelimiters() {
        let cases = [
            "~~ ddd~~",
            "~~ddd ~~",
            "~~~~",
            "~ddd~",
            "~~~ddd~~~",
            "~~dd\ndd~~"
        ]
        for text in cases {
            let tokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .strikethrough }
            XCTAssertTrue(tokens.isEmpty, "Expected no strikethrough in \(text.debugDescription)")
        }
    }

    func testParsesMultipleStrikethroughsOnOneLine() {
        let tokens = MarkdownTokenizer.parseTokens(in: "~~a~~ and ~~b c~~")
            .filter { $0.kind == .strikethrough }
        XCTAssertEqual(tokens.map(\.contentRange), [
            NSRange(location: 2, length: 1),
            NSRange(location: 12, length: 3)
        ])
    }

    func testStylerAppliesStrikethroughToContentOnly() {
        let text = "x ~~ddd~~"
        let styled = styleAttributes(for: text)

        let struck = styled.filter { $0.attributes[.strikethroughStyle] != nil }
        XCTAssertEqual(struck.map(\.range), [NSRange(location: 4, length: 3)])
        XCTAssertEqual(struck.first?.attributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testStruckTextAndLineUseMutedColor() throws {
        let muted = NSColor(white: 0.58, alpha: 1)
        let theme = MarkdownEditorTheme(mutedText: muted, strikethroughColor: .red)
        let configuration = MarkdownEditorConfiguration(theme: theme)

        let struck = try XCTUnwrap(
            styleAttributes(for: "~~ddd~~", configuration: configuration)
                .first { $0.attributes[.strikethroughStyle] != nil }
        )
        XCTAssertEqual(struck.attributes[.foregroundColor] as? NSColor, muted)
        XCTAssertEqual(struck.attributes[.strikethroughColor] as? NSColor, muted)
    }

    func testIgnoresMarkersInsideInlineAndFencedCode() {
        let text = "`~~literal` ~~real~~\n```\n~~literal~~\n```"
        let tokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .strikethrough }
        XCTAssertEqual(tokens.map { (text as NSString).substring(with: $0.contentRange) }, ["real"])
    }

    func testStrikeCanEncloseInlineCode() {
        let text = "~~before `code` after~~"
        let struck = styleAttributes(for: text).filter { $0.attributes[.strikethroughStyle] != nil }
        XCTAssertEqual(struck.map(\.range), [NSRange(location: 2, length: 19)])
    }

    func testIgnoresEscapedMarkersAndRestartsAtNewline() {
        let cases = [
            #"\~~literal~~"#,
            #"~~literal\~~"#,
            "~~unfinished\u{2028}later~~"
        ]
        for text in cases {
            XCTAssertFalse(MarkdownTokenizer.parseTokens(in: text).contains { $0.kind == .strikethrough }, text)
        }

        let text = #"\\~~real~~"#
        let tokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .strikethrough }
        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 2, length: 8)])
    }

    private func styleAttributes(
        for text: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        MarkdownStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 13).fontName,
            fontSize: 13,
            caretLocation: 0,
            activeTokenIndices: [],
            configuration: configuration
        )
    }
}
