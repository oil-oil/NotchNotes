import AppKit
import Foundation
import SwiftUI

struct SlashCommandItem: Identifiable, Equatable, Sendable {
    enum InsertionBehavior: Equatable, Sendable {
        case text(String)
        case codeBlock
        case today
        case now
        case link
    }

    let id: String
    let title: String
    let subtitle: String
    let iconName: String
    let syntaxHint: String
    let keywords: [String]
    let isBlockLevel: Bool
    let insertion: InsertionBehavior
}

struct SlashTriggerMatch: Equatable, Sendable {
    let slashLocation: Int
    let triggerRange: NSRange
    let query: String
    let lineStartLocation: Int
}

struct SlashCommandReplacement: Equatable, Sendable {
    let replaceRange: NSRange
    let replacementText: String
    let selectedRange: NSRange
    let updatedText: String
}

enum SlashKeyAction: Equatable, Sendable {
    case ignored
    case handled
    case commit(SlashCommandItem)
}

struct SlashMenuPlacement: Equatable, Sendable {
    let frame: CGRect
    let isFlippedUpward: Bool

    var origin: CGPoint { frame.origin }
    var size: CGSize { frame.size }
}

enum SlashCommandEngine {
    static let maxQueryLength = 24
    static let menuWidth: CGFloat = 228
    static let rowHeight: CGFloat = 30
    static let menuPadding: CGFloat = 8
    static let maxMenuHeight: CGFloat = 184
    static let caretVerticalGap: CGFloat = 4
    static let screenPopupGap: CGFloat = 6
    static let screenEdgeMargin: CGFloat = 8

    static let builtInItems: [SlashCommandItem] = [
        SlashCommandItem(
            id: "h1",
            title: "Heading 1",
            subtitle: "一级标题",
            iconName: "textformat.size.larger",
            syntaxHint: "#",
            keywords: ["1", "#", "header", "标题", "一级"],
            isBlockLevel: true,
            insertion: .text("# ")
        ),
        SlashCommandItem(
            id: "h2",
            title: "Heading 2",
            subtitle: "二级标题",
            iconName: "textformat.size",
            syntaxHint: "##",
            keywords: ["2", "##", "header", "标题", "二级"],
            isBlockLevel: true,
            insertion: .text("## ")
        ),
        SlashCommandItem(
            id: "h3",
            title: "Heading 3",
            subtitle: "三级标题",
            iconName: "textformat.size.smaller",
            syntaxHint: "###",
            keywords: ["3", "###", "header", "标题", "三级"],
            isBlockLevel: true,
            insertion: .text("### ")
        ),
        SlashCommandItem(
            id: "todo",
            title: "Todo List",
            subtitle: "待办清单",
            iconName: "checklist",
            syntaxHint: "[]",
            keywords: ["task", "check", "checkbox", "[]", "待办", "任务", "清单"],
            isBlockLevel: true,
            insertion: .text("- [ ] ")
        ),
        SlashCommandItem(
            id: "bullet",
            title: "Bulleted List",
            subtitle: "无序列表",
            iconName: "list.bullet",
            syntaxHint: "-",
            keywords: ["ul", "unordered", "-", "无序", "列表"],
            isBlockLevel: true,
            insertion: .text("- ")
        ),
        SlashCommandItem(
            id: "number",
            title: "Numbered List",
            subtitle: "有序列表",
            iconName: "list.number",
            syntaxHint: "1.",
            keywords: ["ol", "ordered", "1.", "有序", "列表", "数字"],
            isBlockLevel: true,
            insertion: .text("1. ")
        ),
        SlashCommandItem(
            id: "quote",
            title: "Quote",
            subtitle: "引用块",
            iconName: "quote.opening",
            syntaxHint: ">",
            keywords: [">", "blockquote", "引用"],
            isBlockLevel: true,
            insertion: .text("> ")
        ),
        SlashCommandItem(
            id: "code",
            title: "Code Block",
            subtitle: "代码块",
            iconName: "chevron.left.forwardslash.chevron.right",
            syntaxHint: "```",
            keywords: ["```", "snippet", "代码"],
            isBlockLevel: true,
            insertion: .codeBlock
        ),
        SlashCommandItem(
            id: "divider",
            title: "Divider",
            subtitle: "分割线",
            iconName: "minus",
            syntaxHint: "---",
            keywords: ["hr", "---", "line", "分割", "分隔线", "横线"],
            isBlockLevel: true,
            insertion: .text("---\n")
        ),
        SlashCommandItem(
            id: "today",
            title: "Today",
            subtitle: "今日日期",
            iconName: "calendar",
            syntaxHint: "date",
            keywords: ["date", "calendar", "日期", "今天", "今日"],
            isBlockLevel: false,
            insertion: .today
        ),
        SlashCommandItem(
            id: "now",
            title: "Current Time",
            subtitle: "当前时间",
            iconName: "clock",
            syntaxHint: "HH:mm",
            keywords: ["time", "clock", "时间", "当前", "现在"],
            isBlockLevel: false,
            insertion: .now
        ),
        SlashCommandItem(
            id: "link",
            title: "Link",
            subtitle: "链接",
            iconName: "link",
            syntaxHint: "[]()",
            keywords: ["url", "[]()", "链接", "超链接", "网址"],
            isBlockLevel: false,
            insertion: .link
        )
    ]

