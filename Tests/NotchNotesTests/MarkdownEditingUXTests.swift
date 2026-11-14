import AppKit
@testable import MarkdownEngine
import SwiftUI
import XCTest
@testable import NotchNotes

@MainActor
final class MarkdownEditingUXTests: XCTestCase {

    // MARK: - 1. Standard Markdown List Raw Text & Continuation

    func testTypingListPrefixesPreservesStandardMarkdownRawText() {
        let dashEditor = makeCoordinatorEditor("")
        typeString("- item", in: dashEditor.textView, coordinator: dashEditor.coordinator)
        XCTAssertEqual(dashEditor.textView.string, "- item")

        let asteriskEditor = makeCoordinatorEditor("")
        typeString("* item", in: asteriskEditor.textView, coordinator: asteriskEditor.coordinator)
        XCTAssertEqual(asteriskEditor.textView.string, "* item")

        let orderedEditor = makeCoordinatorEditor("")
        typeString("1. item", in: orderedEditor.textView, coordinator: orderedEditor.coordinator)
        XCTAssertEqual(orderedEditor.textView.string, "1. item")
    }

    func testEnterContinuesListsAndExitsEmptyListItemsCleanly() {
        let (dashTV, dashCoord) = makeCoordinatorEditor("- first")
        typeCharacter("\n", in: dashTV, coordinator: dashCoord)
        XCTAssertEqual(dashTV.string, "- first\n- ")
        typeCharacter("\n", in: dashTV, coordinator: dashCoord)
        XCTAssertEqual(dashTV.string, "- first\n")

        let (starTV, starCoord) = makeCoordinatorEditor("* first")
        typeCharacter("\n", in: starTV, coordinator: starCoord)
        XCTAssertEqual(starTV.string, "* first\n* ")
        typeCharacter("\n", in: starTV, coordinator: starCoord)
        XCTAssertEqual(starTV.string, "* first\n")

        let (numTV, numCoord) = makeCoordinatorEditor("1. first")
        typeCharacter("\n", in: numTV, coordinator: numCoord)
        XCTAssertEqual(numTV.string, "1. first\n2. ")
        typeCharacter("\n", in: numTV, coordinator: numCoord)
        XCTAssertEqual(numTV.string, "1. first\n")

        let (todoTV, todoCoord) = makeCoordinatorEditor("- [x] done")
        typeCharacter("\n", in: todoTV, coordinator: todoCoord)
        XCTAssertEqual(todoTV.string, "- [x] done\n- [ ] ")
        typeCharacter("\n", in: todoTV, coordinator: todoCoord)
        XCTAssertEqual(todoTV.string, "- [x] done\n")
    }

