//
//  EmphasizedText.swift
//  Jumping Fox
//
//  Turns the Markdown in localized intro copy into one attributed string.
//  Keeping the result as a single text value lets SwiftUI wrap a bold span
//  across lines without treating each styled part as a separate view.
//
//  Markdown rather than an app-private marker: **this** is what Xcode's string
//  catalog editor renders, what translation tools carry through untouched, and
//  what a translator can be expected to already know. Which words carry the
//  emphasis is then a translation decision, made per language — the bold in a
//  Dutch sentence rarely falls on the same words as in English.
//

import Foundation

func emphasizedAttributedString(_ copy: String) -> AttributedString {
    // `inlineOnlyPreservingWhitespace` keeps the copy on one paragraph and
    // leaves its spacing alone; the full parser would collapse both.
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    // Malformed Markdown is a bad translation, not a crash: show the copy as
    // written and let the missing emphasis be the visible symptom.
    return (try? AttributedString(markdown: copy, options: options))
        ?? AttributedString(copy)
}
