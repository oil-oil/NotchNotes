import AppKit
import MarkdownEngine
import SwiftUI

extension Notification.Name {
    static let notchNotesMarkdownShortcut = Notification.Name("NotchNotes.MarkdownShortcut")
}

enum MarkdownShortcutUserInfoKey {
    static let commandID = "commandID"
    static let headingLevel = "headingLevel"
}

enum MarkdownCommand: CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case quote
    case unorderedList
    case orderedList
    case todoList

    var id: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "inlineCode"
        case .link: return "link"
        case .quote: return "quote"
        case .unorderedList: return "unorderedList"
        case .orderedList: return "orderedList"
        case .todoList: return "todoList"
        }
    }

    init?(id: String) {
        guard let match = Self.allCases.first(where: { $0.id == id }) else {
            return nil
        }
        self = match
    }

    var help: String {
        help(for: .english)
    }

    func help(for language: AppLanguage) -> String {
        AppStrings(language: language).markdownCommandHelp(self)
    }
}

@MainActor
final class EditorInteractionState: ObservableObject {
    @Published private(set) var isDraggingSelection = false
    var onSelectionChange: ((NSRange) -> Void)?
    var onEditorSnapshotChange: (((text: String, selectedRange: NSRange, hasMarkedText: Bool)) -> Void)?
    var onViewportScroll: (() -> Void)?
    var onSlashSessionDidUpdate: (() -> Void)?
    var onEditorFocusLost: (() -> Void)?

    private weak var textView: NSTextView?
    private weak var observedSelectionTextView: NSTextView?
    private weak var observedClipView: NSClipView?
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var textChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var clipBoundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var shortcutObserver: NSObjectProtocol?
    private var didStartInEditor = false
    private var pendingFocus = false
    private var pendingSelectionRange: NSRange?
    private var isApplyingRestoredSelection = false
    private var focusAttemptsRemaining = 0
    private var layoutRefreshGeneration = 0
    private var selectionRestoreGeneration = 0