    func testAsteriskListSupportsIndentationAndParagraphHangingIndent() {
        let (scrollView, textView, coordinator) = makeWrappedEditor("- dash\n* star\n1. one")
        _ = scrollView

        for marker in ["- dash", "* star", "1. one"] {
            let loc = (textView.string as NSString).range(of: marker).location
            let para = textView.textStorage?.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertNotNil(para, marker)
            XCTAssertGreaterThan(para?.headIndent ?? 0, 0, marker)
        }

        let (starTV, starCoord) = makeCoordinatorEditor("* item")
        XCTAssertFalse(starCoord.textView(starTV, shouldChangeTextIn: starTV.selectedRange(), replacementString: "\t"))
        XCTAssertEqual(starTV.string, "\t* item")
        XCTAssertTrue(starCoord.textView(starTV, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(starTV.string, "* item")
        _ = coordinator
    }

    // MARK: - 2. Disabling Intrusive Auto-Replacements

    func testAutoClosePairsDisabledByDefaultAndOptInStillWorks() {
        XCTAssertFalse(ListStyle.default.autoClosePairsEnabled)

        let (tv, coord) = makeCoordinatorEditor("")
        typeString("(a) [b] {c} [[wiki", in: tv, coordinator: coord)
        XCTAssertEqual(tv.string, "(a) [b] {c} [[wiki")

        let optInConfig = MarkdownEditorConfiguration(
            lists: ListStyle(autoClosePairsEnabled: true)
        )
        let (_, optInTV, optInCoord) = makeWrappedEditor("", configuration: optInConfig)
        typeCharacter("(", in: optInTV, coordinator: optInCoord)
        XCTAssertEqual(optInTV.string, "()")
    }

    func testArrowAndHorizontalRuleAreNotExpandedOrMutated() {
        let (arrowTV, arrowCoord) = makeCoordinatorEditor("")
        typeString("a -> b", in: arrowTV, coordinator: arrowCoord)
        XCTAssertEqual(arrowTV.string, "a -> b")

        let (_, hrTV, hrCoord) = makeWrappedEditor("")
        typeString("---\nnext", in: hrTV, coordinator: hrCoord)
        XCTAssertEqual(hrTV.string, "---\nnext")

        let strikeStyle = hrTV.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(strikeStyle, NSUnderlineStyle.thick.rawValue)
    }

    // MARK: - 3. System Autocorrect & Smart Quotes Disabled

    func testSystemAutocorrectAndQuoteSubstitutionRemainDisabled() throws {
        let hostingView = NSHostingView(
            rootView: NativeTextViewWrapper(text: .constant("echo \"hello\" `code`"))
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findFirstTextView(in: hostingView))
        let coordinator = try XCTUnwrap(textView.delegate as? NativeTextViewCoordinator)

        let assertAllDisabled = {
            XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
            XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
            XCTAssertFalse(textView.isGrammarCheckingEnabled)
            XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
            XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        }

        assertAllDisabled()

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        assertAllDisabled()

        typeCharacter("!", in: textView, coordinator: coordinator)
        assertAllDisabled()
    }

    // MARK: - 4. Blockquote Rendering & Continuation

    func testBlockquoteStylingAppliesMutedMarkerSoftForegroundAndIndentOutsideCodeBlocks() {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: NSColor(white: 0.58, alpha: 1)
        )
        let config = MarkdownEditorConfiguration(theme: theme)
        let doc = "> quoted wisdom\n```\n> literal in code\n```"
        let (_, textView, _) = makeWrappedEditor(doc, configuration: config)

        let markerColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bodyColor = textView.textStorage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        let quotePara = textView.textStorage?.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(markerColor, theme.mutedText)
        XCTAssertNotEqual(bodyColor, theme.bodyText)
        XCTAssertEqual(bodyColor?.alphaComponent ?? 1, 0.78, accuracy: 0.01)
        XCTAssertGreaterThan(quotePara?.firstLineHeadIndent ?? 0, 0)
        XCTAssertGreaterThan(quotePara?.headIndent ?? 0, quotePara?.firstLineHeadIndent ?? 0)

        let codeQuoteLoc = (doc as NSString).range(of: "> literal").location
        let codePara = textView.textStorage?.attribute(.paragraphStyle, at: codeQuoteLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(codePara?.firstLineHeadIndent, config.codeBlock.horizontalIndent)
        XCTAssertEqual(codePara?.headIndent, config.codeBlock.horizontalIndent)
    }

    func testBlockquoteEnterContinuesAndEmptyQuoteLineExits() {
        let (tv, coord) = makeCoordinatorEditor("> first line")
        typeCharacter("\n", in: tv, coordinator: coord)
        XCTAssertEqual(tv.string, "> first line\n> ")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 15, length: 0))

        typeCharacter("\n", in: tv, coordinator: coord)
        XCTAssertEqual(tv.string, "> first line\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 13, length: 0))
    }

    // MARK: - 5. Bidirectional Formatting Toggle & Shortcuts

    func testInlineCommandsToggleBidirectionallyAndDistinguishBoldFromItalic() {
        let (_, textView, _) = makeWrappedEditor("hello")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: textView)

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        state.applyMarkdownCommand(.bold)
        XCTAssertEqual(textView.string, "**hello**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 5))

        // Triggering italic on **hello** must wrap into ***hello***, NOT strip ** to *!
        state.applyMarkdownCommand(.italic)
        XCTAssertEqual(textView.string, "***hello***")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 5))

