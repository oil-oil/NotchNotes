import AppKit
import MarkdownEngine
import XCTest
@testable import NotchNotes

@MainActor
final class MarkdownListIndentationTests: XCTestCase {
    func testRepeatedTabIndentsOrderedMarkerAndBacktabRestoresEachLevel() {
        let (textView, coordinator) = makeEditor("1. item")

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\ta. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t\ta. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testBacktabPreservesRemainingIndentationWhenRestoringOrderedMarker() {
        let (textView, coordinator) = makeEditor("\t\ta. item")

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. item")
    }

    func testTabOnlyAddsIndentationToUnorderedAndTodoMarkers() {
        let cases = [
            ("- item", "\t- item"),
            ("• item", "\t• item"),
            ("- [ ] todo", "\t- [ ] todo"),
            ("• [x] done", "\t• [x] done")
        ]

        for (input, expected) in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(insertTab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, expected, input)
        }
    }

    func testBacktabRaisesUnorderedAndTodoItemsWithoutChangingMarkers() {
        let cases = [
            "\t- item",
            "\t• item",
            "\t- [ ] todo",
            "\t• [x] done"
        ]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertTrue(insertBacktab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, String(input.dropFirst()), input)
        }
    }

    func testBacktabDoesNotUnderflowTopLevelLists() {
        let cases = ["1. item", "a. item", "- item", "• item", "- [ ] todo"]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertTrue(insertBacktab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, input, input)
        }
    }

    private func makeEditor(_ text: String) -> (NSTextView, NativeTextViewCoordinator) {
        let wrapper = NativeTextViewWrapper(text: .constant(text))
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.string = text
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (textView, coordinator)
    }

    private func insertTab(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\t"
        )
    }

    private func insertBacktab(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    }
}