    init() {
        observeShortcutNotifications()
    }

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
    }

    func bind(containerView: NSView?, textView: NSTextView?) {
        if let textView {
            self.textView = textView
            observeEditorNotifications(in: textView)
            applyPendingSelectionRestore()
        }

        if pendingFocus {
            focusEditor()
        }
    }

    func requestFocus(searchingIn rootView: NSView?) {
        refreshTextView(searchingIn: rootView)
        pendingFocus = true
        focusAttemptsRemaining = 8

        retryFocus(searchingIn: rootView)
    }

    func resetSelectionToDocumentStart(searchingIn rootView: NSView? = nil) {
        restoreSelection(NSRange(location: 0, length: 0), searchingIn: rootView)
    }

    func restoreSelection(
        _ range: NSRange,
        searchingIn rootView: NSView? = nil,
        reveal: Bool = true
    ) {
        pendingSelectionRange = range
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }
        if let textView {
            observeEditorNotifications(in: textView)
        }

        selectionRestoreGeneration += 1
        let generation = selectionRestoreGeneration
        scheduleSelectionRestore(
            range: range,
            generation: generation,
            searchingIn: rootView,
            reveal: reveal
        )
    }

    func cancelPendingSelectionRestore() {
        pendingSelectionRange = nil
        selectionRestoreGeneration += 1
    }

    func requestLayoutRefresh(searchingIn rootView: NSView? = nil, resetScroll: Bool = false) {
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }

        layoutRefreshGeneration += 1
        let generation = layoutRefreshGeneration
        scheduleLayoutRefresh(generation: generation, searchingIn: rootView, resetScroll: resetScroll)
    }

    func currentSelectionRange() -> NSRange? {
        guard let textView else { return nil }
        return safeSelectedRange(in: textView)
    }

    func currentEditorSnapshot() -> (text: String, selectedRange: NSRange, hasMarkedText: Bool)? {
        guard let textView else { return nil }
        return (
            text: textView.string,
            selectedRange: safeSelectedRange(in: textView),
            hasMarkedText: textView.hasMarkedText()
        )
    }

    func focusCurrentEditor() {
        if textView != nil {
            focusEditor()
        } else {
            requestFocus(searchingIn: nil)
        }
    }

    func handleEditorDidResignFirstResponder() {
        onEditorFocusLost?()
    }

    func hasKeyboardFocus(requireActiveKeyWindow: Bool = false) -> Bool {
        guard let textView, let window = textView.window else { return false }
        if requireActiveKeyWindow {
            guard let app = NSApp, app.isActive, window.isKeyWindow else { return false }
        }
        return window.firstResponder === textView
    }

    func hasMarkedText() -> Bool {
        textView?.hasMarkedText() == true
    }

    @discardableResult
    func dismissFindBarIfVisible() -> Bool {
        guard let textView,
              let scrollView = textView.enclosingScrollView,
              scrollView.isFindBarVisible else {
            return false
        }
        let hideItem = NSMenuItem()
        hideItem.tag = NSTextFinder.Action.hideFindInterface.rawValue
        textView.performFindPanelAction(hideItem)
        if scrollView.isFindBarVisible {
            scrollView.isFindBarVisible = false
        }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    public func viewportRect(forCharacterRange range: NSRange) -> CGRect? {
        textView?.viewportRect(forCharacterRange: range)
    }

    func screenRectForSlashTrigger(_ match: SlashTriggerMatch) -> CGRect? {
        guard let textView else { return nil }
        let slashCharRange = NSRange(location: match.slashLocation, length: 1)
        guard let slashRect = resolvedScreenRect(
            in: textView,
            preferredRange: slashCharRange,
            match: match
        ) else {
            return nil
        }

        if match.triggerRange.length > 1 {
            let lastCharLocation = NSMaxRange(match.triggerRange) - 1
            if let caretEndRect = textView.screenRect(
                forCharacterRange: NSRange(location: lastCharLocation, length: 1)
            ), caretEndRect.height > 0 {
                let minY = min(slashRect.minY, caretEndRect.minY)
                let maxY = max(slashRect.maxY, caretEndRect.maxY)
                let maxX = max(slashRect.maxX, caretEndRect.maxX)
                return CGRect(
                    x: slashRect.minX,
                    y: minY,
                    width: max(maxX - slashRect.minX, slashRect.width),
                    height: max(maxY - minY, slashRect.height)
                )
            }
        }

        return slashRect
    }

    private func resolvedScreenRect(
        in textView: NSTextView,
        preferredRange: NSRange,
        match: SlashTriggerMatch
    ) -> CGRect? {
        let candidates = [
            preferredRange,
            match.triggerRange,
            NSRange(location: match.slashLocation, length: 0)
        ]
        for range in candidates {
            if let rect = textView.screenRect(forCharacterRange: range), rect.height > 0 {
                return rect
            }
        }
        return nil
    }

    @discardableResult
    func commitSlashCommand(
        _ item: SlashCommandItem,
        slashSession: SlashCommandSession,
        fallbackText: String
    ) -> Bool {
        let currentText = currentEditorSnapshot()?.text ?? fallbackText
        guard let replacement = slashSession.commit(item, in: currentText) else {
            return false
        }
        onSlashSessionDidUpdate?()
        focusCurrentEditor()
        replaceCharacters(
            in: replacement.replaceRange,
            with: replacement.replacementText,
            selectedRangeAfter: replacement.selectedRange
        )
        requestLayoutRefresh()
        return true
    }

    public func replaceCharacters(in range: NSRange, with replacement: String, selectedRangeAfter: NSRange) {
        guard let textView else { return }
        cancelPendingSelectionRestore()
        let safeRange = clampedRange(range, in: textView)
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: safeRange, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        let safeSelection = clampedRange(selectedRangeAfter, in: textView)
        textView.setSelectedRange(safeSelection)
    }

    func applyMarkdownCommand(_ command: MarkdownCommand) {
        guard let textView else { return }

        cancelPendingSelectionRestore()
        focusEditor()

        switch command {
        case .bold:
            toggleInlineWrap(.bold, in: textView)
        case .italic:
            toggleInlineWrap(.italic, in: textView)
        case .strikethrough:
            toggleInlineWrap(.strikethrough, in: textView)
        case .inlineCode:
            toggleInlineWrap(.inlineCode, in: textView)
        case .link:
            applyLink(in: textView)
        case .quote:
            toggleBlockPrefix(.quote, in: textView)
        case .unorderedList:
            toggleBlockPrefix(.unorderedList, in: textView)
        case .orderedList:
            toggleBlockPrefix(.orderedList, in: textView)
        case .todoList:
            toggleBlockPrefix(.todoList, in: textView)
        }

        requestLayoutRefresh()
    }

    func toggleHeading(level: Int) {
        guard let textView else { return }
        let clampedLevel = min(max(level, 1), 6)
        cancelPendingSelectionRestore()
        focusEditor()
        toggleBlockPrefix(.heading(clampedLevel), in: textView)
        requestLayoutRefresh()
    }

    func handleMouseEvent(_ event: NSEvent, searchingIn rootView: NSView?) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            refreshTextView(searchingIn: rootView)
            if let textView {
                observeEditorNotifications(in: textView)
            }
            didStartInEditor = contains(event)
            isDraggingSelection = false
            if didStartInEditor {
                cancelPendingSelectionRestore()
                if event.type == .leftMouseDown {
                    focusEditor()
                }
            }
        case .leftMouseDragged:
            noteMouseDragged()
        case .leftMouseUp:
            resetDragState()
        default:
            break
        }
    }

    func noteGlobalMouseDragged() {
        noteMouseDragged()
    }

    func noteGlobalMouseUp() {
        resetDragState()
    }

    private func noteMouseDragged() {
        guard didStartInEditor else { return }
        isDraggingSelection = true
    }

    private func focusEditor() {
        guard let textView else {
            return
        }

        pendingFocus = false
        focusAttemptsRemaining = 0
        if let window = textView.window {
            if window.isVisible {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            window.makeFirstResponder(textView)
        }
    }

    private func observeShortcutNotifications() {
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .notchNotesMarkdownShortcut,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let commandID = notification.userInfo?[MarkdownShortcutUserInfoKey.commandID] as? String
            let headingLevel = notification.userInfo?[MarkdownShortcutUserInfoKey.headingLevel] as? Int
            let targetTextViewID = (notification.object as? NSTextView).map(ObjectIdentifier.init)
            let targetWindowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            let dispatch: @MainActor () -> Void = {
                guard let self,
                      self.shouldHandleShortcut(
                          targetTextViewID: targetTextViewID,
                          targetWindowID: targetWindowID
                      ) else {
                    return
                }
                if let commandID, let command = MarkdownCommand(id: commandID) {
                    self.applyMarkdownCommand(command)
                } else if let headingLevel {
                    self.toggleHeading(level: headingLevel)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(dispatch)
            } else {
                Task { @MainActor in dispatch() }
            }
        }
    }

    private func shouldHandleShortcut(
        targetTextViewID: ObjectIdentifier?,
        targetWindowID: ObjectIdentifier?
    ) -> Bool {
        guard let textView else { return false }
        if let targetTextViewID {
            return ObjectIdentifier(textView) == targetTextViewID
        }
        if let targetWindowID {
            return textView.window.map(ObjectIdentifier.init) == targetWindowID
        }
        return hasKeyboardFocus()
    }

    private func observeEditorNotifications(in textView: NSTextView) {
        observeScrollClipView(for: textView)
        guard observedSelectionTextView !== textView else { return }

        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }

        observedSelectionTextView = textView
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            let handleSelection: @MainActor () -> Void = {
                guard let self else { return }
                if !self.isApplyingRestoredSelection,
                   let eventType = NSApp.currentEvent?.type,
                   eventType == .leftMouseDown
                    || eventType == .leftMouseDragged
                    || eventType == .leftMouseUp
                    || eventType == .keyDown {
                    self.cancelPendingSelectionRestore()
                }
                guard let range = self.currentSelectionRange() else { return }
                self.onSelectionChange?(range)
                if !self.isApplyingRestoredSelection,
                   let snapshot = self.currentEditorSnapshot() {
                    self.onEditorSnapshotChange?(snapshot)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handleSelection)
            } else {
                Task { @MainActor in handleSelection() }
            }
        }

        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            let handleChange: @MainActor () -> Void = {
                guard let self, !self.isApplyingRestoredSelection else { return }
                self.cancelPendingSelectionRestore()
                if let snapshot = self.currentEditorSnapshot() {
                    self.onEditorSnapshotChange?(snapshot)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handleChange)
            } else {
                Task { @MainActor in handleChange() }
            }
        }
    }

    private func observeScrollClipView(for textView: NSTextView) {
        guard let clipView = textView.enclosingScrollView?.contentView,
              observedClipView !== clipView else {
            return
        }
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            let handleScroll: @MainActor () -> Void = {
                self?.onViewportScroll?()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handleScroll)
            } else {
                Task { @MainActor in handleScroll() }
            }
        }
    }

    private func applyPendingSelectionRestore() {
        guard let pendingSelectionRange else { return }
        applySelection(pendingSelectionRange, reveal: false)
    }

    // MARK: - Inline Bidirectional Formatting

    private enum InlineWrapKind {
        case bold
        case italic
        case strikethrough
        case inlineCode

        var delimiterChar: unichar {
            switch self {
            case .bold, .italic: return 0x2A // '*'
            case .strikethrough: return 0x7E // '~'
            case .inlineCode: return 0x60    // '`'
            }
        }

        var delimiterLength: Int {
            switch self {
            case .bold, .strikethrough: return 2
            case .italic, .inlineCode: return 1
            }
        }

        var marker: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .strikethrough: return "~~"
            case .inlineCode: return "`"
            }
        }

        var placeholder: String {
            switch self {
            case .bold: return "bold"
            case .italic: return "italic"
            case .strikethrough: return "strikethrough"
            case .inlineCode: return "code"
            }
        }
    }

    private func toggleInlineWrap(_ kind: InlineWrapKind, in textView: NSTextView) {
        let nsString = textView.string as NSString
        let fullLength = nsString.length
        let range = safeSelectedRange(in: textView)
        let delim = kind.delimiterChar
        let delimLen = kind.delimiterLength
        let marker = kind.marker

        var outerLead = 0
        while range.location - 1 - outerLead >= 0,
              nsString.character(at: range.location - 1 - outerLead) == delim {
            outerLead += 1
        }

        let rangeEnd = NSMaxRange(range)
        var outerTrail = 0
        while rangeEnd + outerTrail < fullLength,
              nsString.character(at: rangeEnd + outerTrail) == delim {
            outerTrail += 1
        }

        var innerLead = 0
        var innerTrail = 0
        if range.length > 0 {
            var lead = 0
            while lead < range.length, nsString.character(at: range.location + lead) == delim {
                lead += 1
            }
            if lead == range.length {
                innerLead = range.length / 2
                innerTrail = range.length - innerLead
            } else {
                innerLead = lead
                var trail = 0
                while trail < range.length - innerLead,
                      nsString.character(at: rangeEnd - 1 - trail) == delim {
                    trail += 1
                }
                innerTrail = trail
            }
        }

        let coreStart = range.location + innerLead
        let coreEnd = rangeEnd - innerTrail
        let coreRange = NSRange(location: coreStart, length: max(0, coreEnd - coreStart))
        let coreText = nsString.substring(with: coreRange)
        let totalLead = outerLead + innerLead
        let totalTrail = outerTrail + innerTrail
        let paired = min(totalLead, totalTrail)

        if matchesActiveDelimiter(kind: kind, paired: paired, core: coreText) {
            let fullSpanStart = coreStart - totalLead
            let fullSpanEnd = coreEnd + totalTrail
            let fullSpanRange = NSRange(location: fullSpanStart, length: fullSpanEnd - fullSpanStart)
            let delimUnit = String(UnicodeScalar(delim)!)
            let remainingLeft = String(repeating: delimUnit, count: totalLead - delimLen)
            let remainingRight = String(repeating: delimUnit, count: totalTrail - delimLen)
            let replacement = remainingLeft + coreText + remainingRight
            let selectionAfter = NSRange(
                location: fullSpanStart + remainingLeft.utf16.count,
                length: coreRange.length
            )
            replaceText(in: textView, range: fullSpanRange, with: replacement, selectionAfter: selectionAfter)
            return
        }

        let selectedText = nsString.substring(with: range)
        let content = selectedText.isEmpty ? kind.placeholder : selectedText
        let replacement = marker + content + marker
        let selectionAfter = NSRange(
            location: range.location + marker.utf16.count,
            length: content.utf16.count
        )
        replaceText(in: textView, range: range, with: replacement, selectionAfter: selectionAfter)
    }

    private func matchesActiveDelimiter(kind: InlineWrapKind, paired: Int, core: String) -> Bool {
        guard !core.contains("\n") else { return false }
        switch kind {
        case .bold:
            guard paired >= 2 else { return false }
            return !containsDelimiterRun(in: core, char: 0x2A) { $0 >= 2 }
        case .italic:
            guard paired == 1 || paired >= 3 else { return false }
            return !containsDelimiterRun(in: core, char: 0x2A) { $0 == 1 || $0 >= 3 }
        case .strikethrough:
            guard paired >= 2 else { return false }
            return !core.contains("~~")
        case .inlineCode:
            guard paired >= 1 else { return false }
            return !core.contains("`")
        }
    }

    private func containsDelimiterRun(
        in text: String,
        char: unichar,
        matching predicate: (Int) -> Bool
    ) -> Bool {
        let ns = text as NSString
        let len = ns.length
        var i = 0
        while i < len {
            if ns.character(at: i) == char {
                var j = i + 1
                while j < len, ns.character(at: j) == char {
                    j += 1
                }
                if predicate(j - i) {
                    return true
                }
                i = j
            } else {
                i += 1
            }
        }
        return false
    }

    private func applyLink(in textView: NSTextView) {
        let nsString = textView.string as NSString
        let range = safeSelectedRange(in: textView)
        let selectedText = nsString.substring(with: range)

        // Unwrap when the selection itself is `[label](url)`
        if let linkRegex = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\([^)]*\)$"#),
           let match = linkRegex.firstMatch(
               in: selectedText,
               range: NSRange(location: 0, length: selectedText.utf16.count)
           ) {
            let label = (selectedText as NSString).substring(with: match.range(at: 1))
            let selection = NSRange(location: range.location, length: label.utf16.count)
            replaceText(in: textView, range: range, with: label, selectionAfter: selection)
            return
        }

        // Unwrap when the `url` inside `[label](url)` is currently selected
        if range.location >= 3, NSMaxRange(range) < nsString.length,
           nsString.substring(with: NSRange(location: range.location - 2, length: 2)) == "](",
           nsString.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == ")" {
            let lineRange = nsString.lineRange(for: range)
            let beforeURL = nsString.substring(
                with: NSRange(location: lineRange.location, length: range.location - 2 - lineRange.location)
            ) as NSString
            let openBracketOffset = beforeURL.range(of: "[", options: .backwards).location
            if openBracketOffset != NSNotFound {
                let openBracketDoc = lineRange.location + openBracketOffset
                let labelRange = NSRange(
                    location: openBracketDoc + 1,
                    length: (range.location - 2) - (openBracketDoc + 1)
                )
                let label = nsString.substring(with: labelRange)
                let fullLinkRange = NSRange(
                    location: openBracketDoc,
                    length: (NSMaxRange(range) + 1) - openBracketDoc
                )
                let selection = NSRange(location: openBracketDoc, length: label.utf16.count)
                replaceText(in: textView, range: fullLinkRange, with: label, selectionAfter: selection)
                return
            }
        }

        let label = selectedText.isEmpty ? "link text" : selectedText
        let replacement = "[\(label)](url)"
        let selection: NSRange

        if selectedText.isEmpty {
            selection = NSRange(location: range.location + 1, length: label.utf16.count)
        } else {
            selection = NSRange(location: range.location + label.utf16.count + 3, length: 3)
        }

        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    // MARK: - Block / List Prefix Bidirectional Formatting

    private enum BlockPrefixKind: Equatable {
        case quote
        case unorderedList
        case orderedList
        case todoList
        case heading(Int)
    }

    private struct ParsedLinePrefix {
        let indent: String
        let kind: BlockPrefixKind?
        let body: String
    }

    private static let todoPrefixRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:[-*•]|(?:\d+|a)\.)[ \t]+\[[ xX]\][ \t]*(.*)$"#
    )
    private static let unorderedPrefixRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)[-*•][ \t]+(.*)$"#
    )
    private static let orderedPrefixRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:\d+|a)\.[ \t]+(.*)$"#
    )
    private static let quotePrefixRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)>[ \t]?(.*)$"#
    )
    private static let headingPrefixRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6})[ \t]+(.*)$"#
    )
    private static let leadingIndentRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(.*)$"#
    )

    private func parseLinePrefix(_ line: String) -> ParsedLinePrefix {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let m = Self.todoPrefixRegex.firstMatch(in: line, range: full) {
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: .todoList,
                body: ns.substring(with: m.range(at: 2))
            )
        }
        if let m = Self.unorderedPrefixRegex.firstMatch(in: line, range: full) {
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: .unorderedList,
                body: ns.substring(with: m.range(at: 2))
            )
        }
        if let m = Self.orderedPrefixRegex.firstMatch(in: line, range: full) {
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: .orderedList,
                body: ns.substring(with: m.range(at: 2))
            )
        }
        if let m = Self.quotePrefixRegex.firstMatch(in: line, range: full) {
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: .quote,
                body: ns.substring(with: m.range(at: 2))
            )
        }
        if let m = Self.headingPrefixRegex.firstMatch(in: line, range: full) {
            let level = m.range(at: 2).length
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: .heading(level),
                body: ns.substring(with: m.range(at: 3))
            )
        }
        if let m = Self.leadingIndentRegex.firstMatch(in: line, range: full) {
            return ParsedLinePrefix(
                indent: ns.substring(with: m.range(at: 1)),
                kind: nil,
                body: ns.substring(with: m.range(at: 2))
            )
        }
        return ParsedLinePrefix(indent: "", kind: nil, body: line)
    }

    private func prefixString(for kind: BlockPrefixKind, orderedIndex: Int) -> String {
        switch kind {
        case .quote:
            return "> "
        case .unorderedList:
            return "- "
        case .orderedList:
            return "\(orderedIndex + 1). "
        case .todoList:
            return "- [ ] "
        case .heading(let level):
            return String(repeating: "#", count: level) + " "
        }
    }

    private func toggleBlockPrefix(_ targetKind: BlockPrefixKind, in textView: NSTextView) {
        let nsString = textView.string as NSString
        let selectedRange = safeSelectedRange(in: textView)
        let lineRange = nsString.lineRange(for: selectedRange)
        let original = nsString.substring(with: lineRange)

        let trailingNewline: String
        let bodyWithoutTrailingNewline: String
        if original.hasSuffix("\r\n") {
            trailingNewline = "\r\n"
            bodyWithoutTrailingNewline = String(original.dropLast())
        } else if original.hasSuffix("\n") {
            trailingNewline = "\n"
            bodyWithoutTrailingNewline = String(original.dropLast())
        } else if original.hasSuffix("\r") {
            trailingNewline = "\r"
            bodyWithoutTrailingNewline = String(original.dropLast())
        } else {
            trailingNewline = ""
            bodyWithoutTrailingNewline = original
        }

        let rawLines = bodyWithoutTrailingNewline.isEmpty
            ? [""]
            : bodyWithoutTrailingNewline.components(separatedBy: "\n")
        let lines: [(content: String, carriageReturn: String)] = rawLines.map { raw in
            if raw.hasSuffix("\r") {
                return (String(raw.dropLast()), "\r")
            }
            return (raw, "")
        }

        let parsedLines = lines.map { parseLinePrefix($0.content) }
        let nonEmptyIndices = lines.indices.filter {
            !lines[$0].content.trimmingCharacters(in: .whitespaces).isEmpty
        }

        let shouldRemove = !nonEmptyIndices.isEmpty
            && nonEmptyIndices.allSatisfy { parsedLines[$0].kind == targetKind }

        var orderedCounter = 0
        let transformedContents: [String] = lines.indices.map { index in
            let line = lines[index]
            let parsed = parsedLines[index]
            let isLineEmpty = line.content.trimmingCharacters(in: .whitespaces).isEmpty

            if isLineEmpty && !nonEmptyIndices.isEmpty {
                return line.content
            }

            if shouldRemove {
                return parsed.indent + parsed.body
            }

            let newPrefix = prefixString(for: targetKind, orderedIndex: orderedCounter)
            orderedCounter += 1
            return parsed.indent + newPrefix + parsed.body
        }

        let transformedLines = lines.indices.map { index in
            transformedContents[index] + lines[index].carriageReturn
        }
        let replacementBody = transformedLines.joined(separator: "\n")
        let replacement = replacementBody + trailingNewline

        let selectionAfter: NSRange
        if selectedRange.length == 0, lines.count == 1 {
            let offsetInLine = selectedRange.location - lineRange.location
            let delta = transformedContents[0].utf16.count - lines[0].content.utf16.count
            let newOffset = min(max(offsetInLine + delta, 0), transformedContents[0].utf16.count)
            selectionAfter = NSRange(location: lineRange.location + newOffset, length: 0)
        } else {
            selectionAfter = NSRange(location: lineRange.location, length: replacementBody.utf16.count)
        }

        replaceText(in: textView, range: lineRange, with: replacement, selectionAfter: selectionAfter)
    }

    private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String, selectionAfter: NSRange) {
        let safeRange = clampedRange(range, in: textView)
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: safeRange, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(clampedRange(selectionAfter, in: textView))
    }

    private func safeSelectedRange(in textView: NSTextView) -> NSRange {
        let fullLength = (textView.string as NSString).length
        let selectedRange = textView.selectedRange()
        let location = min(max(selectedRange.location, 0), fullLength)
        let length = min(max(selectedRange.length, 0), fullLength - location)
        return NSRange(location: location, length: length)
    }

    // MARK: - Selection Restore & Layout Refresh

    private func scheduleSelectionRestore(
        range: NSRange,
        generation: Int,
        searchingIn rootView: NSView?,
        reveal: Bool
    ) {
        if textView != nil {
            applySelection(range, reveal: reveal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak rootView] in
            guard let self,
                  self.selectionRestoreGeneration == generation,
                  let targetRange = self.pendingSelectionRange else {
                return
            }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
                if let textView = self.textView {
                    self.observeEditorNotifications(in: textView)
                }
            }
            self.applySelection(targetRange, reveal: reveal)
            self.pendingSelectionRange = nil
        }
    }

    private func applySelection(_ range: NSRange, reveal: Bool) {
        guard let textView else { return }
        let safeRange = clampedRange(range, in: textView)
        let preservedScrollOrigin = reveal
            ? nil
            : textView.enclosingScrollView?.contentView.bounds.origin
        isApplyingRestoredSelection = true
        defer { isApplyingRestoredSelection = false }
        textView.setSelectedRange(safeRange)
        if reveal {
            textView.scrollRangeToVisible(safeRange)
        } else if let scrollView = textView.enclosingScrollView,
                  let preservedScrollOrigin {
            scrollView.contentView.scroll(to: preservedScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func clampedRange(_ range: NSRange, in textView: NSTextView) -> NSRange {
        let fullLength = (textView.string as NSString).length
        let location = min(max(range.location, 0), fullLength)
        let length = min(max(range.length, 0), fullLength - location)
        return NSRange(location: location, length: length)
    }

    private func scheduleLayoutRefresh(
        generation: Int,
        searchingIn rootView: NSView?,
        resetScroll: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak rootView] in
            guard let self, self.layoutRefreshGeneration == generation else { return }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
            }
            self.applyLayoutRefresh(resetScroll: resetScroll)
        }
    }

    private func applyLayoutRefresh(resetScroll: Bool) {
        guard let textView else { return }

        textView.layoutSubtreeIfNeeded()

        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.textViewportLayoutController.layoutViewport()
            let documentEnd = textLayoutManager.documentRange.endLocation
            textLayoutManager.ensureLayout(for: NSTextRange(location: documentEnd))
        }

        if let scrollView = textView.enclosingScrollView {
            if resetScroll {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.needsDisplay = true
        }

        textView.needsDisplay = true
        textView.setNeedsDisplay(textView.visibleRect)
        textView.window?.displayIfNeeded()
    }

    private func retryFocus(searchingIn rootView: NSView?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak rootView] in
            guard let self, self.pendingFocus else { return }
            self.refreshTextView(searchingIn: rootView)

            if self.textView != nil {
                self.focusEditor()
                return
            }

            self.focusAttemptsRemaining -= 1
            guard self.focusAttemptsRemaining > 0 else {
                self.pendingFocus = false
                return
            }

            self.retryFocus(searchingIn: rootView)
        }
    }

    private func refreshTextView(searchingIn rootView: NSView?) {
        guard let rootView,
              let freshTextView = rootView.firstDescendant(ofType: NSTextView.self) else {
            return
        }

        textView = freshTextView
    }

    private func resetDragState() {
        didStartInEditor = false
        isDraggingSelection = false
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let textView,
              let window = textView.window,
              event.window === window else {
            return false
        }

        let location = textView.convert(event.locationInWindow, from: nil)
        return textView.bounds.contains(location)
    }

}

struct EditorFocusBinder: NSViewRepresentable {
    let state: EditorInteractionState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        bind(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        bind(from: view)
    }

    private func bind(from view: NSView) {
        DispatchQueue.main.async {
            let container = view.superview
            let textView = container?.firstDescendant(ofType: NSTextView.self)
                ?? view.firstAncestorDescendant(ofType: NSTextView.self)
            state.bind(containerView: container, textView: textView)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func firstAncestorDescendant<T: NSView>(ofType type: T.Type) -> T? {
        var current: NSView? = self

        while let view = current {
            if let match = view.firstDescendant(ofType: type) {
                return match
            }
            current = view.superview
        }

        return nil
    }
}