        // Triggering italic again strips only the italic layer -> **hello**
        state.applyMarkdownCommand(.italic)
        XCTAssertEqual(textView.string, "**hello**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 5))

        // Triggering bold strips ** -> hello
        state.applyMarkdownCommand(.bold)
        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))

        // Selecting full **hello** including markers also unwraps cleanly
        state.applyMarkdownCommand(.bold)
        textView.setSelectedRange(NSRange(location: 0, length: 9))
        state.applyMarkdownCommand(.bold)
        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))

        // Strikethrough & inline code & link toggle
        state.applyMarkdownCommand(.strikethrough)
        XCTAssertEqual(textView.string, "~~hello~~")
        state.applyMarkdownCommand(.strikethrough)
        XCTAssertEqual(textView.string, "hello")

        state.applyMarkdownCommand(.inlineCode)
        XCTAssertEqual(textView.string, "`hello`")
        state.applyMarkdownCommand(.inlineCode)
        XCTAssertEqual(textView.string, "hello")

        state.applyMarkdownCommand(.link)
        XCTAssertEqual(textView.string, "[hello](url)")
        state.applyMarkdownCommand(.link)
        XCTAssertEqual(textView.string, "hello")
    }

    func testBlockPrefixCommandsToggleAndConvertBetweenListKindsWithoutStacking() {
        let (_, textView, _) = makeWrappedEditor("alpha\nbeta")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: textView)

        textView.setSelectedRange(NSRange(location: 0, length: 10))
        state.applyMarkdownCommand(.unorderedList)
        XCTAssertEqual(textView.string, "- alpha\n- beta")

        // Convert unordered -> todo (replaces `- ` instead of stacking `- [ ] - `)
        state.applyMarkdownCommand(.todoList)
        XCTAssertEqual(textView.string, "- [ ] alpha\n- [ ] beta")

        // Convert todo -> ordered
        state.applyMarkdownCommand(.orderedList)
        XCTAssertEqual(textView.string, "1. alpha\n2. beta")

        // Toggle ordered off
        state.applyMarkdownCommand(.orderedList)
        XCTAssertEqual(textView.string, "alpha\nbeta")

        // Quote toggle
        state.applyMarkdownCommand(.quote)
        XCTAssertEqual(textView.string, "> alpha\n> beta")
        state.applyMarkdownCommand(.quote)
        XCTAssertEqual(textView.string, "alpha\nbeta")

        // Mixed checked/unchecked todo toggle off
        textView.string = "- [ ] one\n- [x] two"
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        state.applyMarkdownCommand(.todoList)
        XCTAssertEqual(textView.string, "one\ntwo")

        // Heading toggle & level switch
        textView.string = "Heading"
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        state.toggleHeading(level: 1)
        XCTAssertEqual(textView.string, "# Heading")
        state.toggleHeading(level: 2)
        XCTAssertEqual(textView.string, "## Heading")
        state.toggleHeading(level: 2)
        XCTAssertEqual(textView.string, "Heading")
    }

    func testEditMenuProvidesStandardFormatShortcutsAndRoutesViaNotification() {
        let appDelegate = AppDelegate()
        let editMenu = appDelegate.makeEditMenu()

        let expectedShortcuts: [(String, NSEvent.ModifierFlags)] = [
            ("b", [.command]),
            ("i", [.command]),
            ("e", [.command]),
            ("k", [.command]),
            ("x", [.command, .shift]),
            ("l", [.command, .shift]),
            ("u", [.command, .shift]),
            ("o", [.command, .shift]),
            ("'", [.command, .shift])
        ]

        for (key, mask) in expectedShortcuts {
            let match = editMenu.items.first {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mask
            }
            XCTAssertNotNil(match, "Missing shortcut \(key) with mask \(mask)")
        }

        let headingSubmenu = editMenu.items.first(where: { $0.title == "Heading" })?.submenu
        XCTAssertEqual(headingSubmenu?.items.count, 3)

        // Verify routing to focused editor in an offscreen unshown window
        let (_, textView, _) = makeWrappedEditor("shortcut")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))

        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 8))

        NotificationCenter.default.post(
            name: .notchNotesMarkdownShortcut,
            object: textView,
            userInfo: [MarkdownShortcutUserInfoKey.commandID: MarkdownCommand.bold.id]
        )
        XCTAssertEqual(textView.string, "**shortcut**")
    }

    // MARK: - 6. Selection Restore Cancellation & Slash Menu Hooks

    func testUserTypingCancelsPendingSelectionRestore() async throws {
        let (_, textView, coordinator) = makeWrappedEditor("hello world")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: textView)

        state.restoreSelection(NSRange(location: 0, length: 0), reveal: false)

        // User immediately moves to end and types before the async restore pass fires
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        typeCharacter("!", in: textView, coordinator: coordinator)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 12, length: 0))

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 12, length: 0))
    }

    func testMouseDownInEditorCancelsPendingSelectionRestore() async throws {
        let (scrollView, textView, _) = makeWrappedEditor("hello world")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        let state = EditorInteractionState()
        state.bind(containerView: scrollView, textView: textView)

        state.restoreSelection(NSRange(location: 0, length: 0), reveal: false)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        if let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) {
            state.handleMouseEvent(mouseDown, searchingIn: scrollView)
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testOnCommandSelectorInterceptsCommandsBeforeDefaultHandling() {
        var intercepted: [Selector] = []
        var shouldConsume = true

        let wrapper = NativeTextViewWrapper(
            text: .constant("- item"),
            onCommandSelector: { selector in
                intercepted.append(selector)
                return shouldConsume
            }
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textView.string = "\t- item"
        textView.delegate = coordinator

        let selectors: [Selector] = [
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.cancelOperation(_:)),
            #selector(NSResponder.insertBacktab(_:))
        ]

        for selector in selectors {
            XCTAssertTrue(coordinator.textView(textView, doCommandBy: selector))
        }
        XCTAssertEqual(intercepted.count, selectors.count)
        // Because insertBacktab: was intercepted and consumed, `\t- item` stayed untouched
        XCTAssertEqual(textView.string, "\t- item")

        shouldConsume = false
        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(textView.string, "- item")
    }

    func testViewportRectAndAtomicReplaceCharactersPreserveUndo() {
        let (_, textView, _) = makeWrappedEditor("/h1")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: textView)

        let slashRect = state.viewportRect(forCharacterRange: NSRange(location: 0, length: 3))
        let caretRect = textView.viewportRect(forCharacterRange: NSRange(location: 3, length: 0))
        let invalidRect = state.viewportRect(forCharacterRange: NSRange(location: 99, length: 1))

        XCTAssertNotNil(slashRect)
        XCTAssertGreaterThan(slashRect?.height ?? 0, 0)
        XCTAssertNotNil(caretRect)
        XCTAssertGreaterThan(caretRect?.height ?? 0, 0)
        XCTAssertNil(invalidRect)

        state.replaceCharacters(
            in: NSRange(location: 0, length: 3),
            with: "# ",
            selectedRangeAfter: NSRange(location: 2, length: 0)
        )
        XCTAssertEqual(textView.string, "# ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "/h1")
    }

    // MARK: - 7. Atomic Block Prefix Backspace & Task Checkbox UX

    func testBackspaceDeletesWholeTodoListAndBlockPrefixesInsteadOfExposingRawSyntax() {
        // 1. Empty todo `- [ ] |` -> `""` in one Backspace, with Undo support
        let (_, todoTV, todoCoord) = makeWrappedEditor("- [ ] ")
        XCTAssertTrue(todoCoord.textView(todoTV, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(todoTV.string, "")
        XCTAssertEqual(todoTV.selectedRange(), NSRange(location: 0, length: 0))
        todoTV.undoManager?.undo()
        XCTAssertEqual(todoTV.string, "- [ ] ")

        // 2. Todo with content `- [x] |buy milk` -> `|buy milk` in one Backspace
        let (_, checkedTV, checkedCoord) = makeWrappedEditor("- [x] buy milk")
        checkedTV.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(checkedCoord.textView(checkedTV, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(checkedTV.string, "buy milk")
        XCTAssertEqual(checkedTV.selectedRange(), NSRange(location: 0, length: 0))

        // 3. Indented empty todo `\t- [ ] |` clears whole line; indented non-empty `\t- [ ] |item` keeps `\t`
        let (_, indEmptyTV, indEmptyCoord) = makeWrappedEditor("\t- [ ] ")
        XCTAssertTrue(indEmptyCoord.textView(indEmptyTV, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(indEmptyTV.string, "")

        let (_, indTextTV, indTextCoord) = makeWrappedEditor("\t- [ ] item")
        indTextTV.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(indTextCoord.textView(indTextTV, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(indTextTV.string, "\titem")
        XCTAssertEqual(indTextTV.selectedRange(), NSRange(location: 1, length: 0))

        // 4. Bullet, ordered, blockquote, heading, and horizontal rule prefixes delete atomically
        let prefixCases: [(initial: String, caret: Int, expected: String)] = [
            ("- ", 2, ""),
            ("- item", 2, "item"),
            ("* item", 2, "item"),
            ("1. ", 3, ""),
            ("12. item", 4, "item"),
            ("> ", 2, ""),
            ("> quote", 2, "quote"),
            ("### ", 4, ""),
            ("### Title", 4, "Title"),
            ("---", 3, "")
        ]
        for testCase in prefixCases {
            let (_, tv, coord) = makeWrappedEditor(testCase.initial)
            tv.setSelectedRange(NSRange(location: testCase.caret, length: 0))
            XCTAssertTrue(
                coord.textView(tv, doCommandBy: #selector(NSResponder.deleteBackward(_:))),
                "Expected atomic backspace for \(testCase.initial.debugDescription)"
            )
            XCTAssertEqual(tv.string, testCase.expected, "Failed for \(testCase.initial.debugDescription)")
        }

        // 5. Inside fenced code blocks, Backspace must NOT eat `- ` or `# `
        let codeDoc = "```\n- [ ] literal\n```"
        let (_, codeTV, codeCoord) = makeWrappedEditor(codeDoc)
        codeTV.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertFalse(codeCoord.textView(codeTV, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    }

    func testTabPrefixedATaskListContinuesOnEnterAndCRLFBlockPrefixTogglesCleanly() {
        let (_, tv, coord) = makeWrappedEditor("\ta. [ ] first")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        typeCharacter("\n", in: tv, coordinator: coord)
        XCTAssertEqual(tv.string, "\ta. [ ] first\n\ta. [ ] ")

        // CRLF lines should strip/toggle block prefixes cleanly across `a. [ ] ` and preserve `\r\n`.
        let crlfTV = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        crlfTV.string = "\ta. [ ] one\r\n\t- [x] two\r\n"
        let interaction = EditorInteractionState()
        interaction.bind(containerView: nil, textView: crlfTV)
        crlfTV.setSelectedRange(NSRange(location: 0, length: (crlfTV.string as NSString).length))
        interaction.applyMarkdownCommand(.todoList)
        XCTAssertEqual(crlfTV.string, "\tone\r\n\ttwo\r\n")
    }

    func testTaskCheckboxRemainsRenderedNearCaretAndArrowsJumpAcrossHiddenPrefix() {
        let (_, textView, coordinator) = makeWrappedEditor("- [ ] task")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)

        // Checkbox attribute stays attached even when caret is adjacent or at line start
        XCTAssertEqual(textView.textStorage?.attribute(.taskCheckbox, at: 2, effectiveRange: nil) as? Bool, false)

        // Left arrow jumps across `- [ ] ` from 6 -> 0 in one step, and checkbox remains rendered
        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        XCTAssertEqual(textView.textStorage?.attribute(.taskCheckbox, at: 2, effectiveRange: nil) as? Bool, false)

        // Right arrow jumps back from 0 -> 6 in one step
        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    // MARK: - Helpers

    private func makeCoordinatorEditor(_ text: String) -> (textView: NSTextView, coordinator: NativeTextViewCoordinator) {
        let wrapper = NativeTextViewWrapper(text: .constant(text))
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        textView.allowsUndo = true
        textView.string = text
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (textView, coordinator)
    }

    private func makeWrappedEditor(
        _ initialText: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> (scrollView: NSScrollView, textView: NSTextView, coordinator: NativeTextViewCoordinator) {
        var backingText = initialText
        let binding = Binding<String>(
            get: { backingText },
            set: { backingText = $0 }
        )
        let wrapper = NativeTextViewWrapper(
            text: binding,
            configuration: configuration
        )
        let coordinator = wrapper.makeCoordinator()
        let scrollView = ClampedScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        textView.configuration = configuration
        textView.allowsUndo = true
        textView.delegate = coordinator
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.configuration = configuration
        coordinator.rebuildTextStorageAndStyle(textView, from: initialText, invalidateLayout: true)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return (scrollView, textView, coordinator)
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

    private func typeString(_ string: String, in textView: NSTextView, coordinator: NativeTextViewCoordinator) {
        for char in string {
            typeCharacter(String(char), in: textView, coordinator: coordinator)
        }
    }

    private func typeCharacter(_ char: String, in textView: NSTextView, coordinator: NativeTextViewCoordinator) {
        let range = textView.selectedRange()
        if coordinator.textView(textView, shouldChangeTextIn: range, replacementString: char) {
            guard textView.shouldChangeText(in: range, replacementString: char) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: char)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + char.utf16.count, length: 0))
        }
    }
}
