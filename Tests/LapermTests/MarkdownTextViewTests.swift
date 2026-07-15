import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor @Test func usesTextKit2Stack() {
    let textView = MarkdownTextView()
    // textLayoutManager プロパティで確認する(layoutManager には触れない — TextKit1 フォールバック防止)
    #expect(textView.textLayoutManager != nil)
    #expect(textView.textContentStorage != nil)
}

@MainActor @Test func highlightsInitialTextAfterHighlightAll() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func typingSchedulesHighlight() {
    let textView = MarkdownTextView()
    textView.string = "plain"
    textView.highlightAll()
    // 編集をシミュレート(didProcessEditing 経由で noteEdit される)
    textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
    // 非同期スケジュールを待たず、直接 flush して差分適用を検証
    textView.highlightNow()
    let font = textView.textStorage!.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(font == MarkdownTheme.default.style(for: .heading(level: 1))?.font)
}

@MainActor @Test func settingThemeRehighlights() {
    let textView = MarkdownTextView()
    textView.string = "# Title"
    textView.highlightAll()
    var theme = MarkdownTheme.default
    theme.styles[.heading(level: 1)] = MarkdownTheme.Style(font: .systemFont(ofSize: 40, weight: .heavy))
    textView.theme = theme
    let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect(font?.pointSize == 40)
}
