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

        for text in ["~~ddd~~", "- [x] done"] {
            let styled = styleAttributes(for: text, configuration: configuration)
            let struck = try XCTUnwrap(
                styled.first { $0.attributes[.strikethroughStyle] != nil },
                "Expected strikethrough in \(text.debugDescription)"
            )
            XCTAssertEqual(struck.attributes[.foregroundColor] as? NSColor, muted, text)
            XCTAssertEqual(struck.attributes[.strikethroughColor] as? NSColor, muted, text)
        }
    }

    func testStylerSkipsStrikethroughInsideInlineCode() {
        let styled = styleAttributes(for: "`~~ddd~~`")
        XCTAssertTrue(styled.allSatisfy { $0.attributes[.strikethroughStyle] == nil })
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