    // MARK: - Trigger Detection

    static func detectTrigger(in text: String, selectedRange: NSRange) -> SlashTriggerMatch? {
        guard selectedRange.location != NSNotFound,
              selectedRange.length == 0 else {
            return nil
        }

        let nsText = text as NSString
        let caretLocation = selectedRange.location
        guard caretLocation >= 0, caretLocation <= nsText.length else {
            return nil
        }

        let lineStart = findLineStart(in: nsText, before: caretLocation)
        let lineEnd = findLineEnd(in: nsText, from: caretLocation)

        // Scan backwards from caret within the current line to locate `/`.
        var foundSlashLocation: Int?
        var cursor = caretLocation
        while cursor > lineStart {
            let unit = nsText.character(at: cursor - 1)
            if unit == UTF16Unit.slash {
                foundSlashLocation = cursor - 1
                break
            }
            if isHorizontalWhitespaceOrNewline(unit) {
                return nil
            }
            cursor -= 1
        }

        guard let slashLocation = foundSlashLocation else {
            return nil
        }

        // `/` must be at line start or immediately preceded by `" "` or `"\t"`.
        if slashLocation > lineStart {
            let previousUnit = nsText.character(at: slashLocation - 1)
            guard previousUnit == UTF16Unit.space || previousUnit == UTF16Unit.tab else {
                return nil
            }
        }

        let queryRange = NSRange(
            location: slashLocation + 1,
            length: caretLocation - (slashLocation + 1)
        )
        let query = nsText.substring(with: queryRange)

        guard query.count <= maxQueryLength,
              !query.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "/" }) else {
            return nil
        }

        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let currentLine = nsText.substring(with: lineRange) as NSString
        let slashOffsetInLine = slashLocation - lineStart

        if isInsideFencedCodeBlock(
            in: nsText,
            lineStartLocation: lineStart,
            currentLine: currentLine,
            slashOffsetInLine: slashOffsetInLine
        ) {
            return nil
        }

        if isInsideInlineCode(in: currentLine, slashOffsetInLine: slashOffsetInLine) {
            return nil
        }

        if isInsideLinkOrWikiLink(in: currentLine, slashOffsetInLine: slashOffsetInLine) {
            return nil
        }

        return SlashTriggerMatch(
            slashLocation: slashLocation,
            triggerRange: NSRange(location: slashLocation, length: caretLocation - slashLocation),
            query: query,
            lineStartLocation: lineStart
        )
    }

    // MARK: - Filtering & Ranking

    static func filterItems(
        query: String,
        items: [SlashCommandItem] = builtInItems
    ) -> [SlashCommandItem] {
        guard !query.isEmpty else {
            return items
        }

        let normalizedQuery = query.lowercased()

        struct RankedItem {
            let item: SlashCommandItem
            let tier: Int
            let originalIndex: Int
        }

        var ranked: [RankedItem] = []
        ranked.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            if let tier = matchTier(for: item, normalizedQuery: normalizedQuery) {
                ranked.append(RankedItem(item: item, tier: tier, originalIndex: index))
            }
        }

        ranked.sort { lhs, rhs in
            if lhs.tier != rhs.tier {
                return lhs.tier < rhs.tier
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        return ranked.map(\.item)
    }

    // MARK: - Command Replacement

    static func apply(
        item: SlashCommandItem,
        match: SlashTriggerMatch,
        in text: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> SlashCommandReplacement {
        let nsText = text as NSString
        let safeLineStart = min(max(match.lineStartLocation, 0), nsText.length)
        let safeSlash = min(max(match.slashLocation, safeLineStart), nsText.length)
        let safeTriggerEnd = min(
            max(NSMaxRange(match.triggerRange), safeSlash),
            nsText.length
        )

        let (baseInsertion, selectionInBase) = renderedInsertion(
            for: item.insertion,
            now: now,
            timeZone: timeZone
        )

        let replaceRange: NSRange
        let prefix: String

        if item.isBlockLevel {
            var whitespaceStart = safeSlash
            while whitespaceStart > safeLineStart {
                let unit = nsText.character(at: whitespaceStart - 1)
                if unit == UTF16Unit.space || unit == UTF16Unit.tab {
                    whitespaceStart -= 1
                } else {
                    break
                }
            }

            if whitespaceStart == safeLineStart {
                // Only leading whitespace precedes `/` on this line.
                let leadingRange = NSRange(
                    location: safeLineStart,
                    length: safeSlash - safeLineStart
                )
                let leadingWhitespace = nsText.substring(with: leadingRange)
                if isListCommand(item.id), leadingWhitespace.contains("\t") {
                    let tabIndent = String(leadingWhitespace.filter { $0 == "\t" })
                    replaceRange = NSRange(
                        location: safeLineStart,
                        length: safeTriggerEnd - safeLineStart
                    )
                    prefix = tabIndent
                } else {
                    replaceRange = NSRange(
                        location: safeLineStart,
                        length: safeTriggerEnd - safeLineStart
                    )
                    prefix = ""
                }
            } else {
                // Non-whitespace content precedes `/` on this line: replace the preceding
                // spaces/tabs + `/query` and start the block on a fresh line.
                replaceRange = NSRange(
                    location: whitespaceStart,
                    length: safeTriggerEnd - whitespaceStart
                )
                prefix = "\n"
            }
        } else {
            replaceRange = NSRange(
                location: safeSlash,
                length: safeTriggerEnd - safeSlash
            )
            prefix = ""
        }

        let replacementText = prefix + baseInsertion
        let updatedText = nsText.replacingCharacters(in: replaceRange, with: replacementText)
        let prefixUTF16Length = (prefix as NSString).length
        let selectedRange = NSRange(
            location: replaceRange.location + prefixUTF16Length + selectionInBase.location,
            length: selectionInBase.length
        )

        return SlashCommandReplacement(
            replaceRange: replaceRange,
            replacementText: replacementText,
            selectedRange: selectedRange,
            updatedText: updatedText
        )
    }

    // MARK: - Menu Placement

    static func menuHeight(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let rawHeight = CGFloat(itemCount) * rowHeight + menuPadding * 2
        return min(rawHeight, maxMenuHeight)
    }

    static func screenMenuPlacement(
        caretScreenRect: CGRect,
        screenVisibleFrame: CGRect,
        itemCount: Int
    ) -> SlashMenuPlacement {
        let minAllowedX = screenVisibleFrame.minX + screenEdgeMargin
        let minAllowedY = screenVisibleFrame.minY + screenEdgeMargin
        let maxAllowedY = screenVisibleFrame.maxY - screenEdgeMargin
        let downwardMaxY = caretScreenRect.minY - screenPopupGap

        guard itemCount > 0 else {
            let clampedX = min(max(caretScreenRect.minX, minAllowedX), screenVisibleFrame.maxX - screenEdgeMargin)
            let clampedY = min(max(downwardMaxY, minAllowedY), maxAllowedY)
            return SlashMenuPlacement(
                frame: CGRect(x: clampedX, y: clampedY, width: 0, height: 0),
                isFlippedUpward: false
            )
        }

        let availableWidth = max(screenVisibleFrame.width - screenEdgeMargin * 2, 0)
        let width = min(menuWidth, availableWidth)
        let desiredHeight = menuHeight(for: itemCount)
        let maxAllowedX = max(screenVisibleFrame.maxX - screenEdgeMargin - width, minAllowedX)
        let originX = min(max(caretScreenRect.minX, minAllowedX), maxAllowedX)

        let spaceBelow = max(downwardMaxY - minAllowedY, 0)
        let upwardMinY = caretScreenRect.maxY + screenPopupGap
        let spaceAbove = max(maxAllowedY - upwardMinY, 0)

        if spaceBelow >= desiredHeight {
            return SlashMenuPlacement(
                frame: CGRect(
                    x: originX,
                    y: downwardMaxY - desiredHeight,
                    width: width,
                    height: desiredHeight
                ),
                isFlippedUpward: false
            )
        }

        if spaceAbove > spaceBelow {
            let fittedHeight = min(desiredHeight, spaceAbove)
            return SlashMenuPlacement(
                frame: CGRect(
                    x: originX,
                    y: upwardMinY,
                    width: width,
                    height: fittedHeight
                ),
                isFlippedUpward: true
            )
        }

        let fittedHeight = min(desiredHeight, spaceBelow)
        return SlashMenuPlacement(
            frame: CGRect(
                x: originX,
                y: downwardMaxY - fittedHeight,
                width: width,
                height: fittedHeight
            ),
            isFlippedUpward: false
        )
    }

    // MARK: - Private Helpers

    private enum UTF16Unit {
        static let tab: unichar = 0x0009
        static let lineFeed: unichar = 0x000A
        static let carriageReturn: unichar = 0x000D
        static let space: unichar = 0x0020
        static let slash: unichar = 0x002F
        static let backtick: unichar = 0x0060
        static let lineSeparator: unichar = 0x2028
        static let paragraphSeparator: unichar = 0x2029
    }

    private static let closedWikiLinkRegex = try! NSRegularExpression(
        pattern: #"!?\[\[[^\]\r\n]*\]\]"#
    )
    private static let unclosedWikiLinkPrefixRegex = try! NSRegularExpression(
        pattern: #"!?\[\[[^\]\r\n]*$"#
    )
    private static let closedMarkdownLinkRegex = try! NSRegularExpression(
        pattern: #"!?\[[^\]\r\n]*\]\([^\)\r\n]*\)"#
    )
    private static let unclosedMarkdownLinkDestPrefixRegex = try! NSRegularExpression(
        pattern: #"!?\[[^\]\r\n]*\]\([^\)\r\n]*$"#
    )

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == UTF16Unit.lineFeed
            || unit == UTF16Unit.carriageReturn
            || unit == UTF16Unit.lineSeparator
            || unit == UTF16Unit.paragraphSeparator
    }

    private static func isHorizontalWhitespaceOrNewline(_ unit: unichar) -> Bool {
        unit == UTF16Unit.space || unit == UTF16Unit.tab || isLineBreak(unit)
    }

    private static func findLineStart(in nsText: NSString, before location: Int) -> Int {
        var index = location
        while index > 0 {
            if isLineBreak(nsText.character(at: index - 1)) {
                break
            }
            index -= 1
        }
        return index
    }

    private static func findLineEnd(in nsText: NSString, from location: Int) -> Int {
        var index = location
        let length = nsText.length
        while index < length {
            if isLineBreak(nsText.character(at: index)) {
                break
            }
            index += 1
        }
        return index
    }

    private static func isInsideFencedCodeBlock(
        in nsText: NSString,
        lineStartLocation: Int,
        currentLine: NSString,
        slashOffsetInLine: Int
    ) -> Bool {
        var openFenceBacktickCount: Int?
        var cursor = 0

        while cursor < lineStartLocation {
            let currentLineStart = cursor
            while cursor < lineStartLocation && !isLineBreak(nsText.character(at: cursor)) {
                cursor += 1
            }
            let currentLineEnd = cursor

            // Advance past line break (`\r\n` or single break char).
            if cursor < lineStartLocation {
                let br = nsText.character(at: cursor)
                cursor += 1
                if br == UTF16Unit.carriageReturn,
                   cursor < lineStartLocation,
                   nsText.character(at: cursor) == UTF16Unit.lineFeed {
                    cursor += 1
                }
            }

            var scan = currentLineStart
            while scan < currentLineEnd {
                let ch = nsText.character(at: scan)
                if ch == UTF16Unit.space || ch == UTF16Unit.tab {
                    scan += 1
                } else {
                    break
                }
            }

            var tickCount = 0
            while scan < currentLineEnd && nsText.character(at: scan) == UTF16Unit.backtick {
                tickCount += 1
                scan += 1
            }

            guard tickCount >= 3 else { continue }

            if let neededTicks = openFenceBacktickCount {
                if tickCount >= neededTicks {
                    var onlyTrailingSpaces = true
                    var rest = scan
                    while rest < currentLineEnd {
                        let ch = nsText.character(at: rest)
                        if ch != UTF16Unit.space && ch != UTF16Unit.tab {
                            onlyTrailingSpaces = false
                            break
                        }
                        rest += 1
                    }
                    if onlyTrailingSpaces {
                        openFenceBacktickCount = nil
                    }
                }
            } else {
                var hasBacktickInInfo = false
                var rest = scan
                while rest < currentLineEnd {
                    if nsText.character(at: rest) == UTF16Unit.backtick {
                        hasBacktickInInfo = true
                        break
                    }
                    rest += 1
                }
                if !hasBacktickInInfo {
                    openFenceBacktickCount = tickCount
                }
            }
        }

        if openFenceBacktickCount != nil {
            return true
        }

        // Also block if the current line itself begins a ``` fence before `/`.
        var lineScan = 0
        let lineLength = currentLine.length
        while lineScan < lineLength {
            let ch = currentLine.character(at: lineScan)
            if ch == UTF16Unit.space || ch == UTF16Unit.tab {
                lineScan += 1
            } else {
                break
            }
        }
        var currentLineTicks = 0
        while lineScan < lineLength && currentLine.character(at: lineScan) == UTF16Unit.backtick {
            currentLineTicks += 1
            lineScan += 1
        }
        if currentLineTicks >= 3 && lineScan <= slashOffsetInLine {
            return true
        }

        return false
    }

    private static func isInsideInlineCode(in currentLine: NSString, slashOffsetInLine: Int) -> Bool {
        struct BacktickRun {
            let start: Int
            let length: Int
        }

        var runs: [BacktickRun] = []
        let length = currentLine.length
        var index = 0

        while index < length {
            if currentLine.character(at: index) == UTF16Unit.backtick {
                let start = index
                while index < length && currentLine.character(at: index) == UTF16Unit.backtick {
                    index += 1
                }
                runs.append(BacktickRun(start: start, length: index - start))
            } else {
                index += 1
            }
        }

        var runIndex = 0
        while runIndex < runs.count {
            let openRun = runs[runIndex]
            if let closeRunIndex = ((runIndex + 1)..<runs.count).first(where: {
                runs[$0].length == openRun.length
            }) {
                let closeRun = runs[closeRunIndex]
                let spanStart = openRun.start
                let spanEnd = closeRun.start + closeRun.length
                if slashOffsetInLine >= spanStart && slashOffsetInLine < spanEnd {
                    return true
                }
                runIndex = closeRunIndex + 1
            } else {
                if openRun.start < slashOffsetInLine {
                    return true
                }
                runIndex += 1
            }
        }

        return false
    }

    private static func isInsideLinkOrWikiLink(
        in currentLine: NSString,
        slashOffsetInLine: Int
    ) -> Bool {
        let lineString = currentLine as String
        let fullLineRange = NSRange(location: 0, length: currentLine.length)

        for match in closedWikiLinkRegex.matches(in: lineString, options: [], range: fullLineRange) {
            let range = match.range
            if slashOffsetInLine >= range.location && slashOffsetInLine < NSMaxRange(range) {
                return true
            }
        }

        for match in closedMarkdownLinkRegex.matches(in: lineString, options: [], range: fullLineRange) {
            let range = match.range
            if slashOffsetInLine >= range.location && slashOffsetInLine < NSMaxRange(range) {
                return true
            }
        }

        if slashOffsetInLine > 0 {
            let prefixRange = NSRange(location: 0, length: slashOffsetInLine)
            if unclosedWikiLinkPrefixRegex.firstMatch(in: lineString, options: [], range: prefixRange) != nil {
                return true
            }
            if unclosedMarkdownLinkDestPrefixRegex.firstMatch(in: lineString, options: [], range: prefixRange) != nil {
                return true
            }
        }

        return false
    }

    private static func matchTier(for item: SlashCommandItem, normalizedQuery: String) -> Int? {
        let idLower = item.id.lowercased()
        let titleLower = item.title.lowercased()
        let subtitleLower = item.subtitle.lowercased()
        let keywordsLower = item.keywords.map { $0.lowercased() }

        // Tier 0: Exact match on id, title, subtitle, or alias keyword.
        if idLower == normalizedQuery
            || titleLower == normalizedQuery
            || subtitleLower == normalizedQuery
            || keywordsLower.contains(normalizedQuery) {
            return 0
        }

        // Tier 1: Prefix match on primary fields (id, title, subtitle).
        if idLower.hasPrefix(normalizedQuery)
            || titleLower.hasPrefix(normalizedQuery)
            || subtitleLower.hasPrefix(normalizedQuery) {
            return 1
        }

        // Tier 2: Prefix match on alias keywords or word boundary in English title.
        let titleWords = titleLower.split(separator: " ")
        if keywordsLower.contains(where: { $0.hasPrefix(normalizedQuery) })
            || titleWords.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 2
        }

        // Tier 3: Substring / contains match on id, title, subtitle, or alias keywords.
        if idLower.contains(normalizedQuery)
            || titleLower.contains(normalizedQuery)
            || subtitleLower.contains(normalizedQuery)
            || keywordsLower.contains(where: { $0.contains(normalizedQuery) }) {
            return 3
        }

        return nil
    }

    private static func isListCommand(_ id: String) -> Bool {
        id == "todo" || id == "bullet" || id == "number"
    }

    private static func renderedInsertion(
        for behavior: SlashCommandItem.InsertionBehavior,
        now: Date,
        timeZone: TimeZone
    ) -> (text: String, selection: NSRange) {
        switch behavior {
        case .text(let value):
            return (value, NSRange(location: (value as NSString).length, length: 0))

        case .codeBlock:
            let snippet = "```\n\n```"
            // Place caret on the middle blank line right after `"```\n"`.
            return (snippet, NSRange(location: 4, length: 0))

        case .today:
            let formatted = formatDate(now, format: "yyyy-MM-dd", timeZone: timeZone)
            return (formatted, NSRange(location: (formatted as NSString).length, length: 0))

        case .now:
            let formatted = formatDate(now, format: "HH:mm", timeZone: timeZone)
            return (formatted, NSRange(location: (formatted as NSString).length, length: 0))

        case .link:
            let placeholder = "link text"
            let snippet = "[\(placeholder)](url)"
            return (snippet, NSRange(location: 1, length: (placeholder as NSString).length))
        }
    }

    private static func formatDate(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

@MainActor
final class SlashCommandSession: ObservableObject {
    @Published private(set) var activeMatch: SlashTriggerMatch?
    @Published private(set) var filteredItems: [SlashCommandItem] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isComposingMarkedText = false
    private(set) var dismissedSlashLocation: Int?

    private let availableItems: [SlashCommandItem]

    init(items: [SlashCommandItem] = SlashCommandEngine.builtInItems) {
        self.availableItems = items
    }

    var isPresented: Bool {
        activeMatch != nil && !filteredItems.isEmpty
    }

    var selectedItem: SlashCommandItem? {
        guard isPresented, filteredItems.indices.contains(selectedIndex) else {
            return nil
        }
        return filteredItems[selectedIndex]
    }

    func update(text: String, selectedRange: NSRange, hasMarkedText: Bool = false) {
        let nsText = text as NSString
        isComposingMarkedText = hasMarkedText

        // Clear dismissed slash tracking once that `/` is deleted or displaced.
        if let dismissedLocation = dismissedSlashLocation {
            if dismissedLocation < 0
                || dismissedLocation >= nsText.length
                || nsText.character(at: dismissedLocation) != 0x002F {
                dismissedSlashLocation = nil
            }
        }

        if hasMarkedText {
            guard let currentMatch = activeMatch else {
                // Do not trigger/jump while IME text is uncommitted and session has not started.
                return
            }
            let slashStillPresent = currentMatch.slashLocation >= 0
                && currentMatch.slashLocation < nsText.length
                && nsText.character(at: currentMatch.slashLocation) == 0x002F
                && selectedRange.location != NSNotFound
                && selectedRange.location > currentMatch.slashLocation
            if !slashStillPresent {
                clearActiveState()
            }
            return
        }

        guard let match = SlashCommandEngine.detectTrigger(in: text, selectedRange: selectedRange) else {
            clearActiveState()
            return
        }

        if let dismissedLocation = dismissedSlashLocation {
            if match.slashLocation == dismissedLocation {
                clearActiveState()
                return
            } else {
                dismissedSlashLocation = nil
            }
        }

        let previousMatch = activeMatch
        let items = SlashCommandEngine.filterItems(query: match.query, items: availableItems)

        activeMatch = match
        filteredItems = items

        if items.isEmpty {
            selectedIndex = 0
        } else if previousMatch?.slashLocation == match.slashLocation,
                  previousMatch?.query == match.query {
            selectedIndex = min(max(selectedIndex, 0), items.count - 1)
        } else {
            selectedIndex = 0
        }
    }

    func moveUp() {
        guard isPresented else { return }
        selectedIndex = (selectedIndex - 1 + filteredItems.count) % filteredItems.count
    }

    func moveDown() {
        guard isPresented else { return }
        selectedIndex = (selectedIndex + 1) % filteredItems.count
    }

    func dismiss() {
        if let activeSlashLocation = activeMatch?.slashLocation {
            dismissedSlashLocation = activeSlashLocation
        }
        clearActiveState()
    }

    func reset() {
        dismissedSlashLocation = nil
        isComposingMarkedText = false
        clearActiveState()
    }

    func handleCommandSelector(_ selector: Selector) -> SlashKeyAction {
        guard isPresented, !isComposingMarkedText else {
            return .ignored
        }

        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveUp()
            return .handled

        case #selector(NSResponder.moveDown(_:)):
            moveDown()
            return .handled

        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertTab(_:)):
            guard let item = selectedItem else {
                return .ignored
            }
            return .commit(item)

        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return .handled

        default:
            return .ignored
        }
    }

    func commit(
        _ item: SlashCommandItem,
        in text: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> SlashCommandReplacement? {
        guard let match = activeMatch else {
            return nil
        }
        let replacement = SlashCommandEngine.apply(
            item: item,
            match: match,
            in: text,
            now: now,
            timeZone: timeZone
        )
        reset()
        return replacement
    }

    private func clearActiveState() {
        activeMatch = nil
        filteredItems = []
        selectedIndex = 0
    }
}
