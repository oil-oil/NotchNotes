import AppKit
@testable import MarkdownEngine
import SwiftUI
import XCTest
@testable import NotchNotes

@MainActor
final class SlashCommandTests: XCTestCase {

    // MARK: - Trigger Rules

    func testTriggerMatchesAtLineStartAndAfterSpaceOrTab() {
        let lineStart = detect("/")
        XCTAssertEqual(lineStart?.slashLocation, 0)
        XCTAssertEqual(lineStart?.query, "")
        XCTAssertEqual(lineStart?.triggerRange, NSRange(location: 0, length: 1))

        let secondLine = detect("第一行\n/todo")
        XCTAssertEqual(secondLine?.slashLocation, 4)
        XCTAssertEqual(secondLine?.lineStartLocation, 4)
        XCTAssertEqual(secondLine?.query, "todo")

        let afterSpace = detect("备注 /h1")
        XCTAssertEqual(afterSpace?.slashLocation, 3)
        XCTAssertEqual(afterSpace?.query, "h1")
        XCTAssertEqual(afterSpace?.triggerRange, NSRange(location: 3, length: 3))

        let afterTab = detect("\t/quote")
        XCTAssertEqual(afterTab?.slashLocation, 1)
        XCTAssertEqual(afterTab?.query, "quote")
    }

    func testTriggerRejectsURLsFilePathsDivisionSelectionsAndLongQueries() {
        let nonTriggerCases = [
            "https:/",
            "https://",
            "https://example.com/docs",
            "path/to/file",
            "a/b",
            "/Users/",
            "/Users/a",
            "/Users/linzhihuang/Notes",
            "/h1 extra",
            "/ ",
            "/" + String(repeating: "a", count: 25)
        ]

        for sample in nonTriggerCases {
            XCTAssertNil(detect(sample), "Expected nil trigger for: \(sample)")
        }

        // Non-empty selection must never trigger.
        let selectedMatch = SlashCommandEngine.detectTrigger(
            in: "/h1",
            selectedRange: NSRange(location: 1, length: 2)
        )
        XCTAssertNil(selectedMatch)

        // Exactly 24 chars is still allowed.
        let maxAllowed = "/" + String(repeating: "a", count: 24)
        XCTAssertEqual(detect(maxAllowed)?.query.count, 24)
    }

    func testTriggerRejectsFencedCodeBlocksInlineCodeMarkdownLinksAndWikiLinks() {
        let fencedOpen = "```swift\n/h1"
        XCTAssertNil(detect(fencedOpen))

        let fencedClosedMiddleText = "```\n/todo\n```"
        let middleSlashCursor = ("```\n/todo" as NSString).length
        XCTAssertNil(
            SlashCommandEngine.detectTrigger(
                in: fencedClosedMiddleText,
                selectedRange: NSRange(location: middleSlashCursor, length: 0)
            )
        )

        // After a closed fenced code block, `/` on a normal line must trigger again.
        let afterClosedFence = "```\nlet x = 1\n```\n/h1"
        XCTAssertEqual(detect(afterClosedFence)?.query, "h1")

        // Inline code spans (closed and unclosed) must not trigger.
        let closedInlineCode = "Use `cmd /h1` here"
        let insideInlineCursor = ("Use `cmd /h1" as NSString).length
        XCTAssertNil(
            SlashCommandEngine.detectTrigger(
                in: closedInlineCode,
                selectedRange: NSRange(location: insideInlineCursor, length: 0)
            )
        )
        XCTAssertNil(detect("Use `cmd /h1"))
        XCTAssertEqual(detect("Use `cmd` /h1")?.query, "h1")

        // Markdown links `[...](...)` and WikiLinks `[[...]]` must not trigger inside.
        let mdLinkLabel = "[See /h1](https://example.com)"
        let mdLinkLabelCursor = ("[See /h1" as NSString).length
        XCTAssertNil(
            SlashCommandEngine.detectTrigger(
                in: mdLinkLabel,
                selectedRange: NSRange(location: mdLinkLabelCursor, length: 0)
            )
        )
        XCTAssertNil(detect("[See](https://example.com /h1"))
        XCTAssertEqual(detect("[See](https://example.com) /h1")?.query, "h1")

        let wikiLink = "[[Project /todo]]"
        let wikiCursor = ("[[Project /todo" as NSString).length
        XCTAssertNil(
            SlashCommandEngine.detectTrigger(
                in: wikiLink,
                selectedRange: NSRange(location: wikiCursor, length: 0)
            )
        )
        XCTAssertNil(detect("[[Project /todo"))
        XCTAssertEqual(detect("[[Project]] /todo")?.query, "todo")

        // Task list checkbox `- [ ] /today` must still trigger.
        XCTAssertEqual(detect("- [ ] /today")?.query, "today")
    }

