import Foundation

public enum NoteTitleExtractor {
    public static let maximumLength = 42

    private static let wikiLinkStorageRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\|\]\r\n]*)\|[^\]\r\n]+\]\]"#
    )
    private static let pairedCodeSpanRegex = try! NSRegularExpression(
        pattern: #"(`+)([^`\r\n]+?)\1"#
    )
    private static let boldItalicRegex = try! NSRegularExpression(
        pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?=\S)([^\*]+?)(?<=\S)\*(?!\*)"#
    )

    public static func title(for text: String, index: Int, untitledPrefix: String = "Untitled") -> String {
        let contentLines = nonFencedLines(in: text)

        for line in contentLines {
            if let heading = extractATXHeading(from: line), !heading.isEmpty {
                return truncate(heading)
            }
        }

        for line in contentLines {
            let candidate = extractFallbackTitle(from: line)
            if !candidate.isEmpty {
                return truncate(candidate)
            }
        }

        return "\(untitledPrefix) \(index + 1)"
    }

    private static func truncate(_ title: String) -> String {
        guard title.count > maximumLength else { return title }
        return String(title.prefix(maximumLength - 1)) + "…"
    }

    private static func nonFencedLines(in text: String) -> [Substring] {
        var result: [Substring] = []
        var activeFence: (character: Character, length: Int)?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let rawLine = text[lineStart..<lineEnd]

            let trimmedLeading = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            if let fence = activeFence {
                if isClosingFence(trimmedLeading, matching: fence) {
                    activeFence = nil
                }
            } else if let openedFence = parseOpeningFence(trimmedLeading) {
                activeFence = openedFence
            } else {
                result.append(rawLine)
            }

            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }

        return result
    }

    private static func parseOpeningFence(_ trimmedLeading: Substring) -> (character: Character, length: Int)? {
        guard let first = trimmedLeading.first, first == "`" || first == "~" else {
            return nil
        }

        let fencePrefix = trimmedLeading.prefix(while: { $0 == first })
        let length = fencePrefix.count
        guard length >= 3 else { return nil }

        let remainder = trimmedLeading.dropFirst(length)
        if first == "`", remainder.contains("`") {
            return nil
        }

        return (first, length)
    }

    private static func isClosingFence(
        _ trimmedLeading: Substring,
        matching fence: (character: Character, length: Int)
    ) -> Bool {
        let prefix = trimmedLeading.prefix(while: { $0 == fence.character })
        guard prefix.count >= fence.length else { return false }
        let remainder = trimmedLeading.dropFirst(prefix.count)
        return remainder.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func extractATXHeading(from line: Substring) -> String? {
        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
        let hashes = trimmedLeading.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }

        let afterHashes = trimmedLeading.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else {
            return nil
        }

        var body = String(afterHashes).trimmingCharacters(in: .whitespacesAndNewlines)
        body = stripClosingHashes(from: body)
        body = cleanInlineMarkdown(in: body)
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripClosingHashes(from heading: String) -> String {
        var current = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return "" }

        if current.allSatisfy({ $0 == "#" }) {
            return ""
        }

        while current.last == "#" {
            var hashStart = current.endIndex
            while hashStart > current.startIndex {
                let prev = current.index(before: hashStart)
                if current[prev] == "#" {
                    hashStart = prev
                } else {
                    break
                }
            }

            guard hashStart > current.startIndex else {
                return ""
            }

            let beforeHashes = current[current.index(before: hashStart)]
            guard beforeHashes == " " || beforeHashes == "\t" else {
                break
            }

            current = String(current[..<hashStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return current
    }

    private static func extractFallbackTitle(from line: Substring) -> String {
        var current = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return "" }

        if let heading = extractATXHeading(from: Substring(current)) {
            return heading
        }

        while !current.isEmpty {
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if let next = stripSingleBlockPrefix(from: current) {
                current = next
            } else {
                break
            }
        }

        current = cleanInlineMarkdown(in: current)
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSingleBlockPrefix(from text: String) -> String? {
        for checkboxPrefix in ["- [ ]", "- [x]", "- [X]", "* [ ]", "* [x]", "* [X]", "+ [ ]", "+ [x]", "+ [X]"] {
            if text == checkboxPrefix {
                return ""
            }
            if text.hasPrefix(checkboxPrefix) {
                let rest = text.dropFirst(checkboxPrefix.count)
                if rest.first == " " || rest.first == "\t" {
                    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        if text.first == ">" {
            return String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for bullet in ["-", "*", "+"] {
            if text == bullet {
                return ""
            }
            if text.hasPrefix(bullet) {
                let rest = text.dropFirst(bullet.count)
                if rest.first == " " || rest.first == "\t" {
                    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let digits = text.prefix(while: \.isWholeNumber)
        if !digits.isEmpty {
            let afterDigits = text.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let rest = afterDigits.dropFirst()
                if rest.isEmpty {
                    return ""
                }
                if rest.first == " " || rest.first == "\t" {
                    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    public static func cleanInlineMarkdown(in input: String) -> String {
        guard !input.isEmpty else { return "" }

        var working = replacingMatches(
            of: wikiLinkStorageRegex,
            in: input,
            withTemplate: "[[$1]]"
        )

        var codeSpans: [String] = []
        let nsWorking = working as NSString
        let matches = pairedCodeSpanRegex.matches(
            in: working,
            range: NSRange(location: 0, length: nsWorking.length)
        )
        if !matches.isEmpty {
            var rebuilt = ""
            var cursor = 0
            for match in matches {
                let prefixLength = match.range.location - cursor
                if prefixLength > 0 {
                    rebuilt += nsWorking.substring(with: NSRange(location: cursor, length: prefixLength))
                }
                let inner = nsWorking.substring(with: match.range(at: 2))
                let tokenIndex = codeSpans.count
                codeSpans.append(inner)
                rebuilt += "\u{FFFC}\(tokenIndex)\u{FFFD}"
                cursor = match.range.location + match.range.length
            }
            if cursor < nsWorking.length {
                rebuilt += nsWorking.substring(with: NSRange(location: cursor, length: nsWorking.length - cursor))
            }
            working = rebuilt
        }

        working = replacingMatches(of: boldItalicRegex, in: working, withTemplate: "$1")
        working = replacingMatches(of: boldRegex, in: working, withTemplate: "$1")
        working = replacingMatches(of: italicRegex, in: working, withTemplate: "$1")

        for (index, inner) in codeSpans.enumerated() {
            working = working.replacingOccurrences(of: "\u{FFFC}\(index)\u{FFFD}", with: inner)
        }

        return working
    }

    private static func replacingMatches(
        of regex: NSRegularExpression,
        in string: String,
        withTemplate template: String
    ) -> String {
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
    }
}
