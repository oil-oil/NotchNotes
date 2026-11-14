//
//  NativeTextViewCoordinator+Autocorrect.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Toggles AppKit's auto-correct, spell-check, grammar-check and quote
//  substitution off when the caret enters tokens where those features are
//  unwanted (code blocks, LaTeX, links). The decision is cached so it only
//  fires when the state actually changes.
//

import AppKit

extension NativeTextViewCoordinator {
    func updateAutocorrectSettings(
        _ textView: NSTextView,
        caretLocation: Int,
        codeTokens: [MarkdownToken]? = nil,
        latexTokens: [MarkdownToken]? = nil,
        allTokens: [MarkdownToken]? = nil
    ) {
        if cachedSpellingDisabled == true {
            return
        }
        cachedSpellingDisabled = true

        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    func isInsideCode(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return MarkdownDetection.isInsideCodeBlock(range: range, codeTokens: parsed.codeTokens)
    }

    func isInsideLatex(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        if MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.latexTokens) {
            return true
        }
        return MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.blockLatexTokens)
    }

    func isInsideSpellcheckSuppressedToken(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .wikiLink || token.kind == .link || token.kind == .imageEmbed else {
                return false
            }
            return NSLocationInRange(location, token.range)
        }
    }

    func isInsideSpellcheckSuppressedToken(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .wikiLink || token.kind == .link || token.kind == .imageEmbed else {
                return false
            }
            return NSIntersectionRange(token.range, range).length > 0
        }
    }
}