    // MARK: - Built-in Catalog & Bilingual Filtering

    func testBuiltInCatalogIconsAndBilingualKeywordOrdering() {
        XCTAssertEqual(
            SlashCommandEngine.builtInItems.map(\.id),
            ["h1", "h2", "h3", "todo", "bullet", "number", "quote", "code", "divider", "today", "now", "link"]
        )

        for item in SlashCommandEngine.builtInItems {
            XCTAssertNotNil(
                NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil),
                "Missing SF Symbol: \(item.iconName)"
            )
        }

        // Empty query returns full list in frequency order.
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "").count, 12)

        // Bilingual & alias matches.
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "待办").first?.id, "todo")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "task").first?.id, "todo")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "check").first?.id, "todo")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "标题").map(\.id), ["h1", "h2", "h3"])
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "##").map(\.id), ["h2", "h3"])
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "ul").first?.id, "bullet")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "ol").first?.id, "number")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "hr").first?.id, "divider")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "代码").first?.id, "code")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "日期").first?.id, "today")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "date").first?.id, "today")
        XCTAssertEqual(SlashCommandEngine.filterItems(query: "time").first?.id, "now")

        // Prefix hits must rank ahead of contains-only hits:
        // For query "o", `number` has keyword prefix ("ol", "ordered"), while `todo`/`quote`/`code` only contain "o".
        let oMatches = SlashCommandEngine.filterItems(query: "o").map(\.id)
        XCTAssertEqual(oMatches.first, "number")
        XCTAssertTrue(oMatches.contains("todo"))

        // Non-matching query produces empty array.
        XCTAssertTrue(SlashCommandEngine.filterItems(query: "Users").isEmpty)
    }

    // MARK: - Replacement, Block Newlines, UTF-16 Emoji & Fixed Date

    func testLineStartVersusMidLineBlockReplacementAndCaretPositions() {
        // Line-start / whitespace-only prefix replaces leading spaces + `/query`.
        let leadingSpacesH1 = applyCommand("h1", to: "   /h1")
        XCTAssertEqual(leadingSpacesH1.updatedText, "# ")
        XCTAssertEqual(leadingSpacesH1.selectedRange, NSRange(location: 2, length: 0))

        // Tab-indented list preserves list tab indentation.
        let indentedTodo = applyCommand("todo", to: "\t/todo")
        XCTAssertEqual(indentedTodo.updatedText, "\t- [ ] ")
        XCTAssertEqual(indentedTodo.selectedRange, NSRange(location: 7, length: 0))

        // Mid-line block command replaces preceding space + `/h1` with `\n# `.
        let midLineH1 = applyCommand("h1", to: "备注 /h1")
        XCTAssertEqual(midLineH1.updatedText, "备注\n# ")
        XCTAssertEqual(midLineH1.selectedRange, NSRange(location: 5, length: 0))

        // Code block places caret on the middle blank line both at line start and mid-line with Emoji!
        let codeAtStart = applyCommand("code", to: "/code")
        XCTAssertEqual(codeAtStart.updatedText, "```\n\n```")
        XCTAssertEqual(codeAtStart.selectedRange, NSRange(location: 4, length: 0))

        let emojiMidLineCode = "👨‍👩‍👧‍👦备注 /code"
        let codeMidLine = applyCommand("code", to: emojiMidLineCode)
        XCTAssertEqual(codeMidLine.updatedText, "👨‍👩‍👧‍👦备注\n```\n\n```")
        let expectedMiddleLineUTF16 = ("👨‍👩‍👧‍👦备注\n```\n" as NSString).length
        XCTAssertEqual(codeMidLine.selectedRange, NSRange(location: expectedMiddleLineUTF16, length: 0))

        // Link command selects `"link text"` accurately even after multi-scalar Emoji + CJK.
        let linkSource = "👨‍👩‍👧‍👦查看 /link 后缀"
        let linkCursor = ("👨‍👩‍👧‍👦查看 /link" as NSString).length
        let linkMatch = SlashCommandEngine.detectTrigger(
            in: linkSource,
            selectedRange: NSRange(location: linkCursor, length: 0)
        )!
        let linkItem = SlashCommandEngine.builtInItems.first { $0.id == "link" }!
        let linkResult = SlashCommandEngine.apply(item: linkItem, match: linkMatch, in: linkSource)
        XCTAssertEqual(linkResult.updatedText, "👨‍👩‍👧‍👦查看 [link text](url) 后缀")
        XCTAssertEqual(
            (linkResult.updatedText as NSString).substring(with: linkResult.selectedRange),
            "link text"
        )
    }

    func testTodayAndNowFormattingWithFixedDate() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let fixedDate = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 5)
        )!

        let todayMatch = detect("日期 /today")!
        let todayItem = SlashCommandEngine.builtInItems.first { $0.id == "today" }!
        let todayResult = SlashCommandEngine.apply(
            item: todayItem,
            match: todayMatch,
            in: "日期 /today",
            now: fixedDate,
            timeZone: utc
        )
        XCTAssertEqual(todayResult.updatedText, "日期 2026-11-14")
        XCTAssertEqual(
            todayResult.selectedRange,
            NSRange(location: ("日期 2026-11-14" as NSString).length, length: 0)
        )

        let nowMatch = detect("时间 /now")!
        let nowItem = SlashCommandEngine.builtInItems.first { $0.id == "now" }!
        let nowResult = SlashCommandEngine.apply(
            item: nowItem,
            match: nowMatch,
            in: "时间 /now",
            now: fixedDate,
            timeZone: utc
        )
        XCTAssertEqual(nowResult.updatedText, "时间 09:05")
        XCTAssertEqual(
            nowResult.selectedRange,
            NSRange(location: ("时间 09:05" as NSString).length, length: 0)
        )
    }

    // MARK: - Session State Machine, Esc Suppression & IME Guard

    func testSessionNavigationEscSuppressionAndMarkedTextGuard() {
        let session = SlashCommandSession()

        // Marked text before session starts must not trigger menu.
        session.update(
            text: "/h",
            selectedRange: NSRange(location: 2, length: 0),
            hasMarkedText: true
        )
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.activeMatch)

        // Normal `/head` activates with 3 heading items.
        session.update(text: "/head", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.filteredItems.map(\.id), ["h1", "h2", "h3"])
        XCTAssertEqual(session.selectedIndex, 0)

        // Wrap-around keyboard navigation.
        XCTAssertEqual(session.handleCommandSelector(#selector(NSResponder.moveUp(_:))), .handled)
        XCTAssertEqual(session.selectedIndex, 2)
        XCTAssertEqual(session.selectedItem?.id, "h3")

        XCTAssertEqual(session.handleCommandSelector(#selector(NSResponder.moveDown(_:))), .handled)
        XCTAssertEqual(session.selectedIndex, 0)
        XCTAssertEqual(session.selectedItem?.id, "h1")

        // Enter / Tab commits currently selected item.
        XCTAssertEqual(
            session.handleCommandSelector(#selector(NSResponder.insertNewline(_:))),
            .commit(SlashCommandEngine.builtInItems[0])
        )
        XCTAssertEqual(
            session.handleCommandSelector(#selector(NSResponder.insertTab(_:))),
            .commit(SlashCommandEngine.builtInItems[0])
        )

        // Pressing Esc dismisses and suppresses re-popping at the same `slashLocation`.
        XCTAssertEqual(session.handleCommandSelector(#selector(NSResponder.cancelOperation(_:))), .handled)
        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(session.dismissedSlashLocation, 0)

        session.update(text: "/h1", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertFalse(session.isPresented)

        // Typing `/` at a new location triggers again immediately.
        session.update(text: "/h1 /to", selectedRange: NSRange(location: 7, length: 0))
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.activeMatch?.slashLocation, 4)
        XCTAssertEqual(session.filteredItems.map(\.id), ["todo", "today"])

        // Dismiss at location 4, delete `/`, then re-type `/` at location 4 -> triggers again.
        session.dismiss()
        XCTAssertFalse(session.isPresented)
        session.update(text: "/h1 ", selectedRange: NSRange(location: 4, length: 0))
        XCTAssertNil(session.dismissedSlashLocation)
        session.update(text: "/h1 /", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertTrue(session.isPresented)

        // Typing `/Users` -> `/Users/a` automatically closes and stops matching.
        session.update(text: "/Users", selectedRange: NSRange(location: 6, length: 0))
        XCTAssertFalse(session.isPresented)
        session.update(text: "/Users/a", selectedRange: NSRange(location: 8, length: 0))
        XCTAssertNil(session.activeMatch)
        XCTAssertFalse(session.isPresented)
    }

    // MARK: - Placement & Boundary Clamping

    func testScreenMenuPlacementClampsAtScreenEdgesAndInstantiatesSessionView() {
        let screenVisibleFrame = CGRect(x: 20, y: 40, width: 1200, height: 800)

        // Left & bottom corner with tight downward space clamps X to minEdgeMargin and flips cleanly within visibleFrame.
        let bottomLeftCaret = CGRect(x: 5, y: 55, width: 4, height: 18)
        let clampedBottomLeft = SlashCommandEngine.screenMenuPlacement(
            caretScreenRect: bottomLeftCaret,
            screenVisibleFrame: screenVisibleFrame,
            itemCount: 12
        )
        XCTAssertTrue(clampedBottomLeft.isFlippedUpward)
        XCTAssertEqual(clampedBottomLeft.frame.minX, screenVisibleFrame.minX + SlashCommandEngine.screenEdgeMargin, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(clampedBottomLeft.frame.minY, screenVisibleFrame.minY + SlashCommandEngine.screenEdgeMargin)
        XCTAssertLessThanOrEqual(clampedBottomLeft.frame.maxY, screenVisibleFrame.maxY - SlashCommandEngine.screenEdgeMargin)

        // Right edge clamps maxX cleanly inside screenVisibleFrame.
        let topRightCaret = CGRect(x: 1180, y: 760, width: 4, height: 18)
        let clampedTopRight = SlashCommandEngine.screenMenuPlacement(
            caretScreenRect: topRightCaret,
            screenVisibleFrame: screenVisibleFrame,
            itemCount: 12
        )
        XCTAssertFalse(clampedTopRight.isFlippedUpward)
        XCTAssertEqual(clampedTopRight.frame.maxX, screenVisibleFrame.maxX - SlashCommandEngine.screenEdgeMargin, accuracy: 0.01)

        // Zero items yields zero-sized frame clamped within screenVisibleFrame.
        let emptyPlacement = SlashCommandEngine.screenMenuPlacement(
            caretScreenRect: topRightCaret,
            screenVisibleFrame: screenVisibleFrame,
            itemCount: 0
        )
        XCTAssertEqual(emptyPlacement.frame.size, .zero)
        XCTAssertGreaterThanOrEqual(emptyPlacement.frame.minX, screenVisibleFrame.minX + SlashCommandEngine.screenEdgeMargin)
        XCTAssertLessThanOrEqual(emptyPlacement.frame.maxX, screenVisibleFrame.maxX - SlashCommandEngine.screenEdgeMargin)

        // Menu view instantiates cleanly with session.
        let session = SlashCommandSession()
        session.update(text: "/", selectedRange: NSRange(location: 1, length: 0))
        let hostingView = NSHostingView(
            rootView: SlashCommandMenuView(session: session) { _ in }
        )
        XCTAssertNotNil(hostingView)
    }

    func testScreenMenuPlacementAlwaysOpensDownwardInNotchDrawerAndNeverCoversSlash() {
        let screenVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let caretsInTopAnchoredDrawer = [
            CGRect(x: 492, y: 800, width: 8, height: 18),  // top line of drawer
            CGRect(x: 540, y: 660, width: 8, height: 18),  // middle line (previously overlapped `/`)
            CGRect(x: 610, y: 515, width: 8, height: 18),  // bottom line (previously flipped upward)
            CGRect(x: 1360, y: 620, width: 8, height: 18)  // near right screen edge
        ]

        for caret in caretsInTopAnchoredDrawer {
            let placement = SlashCommandEngine.screenMenuPlacement(
                caretScreenRect: caret,
                screenVisibleFrame: screenVisibleFrame,
                itemCount: 12
            )
            XCTAssertFalse(placement.isFlippedUpward, "Should open downward for caret \(caret)")
            XCTAssertEqual(placement.frame.maxY, caret.minY - SlashCommandEngine.screenPopupGap, accuracy: 0.01)
            XCTAssertFalse(placement.frame.intersects(caret), "Popup must never cover caret \(caret)")
            XCTAssertGreaterThanOrEqual(placement.frame.minX, screenVisibleFrame.minX + SlashCommandEngine.screenEdgeMargin)
            XCTAssertLessThanOrEqual(placement.frame.maxX, screenVisibleFrame.maxX - SlashCommandEngine.screenEdgeMargin)
        }

        // Only when near the very bottom of the screen should it flip upward, still without covering `/`.
        let nearBottomScreenCaret = CGRect(x: 120, y: 60, width: 8, height: 18)
        let upwardPlacement = SlashCommandEngine.screenMenuPlacement(
            caretScreenRect: nearBottomScreenCaret,
            screenVisibleFrame: screenVisibleFrame,
            itemCount: 12
        )
        XCTAssertTrue(upwardPlacement.isFlippedUpward)
        XCTAssertEqual(upwardPlacement.frame.minY, nearBottomScreenCaret.maxY + SlashCommandEngine.screenPopupGap, accuracy: 0.01)
        XCTAssertFalse(upwardPlacement.frame.intersects(nearBottomScreenCaret))
    }

    func testEditorScreenRectAnchorsBelowSlashAcrossTopMiddleAndScrolledBottomLines() throws {
        var backingText = "/"
        let binding = Binding<String>(
            get: { backingText },
            set: { backingText = $0 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 492, width: 500, height: 283),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: NativeTextViewWrapper(
                text: binding,
                configuration: MarkdownEditorConfiguration(textInsets: TextInsets(horizontal: 12, vertical: 12)),
                fontName: "SF Pro",
                fontSize: 15
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 283)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findFirstTextView(in: hostingView))
        let interactionState = EditorInteractionState()
        interactionState.bind(containerView: hostingView, textView: textView)

        let screenVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 850)

        func measurePlacement(for sampleText: String) throws -> (slashRect: CGRect, placement: SlashMenuPlacement) {
            backingText = sampleText
            textView.string = sampleText
            let length = (sampleText as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
            textView.layoutSubtreeIfNeeded()
            if let textLayoutManager = textView.textLayoutManager {
                textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            }
            textView.scrollRangeToVisible(NSRange(location: length, length: 0))
            textView.layoutSubtreeIfNeeded()

            let match = try XCTUnwrap(
                SlashCommandEngine.detectTrigger(in: sampleText, selectedRange: NSRange(location: length, length: 0))
            )
            let slashRect = try XCTUnwrap(interactionState.screenRectForSlashTrigger(match))
            let placement = SlashCommandEngine.screenMenuPlacement(
                caretScreenRect: slashRect,
                screenVisibleFrame: screenVisibleFrame,
                itemCount: 12
            )
            return (slashRect, placement)
        }

        let top = try measurePlacement(for: "/")
        let middleText = Array(repeating: "line", count: 7).joined(separator: "\n") + "\n/todo"
        let middle = try measurePlacement(for: middleText)
        let scrolledBottomText = Array(repeating: "line", count: 23).joined(separator: "\n") + "\n/"
        let bottom = try measurePlacement(for: scrolledBottomText)

        XCTAssertGreaterThan(top.slashRect.minY, middle.slashRect.minY)

        for sample in [top, middle, bottom] {
            XCTAssertFalse(sample.placement.isFlippedUpward)
            XCTAssertLessThanOrEqual(
                sample.placement.frame.maxY,
                sample.slashRect.minY - SlashCommandEngine.screenPopupGap + 0.01
            )
            XCTAssertFalse(sample.placement.frame.intersects(sample.slashRect))
        }
    }

    private func findFirstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView {
            return tv
        }
        for subview in view.subviews {
            if let tv = findFirstTextView(in: subview) {
                return tv
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func detect(_ text: String) -> SlashTriggerMatch? {
        SlashCommandEngine.detectTrigger(
            in: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        )
    }

    private func applyCommand(_ id: String, to text: String) -> SlashCommandReplacement {
        let match = detect(text)!
        let item = SlashCommandEngine.builtInItems.first { $0.id == id }!
        return SlashCommandEngine.apply(item: item, match: match, in: text)
    }
}
